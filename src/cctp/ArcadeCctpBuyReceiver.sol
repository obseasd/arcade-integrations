// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation)
        external
        returns (bool);
}

interface IArcadeLaunchpadBuy {
    /// @return tokensOut actual tokens delivered to msg.sender
    /// @return usdcSpent actual gross USDC spent
    /// @return refund USDC returned to msg.sender (curve near migration)
    function buy(address tokenAddr, uint256 amountUsdcIn, uint256 minTokensOut)
        external
        returns (uint256 tokensOut, uint256 usdcSpent, uint256 refund);
}

interface IV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// Arcade's V3 router uses a FLAT-parameter exactInputSingle (not the canonical
/// Uniswap struct) with no sqrtPriceLimit. This is the venue for the USDC/ETH
/// (SeedETH) pool, which only exists on the V3 factory.
interface IArcadeV3Router {
    function exactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

/**
 * @title ArcadeCctpBuyReceiver
 * @notice "Bridge and buy" landing contract on Arc. A user on another chain
 *         calls CCTP V2 `depositForBurnWithHook` with:
 *           - mintRecipient = this contract
 *           - hookData      = abi.encode(beneficiary, token, minTokensOut,
 *                             ammRouter, v3Router, v3Fee)
 *         Then ANYONE (the user, the app, a relayer) calls `receiveAndBuy` on
 *         Arc with the attested message. In one atomic tx this contract:
 *           1. calls MessageTransmitterV2.receiveMessage -> USDC is minted here,
 *           2. reads the ATTESTED hookData to learn (beneficiary, token, minOut),
 *           3. buys `token` on the launchpad curve with the freshly minted USDC,
 *           4. forwards the bought tokens (and any curve refund) to `beneficiary`.
 *         If the buy reverts (token migrated, slippage, unknown token, ...), the
 *         minted USDC is returned to `beneficiary` so funds are never stuck.
 *
 * @dev Trustless recipient: `beneficiary` is read from the ATTESTED message, not
 *      from the caller, so `receiveAndBuy` is safe to leave permissionless — a
 *      third party can only ever execute the depositor's own committed intent,
 *      never redirect the tokens. The contract holds no funds between calls.
 *
 *      CCTP V2 message layout (verified against circlefin/evm-cctp-contracts):
 *        MessageV2 body starts at byte 148. Within the BurnMessageV2 body:
 *        mintRecipient at byte 36, hookData at byte 228. So in the full
 *        `message`: mintRecipient at byte 184, hookData at byte 376.
 */
/// V4 pool identity, as ArcadeHook._buildPoolKey builds it.
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// ArcadeHook's curve leg. NOTE the arity: the V4 hook returns TWO values
/// (tokensOut, actualGross) where the legacy launchpad returned three. A single
/// shared interface would silently mis-decode one of them.
interface IArcadeHookBuy {
    function buy(address token, uint256 amountIn, uint256 minTokensOut)
        external
        returns (uint256 tokensOut, uint256 actualGross);
}

/// Read-only hook accessors used to rebuild a PoolKey on-chain, so a V4 route
/// needs no extra hookData words and the attested message format is unchanged.
interface IArcadeHookPool {
    function poolIdOf(address token) external view returns (bytes32);
    function poolFeeOf(address token) external view returns (uint24);
}

/// ArcadeV4SwapRouter. Flat args around a PoolKey struct.
interface IArcadeV4Router {
    function exactInputSingle(
        V4PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint160 sqrtPriceLimitX96
    ) external payable returns (uint256 amountOut);
}

contract ArcadeCctpBuyReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMessageTransmitterV2 public immutable messageTransmitter;
    IERC20 public immutable usdc;
    address public immutable launchpad;
    /// V2 router used as an AMM fallback when the token isn't a live curve
    /// token (migrated launch, cirBTC, EURC, any USDC-paired token).
    address public immutable v2Router;

    /// ArcadeHook. On Arc mainnet this REPLACES `launchpad`: PUMP tokens curve
    /// on the hook and graduate into a V4 pool, and no legacy launchpad is
    /// deployed there. Zero on a legacy-only deployment.
    address public immutable hook;
    /// ArcadeV4SwapRouter, the post-graduation venue for a hook launch. Zero on
    /// a legacy-only deployment.
    address public immutable v4Router;
    /// Every ArcadeHook pool is built with this tick spacing.
    int24 private constant V4_TICK_SPACING = 200;
    /// Receives the bridge fee. Immutable so a compromised key can never
    /// redirect it; a new treasury means a new receiver.
    address public immutable treasury;

    /// @notice Target ALL-IN bridge cost, in bps of the burned amount, for a
    ///         FAST transfer. Circle's own fast fee is deducted at mint (it is
    ///         attested in the message as `feeExecuted`), so we only skim the
    ///         REMAINDER up to this target: fee = amount*5/10000 - feeExecuted.
    ///         Net effect: the user always pays ~0.05% total no matter what
    ///         Circle charges on that route (0.01% ETH, 0.013% Base/Arb today),
    ///         and if Circle ever raises its fee past the target we skim zero
    ///         rather than exceeding it. STANDARD transfers are never charged.
    uint256 private constant TARGET_BRIDGE_FEE_BPS = 5;

    /// @notice Fees we skimmed but could NOT deliver to `treasury` (blacklisted
    ///         or frozen). Held here rather than reverting the user's bridge,
    ///         and pushed out later by anyone via claimFees(). A dead treasury
    ///         must cost us the fee, never the user's principal.
    uint256 public pendingFees;
    /// CCTP's fast/standard boundary: minFinalityThreshold <= 1000 is Fast.
    uint32 private constant FAST_FINALITY_MAX = 1000;

    // Byte offsets of fields inside the full CCTP V2 `message`.
    // MessageV2 header is 148 bytes; BurnMessageV2 body then lays out
    // version(4) burnToken(32) mintRecipient(32) amount(32) messageSender(32)
    // maxFee(32) feeExecuted(32) expirationBlock(32) hookData(...).
    uint256 private constant FINALITY_EXECUTED_OFFSET = 144; // header, uint32
    uint256 private constant MINT_RECIPIENT_OFFSET = 184; // body(148) + 36
    uint256 private constant AMOUNT_OFFSET = 216; // body(148) + 68
    uint256 private constant FEE_EXECUTED_OFFSET = 312; // body(148) + 164
    uint256 private constant HOOK_DATA_OFFSET = 376; // body(148) + 228
    // hookData = abi.encode(address beneficiary, address token, uint256 minOut,
    // address ammRouter, address v3Router, uint256 v3Fee, uint256 buyDeadline)
    // = 7 * 32 bytes.
    //   - ammRouter: best V2-style venue (Arcade V2 / XyloNet / ...).
    //   - v3Router + v3Fee: when BOTH non-zero, the AMM leg routes through the
    //     Arcade V3 router at that fee tier instead of V2 (the only venue for
    //     the USDC/ETH pool). The frontend picks exactly ONE AMM venue.
    //   - buyDeadline: unix seconds after which the BUY is abandoned and the
    //     USDC is refunded to the beneficiary instead. See _buyExpired.
    uint256 private constant HOOK_DATA_LEN = 224;

    event BridgeBuy(
        address indexed beneficiary,
        address indexed token,
        uint256 usdcMinted,
        uint256 tokensOut,
        bool bought
    );
    /// Fast-transfer bridge fee skimmed to the treasury.
    event BridgeFeeTaken(uint256 fee);
    /// The buy was abandoned because its quote had expired; USDC was refunded.
    /// Distinct from BridgeBuy(bought=false), which means the routes FAILED --
    /// conflating "we chose not to trade" with "the trade broke" would hide
    /// both.
    event BridgeBuyExpired(
        address indexed beneficiary,
        address indexed token,
        uint256 usdcRefunded,
        uint256 deadline
    );
    /// The treasury could not be paid (blacklisted/frozen); fee held for pull.
    event BridgeFeeDeferred(uint256 fee);
    /// Deferred fees pulled to the treasury.
    event BridgeFeesClaimed(uint256 amount);
    /// Plain bridge (no buy) forwarded to the beneficiary, net of the fee.
    event BridgeForward(address indexed beneficiary, uint256 usdcOut);

    error BadMessage();
    error NotForThisReceiver();
    error NothingMinted();

    /// @param _launchpad Legacy bonding-curve launchpad. MAY be zero on a
    ///        V4-only deployment (Arc mainnet), where `_hook` takes its place.
    /// @param _v2Router Default V2-style AMM venue. MAY be zero where no V2
    ///        router exists; the message can still name one explicitly.
    /// @param _hook ArcadeHook. Zero on a legacy-only deployment.
    /// @param _v4Router ArcadeV4SwapRouter. Zero on a legacy-only deployment.
    constructor(
        address _messageTransmitter,
        address _usdc,
        address _launchpad,
        address _v2Router,
        address _treasury,
        address _hook,
        address _v4Router
    ) {
        require(
            _messageTransmitter != address(0) && _usdc != address(0) && _treasury != address(0),
            "zero addr"
        );
        // The launchpad and V2 router used to be unconditionally required,
        // which made this contract undeployable on a network that has neither -
        // exactly Arc mainnet, where the hook absorbed the launchpad and no V2
        // router is deployed. What actually matters is that SOME curve venue
        // and SOME AMM venue exist, or every bridged buy would refund.
        require(_launchpad != address(0) || _hook != address(0), "no curve venue");
        require(
            _v2Router != address(0) || _v4Router != address(0),
            "no amm venue"
        );
        // A V4 route needs the hook to resolve the pool it should trade in.
        require(_v4Router == address(0) || _hook != address(0), "v4 needs hook");
        messageTransmitter = IMessageTransmitterV2(_messageTransmitter);
        usdc = IERC20(_usdc);
        launchpad = _launchpad;
        v2Router = _v2Router;
        treasury = _treasury;
        hook = _hook;
        v4Router = _v4Router;
    }

    /// @dev Bridge fee for this message, derived ENTIRELY from Circle-attested
    ///      fields so the sender cannot understate it: the burned `amount`, the
    ///      `feeExecuted` Circle actually took, and the executed finality
    ///      threshold. Returns 0 for a standard transfer, and 0 if Circle's own
    ///      fee already meets/exceeds the all-in target.
    function _bridgeFee(bytes calldata message, uint256 minted)
        private
        pure
        returns (uint256 fee)
    {
        uint32 finalityExecuted = uint32(
            uint256(_loadWord(message, FINALITY_EXECUTED_OFFSET)) >> 224
        );
        // Standard transfer: Circle charges nothing and neither do we.
        if (finalityExecuted > FAST_FINALITY_MAX) return 0;

        uint256 amount = uint256(_loadWord(message, AMOUNT_OFFSET));
        uint256 feeExecuted = uint256(_loadWord(message, FEE_EXECUTED_OFFSET));

        uint256 target = (amount * TARGET_BRIDGE_FEE_BPS) / 10_000;
        if (feeExecuted >= target) return 0;
        fee = target - feeExecuted;
        // Never skim more than actually landed (defensive; cannot happen with
        // sane values since minted == amount - feeExecuted).
        if (fee > minted) fee = minted;
    }

    /**
     * @notice Redeem an attested CCTP transfer and buy the committed token.
     * @param message     the CCTP V2 message (mintRecipient must be this contract)
     * @param attestation Circle's attestation for `message`
     */
    function receiveAndBuy(bytes calldata message, bytes calldata attestation)
        external
        nonReentrant
    {
        // EXACT length, mirroring receiveAndForward (audit 2026-07-11 F-2).
        if (message.length != HOOK_DATA_OFFSET + HOOK_DATA_LEN) revert BadMessage();

        // This message must mint to us, else `minted` below would be 0 anyway,
        // but check explicitly so a mis-addressed message fails loudly.
        address mintRecipient = address(
            uint160(uint256(_loadWord(message, MINT_RECIPIENT_OFFSET)))
        );
        if (mintRecipient != address(this)) revert NotForThisReceiver();

        // Attested intent — cannot be forged by the caller.
        (
            address beneficiary,
            address token,
            uint256 minTokensOut,
            address ammRouter,
            address v3Router,
            uint256 v3Fee,
            uint256 buyDeadline
        ) = abi.decode(
                message[HOOK_DATA_OFFSET:HOOK_DATA_OFFSET + HOOK_DATA_LEN],
                (address, address, uint256, address, address, uint256, uint256)
            );
        if (beneficiary == address(0) || token == address(0)) revert BadMessage();
        // Frontend-chosen V2-style venue (best route); fall back to the default.
        address router = ammRouter == address(0) ? v2Router : ammRouter;
        bool useV3 = v3Router != address(0) && v3Fee != 0;

        uint256 balBefore = usdc.balanceOf(address(this));
        // Snapshot deferred fees too: a fee we could NOT hand to the treasury
        // stays in this contract, so it inflates our balance exactly like a
        // curve refund does. Without netting it out, `leftover` below would
        // ship it to the beneficiary while `pendingFees` kept the credit --
        // permanently bricking claimFees() for everyone (audit round 3).
        uint256 pfBefore = pendingFees;
        // Mints USDC to this contract (mintRecipient). Reverts if already used.
        messageTransmitter.receiveMessage(message, attestation);
        uint256 minted = usdc.balanceOf(address(this)) - balBefore;
        if (minted == 0) revert NothingMinted();

        // Skim the fast-transfer bridge fee before anything else, so the buy
        // and every refund path below operate on the net amount.
        minted -= _takeBridgeFee(message, minted);
        if (minted == 0) revert NothingMinted();

        // STALE QUOTE GUARD. minTokensOut is fixed at BURN time, this message
        // stays claimable forever, and claiming is permissionless -- so without
        // a deadline the slippage band is stale by construction and a bot can
        // claim at a moment of its choosing and extract the whole band. A
        // deadline bounds that window: past it we refund USDC rather than
        // execute a buy at a price the user quoted in another market.
        //
        // Deliberately AFTER _takeBridgeFee: Circle already performed the
        // transfer and charged for it, so the fee is owed whether or not we
        // buy. Skipping it here would make expiry a fee dodge.
        //
        // buyDeadline == 0 means "no deadline": an explicit opt-out for a
        // hand-crafted hookData. Only the BURNER can set it, spending their own
        // USDC, so opting out is self-harm at worst and never a lever on anyone
        // else. The frontend always sets one.
        //
        // An earlier version of this comment justified the branch as protecting
        // "every in-flight message burned before this build". That was FALSE:
        // pre-build encoders emitted 6 hookData words (568-byte messages) naming
        // an OLDER receiver, and this build requires exactly 600 bytes AND
        // mintRecipient == address(this), so no legacy message can reach this
        // line -- the set it claimed to protect is empty. The behaviour is right
        // for the reason above; the old reason was invented. This repo keeps
        // getting bitten by exactly this (see the locker's "cannot happen" note
        // fixed in f64c384): a false rationale is worse than none, because it
        // tells the next reader not to re-derive the branch.
        if (buyDeadline != 0 && block.timestamp > buyDeadline) {
            usdc.safeTransfer(beneficiary, minted);
            emit BridgeBuyExpired(beneficiary, token, minted, buyDeadline);
            return;
        }

        // Route 1: the bonding-curve launchpad (works only for a live,
        // non-migrated curve token). Skipped entirely where no legacy launchpad
        // is deployed; the hook branch below is the mainnet equivalent.
        if (launchpad != address(0)) {
        usdc.forceApprove(launchpad, minted);
        try IArcadeLaunchpadBuy(launchpad).buy(token, minted, minTokensOut) returns (
            uint256 tokensOut,
            uint256,
            uint256
        ) {
            if (tokensOut > 0) {
                IERC20(token).safeTransfer(beneficiary, tokensOut);
            }
            // Any USDC this flow left behind (curve refund near migration) goes
            // to the beneficiary. Uses balBefore as the baseline so a pre-
            // existing stuck balance is never swept into this transfer.
            // Net out both a pre-existing stuck balance AND anything we just
            // deferred: only the curve's own refund belongs to the beneficiary.
            uint256 leftover =
                usdc.balanceOf(address(this)) - balBefore - (pendingFees - pfBefore);
            if (leftover > 0) usdc.safeTransfer(beneficiary, leftover);
            usdc.forceApprove(launchpad, 0);
            emit BridgeBuy(beneficiary, token, minted, tokensOut, true);
            return;
        } catch {
            // Not a live curve token (migrated / cirBTC / EURC / unknown) — fall
            // through to the AMM.
            usdc.forceApprove(launchpad, 0);
        }
        }

        // Route 1b: the ArcadeHook curve. Same shape as Route 1 and the same
        // reason for the try/catch - a token that has already graduated, or was
        // never a hook launch, reverts and falls through to the AMM. Kept as a
        // separate block rather than folded into Route 1 because the hook
        // returns TWO values where the launchpad returns three, so one shared
        // interface would mis-decode.
        if (hook != address(0)) {
            usdc.forceApprove(hook, minted);
            try IArcadeHookBuy(hook).buy(token, minted, minTokensOut) returns (
                uint256 tokensOut,
                uint256
            ) {
                if (tokensOut > 0) {
                    IERC20(token).safeTransfer(beneficiary, tokensOut);
                }
                // Same netting as Route 1: baseline off balBefore so a
                // pre-existing stuck balance is never swept, and subtract what
                // we just deferred so a fee we could not pay out does not get
                // shipped to the beneficiary while pendingFees still credits it.
                uint256 leftoverHook =
                    usdc.balanceOf(address(this)) - balBefore - (pendingFees - pfBefore);
                if (leftoverHook > 0) usdc.safeTransfer(beneficiary, leftoverHook);
                usdc.forceApprove(hook, 0);
                emit BridgeBuy(beneficiary, token, minted, tokensOut, true);
                return;
            } catch {
                usdc.forceApprove(hook, 0);
            }
        }

        // Route 1c: the token's V4 pool, for a hook launch that has graduated.
        // The PoolKey is rebuilt on-chain from poolIdOf / poolFeeOf rather than
        // carried in hookData, so the attested message keeps its exact length
        // and the burn-side encoder does not change. `fee` MUST be read, not
        // assumed: it is the CLANKER tier, or 0 on a PUMP pool where the hook
        // captures instead, and a wrong fee hashes to a pool that does not
        // exist.
        if (v4Router != address(0)) {
            try IArcadeHookPool(hook).poolIdOf(token) returns (bytes32 pid) {
                if (pid != bytes32(0)) {
                    // Defaulting to 0 when poolFeeOf reverts is safe in both
                    // directions rather than a guess: 0 IS the real fee on a
                    // PUMP pool (the hook captures instead), and if it is wrong
                    // the derived key names a pool that does not exist, so the
                    // router reverts and this falls through to the refund. It
                    // can never route into the WRONG pool, only into none.
                    uint24 poolFee = 0;
                    try IArcadeHookPool(hook).poolFeeOf(token) returns (uint24 f) {
                        poolFee = f;
                    } catch {}
                    address u = address(usdc);
                    (address c0, address c1) = u < token ? (u, token) : (token, u);
                    V4PoolKey memory key = V4PoolKey({
                        currency0: c0,
                        currency1: c1,
                        fee: poolFee,
                        tickSpacing: V4_TICK_SPACING,
                        hooks: hook
                    });
                    usdc.forceApprove(v4Router, minted);
                    try
                        IArcadeV4Router(v4Router).exactInputSingle(
                            key,
                            u == c0,
                            minted,
                            minTokensOut,
                            beneficiary,
                            0
                        )
                    returns (uint256 amountOut) {
                        usdc.forceApprove(v4Router, 0);
                        emit BridgeBuy(beneficiary, token, minted, amountOut, true);
                        return;
                    } catch {
                        usdc.forceApprove(v4Router, 0);
                    }
                }
            } catch {}
        }

        // Route 2: AMM. Exactly ONE venue, chosen by the frontend, delivered
        // straight to the beneficiary.
        if (useV3) {
            // V3: USDC -> token via the Arcade V3 router at the chosen fee tier.
            // This is the only venue for the USDC/ETH (SeedETH) pool.
            usdc.forceApprove(v3Router, minted);
            try
                IArcadeV3Router(v3Router).exactInputSingle(
                    address(usdc),
                    token,
                    uint24(v3Fee),
                    beneficiary,
                    minted,
                    minTokensOut,
                    block.timestamp
                )
            returns (uint256 amountOut) {
                usdc.forceApprove(v3Router, 0);
                emit BridgeBuy(beneficiary, token, minted, amountOut, true);
                return;
            } catch {
                usdc.forceApprove(v3Router, 0);
            }
        } else if (router != address(0)) {
            // V2: USDC -> token via the frontend-chosen V2-style router
            // (XyloNet stable pool for EURC, Arcade V2 for migrated launches).
            //
            // The router != 0 guard is NOT decorative. `router` falls back to
            // v2Router, which is address(0) on a V4-only deployment, and
            // forceApprove(address(0), ...) REVERTS on Circle USDC. Without
            // this, a token that filled on neither the curve nor the V4 pool
            // reverted the whole claim instead of refunding - and since the
            // attested message stays claimable, that is a bridge transfer stuck
            // with no way out rather than a graceful refund. Found by
            // test_v4_refundsWhenNoVenueFills.
            usdc.forceApprove(router, minted);
            address[] memory path = new address[](2);
            path[0] = address(usdc);
            path[1] = token;
            try
                IV2Router(router).swapExactTokensForTokens(
                    minted,
                    minTokensOut,
                    path,
                    beneficiary,
                    block.timestamp
                )
            returns (uint256[] memory amounts) {
                usdc.forceApprove(router, 0);
                emit BridgeBuy(
                    beneficiary,
                    token,
                    minted,
                    amounts.length > 0 ? amounts[amounts.length - 1] : 0,
                    true
                );
                return;
            } catch {
                usdc.forceApprove(router, 0);
            }
        }

        // Both routes failed — return the bridged USDC so funds are never stuck.
        usdc.safeTransfer(beneficiary, minted);
        emit BridgeBuy(beneficiary, token, minted, 0, false);
    }

    /// @dev Compute + transfer the bridge fee. Returns the amount skimmed.
    function _takeBridgeFee(bytes calldata message, uint256 minted)
        private
        returns (uint256 fee)
    {
        fee = _bridgeFee(message, minted);
        if (fee > 0) {
            // NEVER let paying ourselves brick the user's transfer (audit
            // 2026-07-11). `treasury` is immutable with no setter; if it is
            // ever USDC-blacklisted or frozen, a hard transfer here would
            // revert the whole receiveAndBuy/receiveAndForward. And because
            // destinationCaller is pinned to this contract and there is no
            // rescue path, that does not merely delay the bridge -- it makes
            // every in-flight transfer PERMANENTLY unmintable.
            //
            // This is the exact failure mode ArcadeLaunchpad fixed hours before
            // this contract shipped ("a USDC-blacklisted or frozen treasury
            // would have reverted EVERY createToken permanently"), via
            // _safePayUsdc + a pull. The receiver never got the same treatment.
            // So: a dead treasury costs us the FEE, never the user's principal.
            (bool ok, bytes memory ret) = address(usdc).call(
                abi.encodeWithSelector(IERC20.transfer.selector, treasury, fee)
            );
            // `ret.length >= 32` before decoding: abi.decode reverts on a
            // short return, which would revert INSIDE the guard whose whole
            // job is to prevent a revert. ArcadeV3SwapRouter._pay and
            // ArcadeV3Locker._payOrCredit both carry this gate (M-14); this
            // contract was the one sibling that never got it.
            if (ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))))) {
                emit BridgeFeeTaken(fee);
            } else {
                pendingFees += fee;
                emit BridgeFeeDeferred(fee);
            }
        }
    }

    /**
     * @notice Redeem an attested CCTP transfer WITHOUT buying: skim the
     *         fast-transfer bridge fee and forward the rest to the beneficiary.
     *         This is the plain-bridge path. hookData carries only the
     *         beneficiary (32 bytes), since there is no token/route to commit.
     * @dev Same trustless property as receiveAndBuy: the beneficiary comes from
     *      the ATTESTED message, so this is safe to leave permissionless.
     */
    function receiveAndForward(bytes calldata message, bytes calldata attestation)
        external
        nonReentrant
    {
        // EXACT length (audit 2026-07-11 F-2): a `>=` here also accepts a BUY
        // message (600 bytes on this build), whose first hookData word decodes
        // as the beneficiary, so funds are not misrouted but the committed buy
        // is silently skipped. Anyone could front-run receiveAndBuy with this
        // and cancel the user's buy (nonce burned, plain USDC delivered
        // instead). Exact lengths make the two entrypoints mutually exclusive,
        // and they stay so as hookData grows.
        if (message.length != HOOK_DATA_OFFSET + 32) revert BadMessage();

        address mintRecipient = address(
            uint160(uint256(_loadWord(message, MINT_RECIPIENT_OFFSET)))
        );
        if (mintRecipient != address(this)) revert NotForThisReceiver();

        address beneficiary = address(
            uint160(uint256(_loadWord(message, HOOK_DATA_OFFSET)))
        );
        if (beneficiary == address(0)) revert BadMessage();

        uint256 balBefore = usdc.balanceOf(address(this));
        messageTransmitter.receiveMessage(message, attestation);
        uint256 minted = usdc.balanceOf(address(this)) - balBefore;
        if (minted == 0) revert NothingMinted();

        minted -= _takeBridgeFee(message, minted);
        if (minted > 0) usdc.safeTransfer(beneficiary, minted);
        emit BridgeForward(beneficiary, minted);
    }

    /// @notice Push any deferred fees to the treasury. Permissionless: the
    ///         destination is immutable, so there is nobody to trust and
    ///         nothing to gate. Reverts if the treasury still cannot receive,
    ///         which is fine -- unlike inside a bridge, failing here costs
    ///         nothing but the caller's gas.
    function claimFees() external nonReentrant {
        uint256 amount = pendingFees;
        if (amount == 0) revert NothingMinted();
        pendingFees = 0;
        usdc.safeTransfer(treasury, amount);
        emit BridgeFeesClaimed(amount);
    }

    /// @dev Read a 32-byte word at `offset` inside the `message` calldata bytes.
    function _loadWord(bytes calldata message, uint256 offset)
        private
        pure
        returns (bytes32 v)
    {
        assembly {
            v := calldataload(add(message.offset, offset))
        }
    }
}
