// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/**
 * @title ArcadeV4SwapRouter
 * @notice Thin router that lets EOAs swap through V4 pools. V4 forbids direct
 *         `poolManager.swap` calls outside of an `unlock` callback; this
 *         contract is the canonical caller for our launchpad's pools.
 *
 *         Flow per swap:
 *           1. Caller approves this contract to spend their input currency.
 *           2. Caller invokes `exactInputSingle` or `exactOutputSingle`.
 *           3. Router calls `poolManager.unlock(encoded args)`. The manager
 *              calls back into `unlockCallback`, where we:
 *                a. `poolManager.swap` to generate a BalanceDelta.
 *                b. `sync` + transfer input from caller + `settle` for the
 *                   currency we owe the pool.
 *                c. `take` the output currency to the recipient.
 *              All currency deltas zero at callback return -> manager accepts.
 *           4. Router enforces slippage on the realised input/output and
 *              returns the amount the user actually received / spent.
 *
 *         No fees, no path-finding, no Permit2 -- single-pool single-hop
 *         only. Multi-hop or aggregator behavior layers on top. STATELESS +
 *         ownerless: the router charges nothing of its own (the pool/hook fee is
 *         the only fee). An earlier build carried an owner-tunable per-swap
 *         "referral surcharge" (extra bps on top, paid to a passed referrer);
 *         that model was ABANDONED (referral is now a share of the PLATFORM fee,
 *         not a surcharge on top), so the router is back to a pure swap conduit.
 *
 *         License: MIT (our code). Depends on v4-core under BUSL-1.1 -- same
 *         non-production-use scope as the rest of `v4src/`.
 */
contract ArcadeV4SwapRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;

    error NotPoolManager();
    error SlippageExceeded(uint256 actual, uint256 limit);
    error ZeroAmount();
    error SwapFailed();
    /// Exact-output swap did not deliver the full requested output (a binding
    /// price limit produced a partial fill, or a hook skimmed the output). We
    /// refuse to silently under-deliver on an exact-output request.
    error IncompleteOutput(uint256 delivered, uint256 requested);

    event SwapExecuted(
        address indexed payer,
        address indexed recipient,
        Currency indexed inputCurrency,
        Currency outputCurrency,
        uint256 amountIn,
        uint256 amountOut,
        bool zeroForOne
    );

    /// @dev Encoded payload pushed through `poolManager.unlock` and decoded
    ///      in `unlockCallback`.
    struct SwapCallbackData {
        address payer;
        address recipient;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified; // negative = exact-in, positive = exact-out
        uint160 sqrtPriceLimitX96;
    }

    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    // -----------------------------------------------------------------
    // Public entry-points
    // -----------------------------------------------------------------

    /**
     * @notice Swap an exact amount of input currency for as much output as
     *         possible, reverting if the output falls below `minAmountOut`.
     * @param key             PoolKey identifying the V4 pool.
     * @param zeroForOne      True if swapping currency0 -> currency1.
     * @param amountIn        Exact input amount the caller sends.
     * @param minAmountOut    Slippage floor on the output the recipient gets.
     * @param recipient       Destination of the output currency.
     * @param sqrtPriceLimitX96 Price limit. Pass 0 for "no limit" -- it is
     *        resolved to the full tick range in `unlockCallback` (a raw 0 is
     *        rejected by v4-core's `Pool.swap` on both directions, so callers
     *        MUST rely on this sentinel rather than passing 0 through).
     * @return amountOut      Realised output the recipient received.
     */
    function exactInputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint160 sqrtPriceLimitX96
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                SwapCallbackData({
                    payer: msg.sender,
                    recipient: recipient,
                    key: key,
                    zeroForOne: zeroForOne,
                    // V4 convention: NEGATIVE = exact-input.
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                })
            )
        );
        (uint256 realisedIn, uint256 realisedOut) = abi.decode(result, (uint256, uint256));
        if (realisedOut < minAmountOut) revert SlippageExceeded(realisedOut, minAmountOut);
        amountOut = realisedOut;

        // Emit the REALISED amounts (indexers derive volume from this event).
        emit SwapExecuted(msg.sender, recipient, inputCurrency, outputCurrency, realisedIn, realisedOut, zeroForOne);
    }

    /**
     * @notice Swap as much input as needed to receive an exact output amount,
     *         reverting if the input required exceeds `maxAmountIn` OR if the
     *         pool cannot deliver the full `amountOut` (partial fill / hook
     *         skim -> `IncompleteOutput`). Pass `sqrtPriceLimitX96 = 0` for
     *         no limit (resolved to the full tick range in `unlockCallback`).
     */
    function exactOutputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        uint160 sqrtPriceLimitX96
    ) external nonReentrant returns (uint256 amountIn) {
        if (amountOut == 0) revert ZeroAmount();

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                SwapCallbackData({
                    payer: msg.sender,
                    recipient: recipient,
                    key: key,
                    zeroForOne: zeroForOne,
                    // V4 convention: POSITIVE = exact-output.
                    amountSpecified: int256(amountOut),
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                })
            )
        );
        (uint256 realisedIn, uint256 realisedOut) = abi.decode(result, (uint256, uint256));
        // Exact-output must actually deliver the full output. A binding price
        // limit or an output-skimming hook can leave realisedOut < amountOut;
        // refuse rather than silently under-deliver (the recipient asked for a
        // precise amount). Use exact-INPUT against a skimming pool.
        if (realisedOut < amountOut) revert IncompleteOutput(realisedOut, amountOut);
        if (realisedIn > maxAmountIn) revert SlippageExceeded(realisedIn, maxAmountIn);
        amountIn = realisedIn;

        emit SwapExecuted(msg.sender, recipient, inputCurrency, outputCurrency, realisedIn, realisedOut, zeroForOne);
    }

    // -----------------------------------------------------------------
    // IUnlockCallback
    // -----------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @dev Only callable by the PoolManager mid-unlock. Performs the swap,
    ///      settles the input debt by pulling from the payer, and takes the
    ///      output credit to the recipient.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        SwapCallbackData memory cb = abi.decode(data, (SwapCallbackData));

        // Resolve the "no limit" sentinel. v4-core's Pool.swap REJECTS a raw 0
        // on both directions (zeroForOne: 0 <= MIN_SQRT_PRICE; !zeroForOne:
        // 0 <= current price), so 0 means "swap the full tick range", encoded
        // as the min/max sqrt price +/-1 (the widest bound Pool.swap accepts).
        uint160 limit = cb.sqrtPriceLimitX96 == 0
            ? (cb.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
            : cb.sqrtPriceLimitX96;

        // Run the swap. BalanceDelta is from the SWAP'S perspective:
        //   negative on the side the pool RECEIVED from us (we owe it)
        //   positive on the side the pool PAID to us (we're owed)
        BalanceDelta delta = POOL_MANAGER.swap(
            cb.key,
            SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: cb.amountSpecified,
                sqrtPriceLimitX96: limit
            }),
            ""
        );

        // Split into input / output amounts based on swap direction.
        (Currency inputCurrency, Currency outputCurrency, int128 inputDelta, int128 outputDelta) =
            cb.zeroForOne
                ? (cb.key.currency0, cb.key.currency1, delta.amount0(), delta.amount1())
                : (cb.key.currency1, cb.key.currency0, delta.amount1(), delta.amount0());

        // We expect to OWE input (negative) and be OWED output (positive).
        // Any other shape is a malformed swap result.
        if (inputDelta >= 0 || outputDelta <= 0) revert SwapFailed();

        uint256 amountIn = uint256(uint128(-inputDelta));
        uint256 amountOut = uint256(uint128(outputDelta));

        // Settle the input debt: sync the currency, pull from payer, settle.
        POOL_MANAGER.sync(inputCurrency);
        IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(cb.payer, address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();

        // Deliver the full output to the recipient (the router takes no cut).
        POOL_MANAGER.take(outputCurrency, cb.recipient, amountOut);

        // Return both realised legs so each entry point can enforce its own
        // invariant (exact-in checks the output floor; exact-out the input ceiling).
        return abi.encode(amountIn, amountOut);
    }
}
