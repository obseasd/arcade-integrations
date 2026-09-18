// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @dev Canonical Uniswap `SwapRouter02.exactInputSingle`, the STRUCT form,
 *      selector 0x04e45aaf.
 *
 *      Arc mainnet: SwapRouter02 0x53bf6b0684ec7ef91e1387da3d1a1769bc5a6f77 on
 *      the canonical factory 0xf0db7b58379503491d857db50ac9ece64c653918. Its
 *      bytecode carries 0x04e45aaf and NOT the flat 0x122194c5 of our V3 fork's
 *      router (checked on 2026-09-16). The two shapes share no selector, so
 *      pointing `setPool` at the fork's router would revert every buyback.
 *
 *      Why canonical and not the fork: the relaunched platform token lives on
 *      the canonical factory, because bots and aggregators discover pools by
 *      factory address and never saw the fork's pool on 16 September. The
 *      fork's only advantage was `setFeeProtocol`, and it bought nothing once
 *      the LP went into a locker that already collects all of the position's
 *      fees.
 *
 *      SwapRouter02's single-hop call has no `deadline`. Nothing is lost: the
 *      keeper calls the vault inside the block it executes in, never from an
 *      intent signed minutes ahead, and `minAmountOut` is the protection that
 *      matters. `sqrtPriceLimitX96` is always 0 (no partial fill at a price
 *      limit; the floor does that job).
 *
 *      Declared nonpayable here although the real function is payable: the vault
 *      never sends value, and payability does not change selector or calldata.
 */
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/**
 * @title ArcadeBuybackVault
 * @notice Receives the protocol's share of fees and spends most of it buying the
 *         platform token. It is meant to BE the hook's `TREASURY`, so that the
 *         buyback is what the protocol does by default rather than something an
 *         operator remembers to do.
 *
 *         Split on every execution: `reserveBps` to the real treasury, the rest
 *         spent on the market. Shipped at 20 / 80.
 *
 * @dev Design constraints, in the order they mattered.
 *
 *      1. RECEIVING MUST NEVER REVERT. The hook pays this address on every
 *         single trade. A contract that can refuse a transfer would not merely
 *         miss a buyback, it would break fee settlement for every launch at
 *         once. So this contract has no `receive`, no hook, no callback and no
 *         accounting on the way in: a plain ERC20 `transfer` lands here and does
 *         nothing. Everything happens later, on a separate call.
 *
 *      2. THE BUY IS NOT PERMISSIONLESS. It needs a `minAmountOut`, and there is
 *         no on-chain price this contract could derive one from - Arc has no
 *         oracle for the platform token, and a TWAP read from the very pool
 *         being traded is what sandwiching defeats. An open `buyback()` taking a
 *         caller-supplied floor is an invitation: pass 1 wei and keep the
 *         difference. So execution is allow-listed to the keeper, the same trust
 *         boundary the fill keeper already sits on, and the owner can revoke it.
 *
 *      3. THE OUTPUT NEVER LANDS HERE. `sink` receives it directly from the
 *         router. Point it at a burn address for buy-and-burn, or at a vault for
 *         buy-and-hold; the mechanism is a parameter, not a rewrite, because
 *         which one is right is still being decided.
 *
 *      4. ONE VENUE, OWNER-SET. `buyback` does NOT take router calldata. A
 *         contract that forwards arbitrary calldata to an arbitrary address with
 *         its own balance approved is a drain waiting for one mistake in the
 *         allowlist. The pool is fixed by the owner and the only freedom the
 *         caller has is the amount and the floor.
 */
contract ArcadeBuybackVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The asset fees arrive in. USDC in practice.
    IERC20 public immutable QUOTE;
    /// @notice The token being bought.
    address public immutable TOKEN;

    /// @notice Where the reserve share goes. The Safe.
    address public treasury;
    /// @notice Where bought tokens go. A burn address, or a vault.
    address public sink;
    /// @notice Canonical Uniswap SwapRouter02 (struct exactInputSingle). NOT the
    ///         Arcade V3 fork's router, whose flat form this vault cannot call.
    address public router;
    /// @notice Fee tier of the QUOTE/TOKEN pool, e.g. 3000 for 0.3%.
    uint24 public poolFee;

    /// @notice Share of each execution kept by the treasury, in bps. The rest is
    ///         spent buying. 2_000 = 20% reserved, 80% bought.
    uint16 public reserveBps;

    /// @notice When the last buy executed, as a unix timestamp. 0 until the
    ///         first one.
    ///
    /// @dev Stamped, NOT enforced. The keeper paces itself off this instead of
    ///      its own database, so a restart, a wiped cursor table or a second
    ///      keeper cannot produce a burst of buys. Keeping the cadence off-chain
    ///      would make it a property of one server's memory rather than of the
    ///      protocol.
    ///
    ///      Deliberately no minimum interval in the contract: the owner must
    ///      stay able to run an unscheduled buy, and a hard gate here would turn
    ///      a pacing preference into a lockout.
    uint64 public lastBuybackAt;

    /// @notice Addresses allowed to trigger a buy. The keeper.
    mapping(address => bool) public allowedCaller;

    uint16 internal constant BPS = 10_000;
    /// @dev A reserve above this would mean the contract is not really a buyback
    ///      vault any more, and a silent re-purposing is worse than a redeploy.
    uint16 internal constant MAX_RESERVE_BPS = 5_000;

    event TreasurySet(address indexed treasury);
    event SinkSet(address indexed sink);
    event PoolSet(address indexed router, uint24 fee);
    event ReserveBpsSet(uint16 reserveBps);
    event CallerSet(address indexed caller, bool allowed);
    event BoughtBack(uint256 quoteSpent, uint256 tokensBought, uint256 reserved);
    event TokenSwept(address indexed sink, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotAllowedCaller();
    error InvalidReserve();
    error PoolNotSet();
    error NothingToSpend();
    error CannotRescueQuote();

    constructor(
        address quote_,
        address token_,
        address treasury_,
        address sink_,
        uint16 reserveBps_,
        address owner_
    ) Ownable(owner_) {
        if (quote_ == address(0) || token_ == address(0) || treasury_ == address(0) || sink_ == address(0)) {
            revert ZeroAddress();
        }
        if (reserveBps_ > MAX_RESERVE_BPS) revert InvalidReserve();
        QUOTE = IERC20(quote_);
        TOKEN = token_;
        treasury = treasury_;
        sink = sink_;
        reserveBps = reserveBps_;
        emit TreasurySet(treasury_);
        emit SinkSet(sink_);
        emit ReserveBpsSet(reserveBps_);
    }

    // ---------------------------------------------------------------- admin

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice Where bought tokens go. This is the buy-and-burn / buy-and-hold
    ///         switch: a dead address burns, a vault holds.
    function setSink(address s) external onlyOwner {
        if (s == address(0)) revert ZeroAddress();
        sink = s;
        emit SinkSet(s);
    }

    /// @notice The SwapRouter02 and the fee tier of the QUOTE/TOKEN pool. On Arc
    ///         mainnet: `setPool(0x53bf6b0684ec7ef91e1387da3d1a1769bc5a6f77, 10000)`.
    ///
    /// @dev Settable rather than immutable so the buy can follow the token if
    ///      liquidity moves to another fee tier, without stranding the fee
    ///      balance that has already accumulated here.
    function setPool(address router_, uint24 fee_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
        poolFee = fee_;
        emit PoolSet(router_, fee_);
    }

    function setReserveBps(uint16 bps) external onlyOwner {
        if (bps > MAX_RESERVE_BPS) revert InvalidReserve();
        reserveBps = bps;
        emit ReserveBpsSet(bps);
    }

    function setAllowedCaller(address caller, bool allowed) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        allowedCaller[caller] = allowed;
        emit CallerSet(caller, allowed);
    }

    /// @dev Renouncing would freeze the pool config and the caller allowlist with
    ///      no way to rotate a compromised keeper. Ownership must be
    ///      TRANSFERRED, never dropped.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }

    // ------------------------------------------------------------- the buy

    /// @notice Reserve a slice for the treasury and spend the rest buying TOKEN.
    ///
    /// @param amountIn  How much QUOTE to process. Capped at the balance, so a
    ///                  caller can pass type(uint256).max to mean "everything"
    ///                  without racing an inbound fee payment.
    /// @param minAmountOut Floor on the tokens bought, for the spend portion.
    ///
    /// @dev The reserve is sent BEFORE the swap. If the swap reverts the whole
    ///      call unwinds, so this cannot leak the reserve on a failed buy; doing
    ///      it in this order simply keeps the amount arithmetic in one place.
    function buyback(uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 tokensBought)
    {
        if (!allowedCaller[msg.sender] && msg.sender != owner()) revert NotAllowedCaller();
        if (router == address(0)) revert PoolNotSet();

        uint256 bal = QUOTE.balanceOf(address(this));
        uint256 amount = amountIn > bal ? bal : amountIn;
        if (amount == 0) revert NothingToSpend();

        uint256 reserved = (amount * reserveBps) / BPS;
        uint256 spend = amount - reserved;
        if (spend == 0) revert NothingToSpend();

        if (reserved > 0) QUOTE.safeTransfer(treasury, reserved);

        // forceApprove, not approve: a router that leaves a non-zero allowance
        // behind would make the next approve revert on a strict ERC20.
        QUOTE.forceApprove(router, spend);
        tokensBought = ISwapRouter02(router).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(QUOTE),
                tokenOut: TOKEN,
                fee: poolFee,
                recipient: sink, // straight to the sink; nothing bought ever rests here
                amountIn: spend,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        QUOTE.forceApprove(router, 0);

        lastBuybackAt = uint64(block.timestamp);
        emit BoughtBack(spend, tokensBought, reserved);
    }

    /**
     * @notice Push any TOKEN sitting here to the sink.
     *
     * @dev Bought tokens never rest in this contract, the router delivers them
     *      straight to the sink. But TOKEN still arrives here by another route:
     *      the platform's own LP fees are paid in BOTH sides of the pair, so
     *      harvesting them lands USDC (which the buyback spends) and TOKEN
     *      (which has nowhere else to go). Without this it would need `rescue`,
     *      an owner-only escape hatch, for something that happens routinely.
     *
     *      Permissionless, and the destination is storage rather than an
     *      argument, so a caller can only pay gas to move our tokens to our own
     *      sink. Earned TOKEN then ends up exactly where bought TOKEN does.
     */
    function sweepToken() external returns (uint256 amount) {
        amount = IERC20(TOKEN).balanceOf(address(this));
        if (amount == 0) return 0;
        IERC20(TOKEN).safeTransfer(sink, amount);
        emit TokenSwept(sink, amount);
    }

    // -------------------------------------------------------------- rescue

    /// @notice Recover a token that is not the quote asset.
    ///
    /// @dev Deliberately CANNOT move QUOTE. That balance is the buyback budget,
    ///      and an owner able to sweep it would make the whole mechanism a
    ///      promise again rather than something the contract enforces. Use
    ///      `setReserveBps` if the split needs to change.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(QUOTE)) revert CannotRescueQuote();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
