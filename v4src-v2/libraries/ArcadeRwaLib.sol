// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ArcadeV4Curve} from "./ArcadeV4Curve.sol";
import {ArcadeHookLib} from "./ArcadeHookLib.sol";
import {ArcadeHook, IArcadeTwitterEscrowV4Min} from "../ArcadeHook.sol";
import {IArcadeDividendDistributor} from "../interfaces/IArcadeDividendDistributor.sol";
import {ArcadeRwaLaunchToken} from "../../src/launchpad/ArcadeRwaLaunchToken.sol";

/**
 * @title ArcadeRwaLib
 * @notice Delegatecall library for the RWA launch mode. The ArcadeHook is at the
 *         EIP-170 bytecode ceiling, so the RWA-specific heavy logic lives here
 *         (public functions run via delegatecall in the hook's context, like
 *         ArcadeHookLib) and the hook keeps only a thin branch + storage.
 *
 *         computeSplit/splitAmount are the pure ECONOMIC CORE (BaseStonk-style
 *         single-tax 3-way split, holders-floor). createRwaLaunch orchestrates a
 *         full RWA launch: deploy the dividend token, register the distributor,
 *         seed single-sided against the (allowlisted) quote, and store the
 *         immutable fee config. Anti-sniper + the always-quote dividend accrual on
 *         swaps are wired in later slices.
 */
library ArcadeRwaLib {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Max price impact (bps of the sqrtPrice) the harvest's token->quote
    ///         conversion may cause. Bounds MEV: a sandwicher can only make the
    ///         conversion fill this far from spot; the rest routes to treasury as
    ///         the M-1 residual, capping the extractable value below the LP-fee cost
    ///         of the sandwich (audit MEDIUM-1).
    uint256 internal constant MAX_CONVERT_SLIP_BPS = 300; // ~3% on sqrt (~6% on price)

    // ------------------------------------------------------------------
    // Fee-split bounds (spec section 6)
    // ------------------------------------------------------------------

    uint16 internal constant MIN_TAX_BPS = 100; // 1%
    uint16 internal constant MAX_TAX_BPS = 300; // 3%
    uint16 internal constant PLATFORM_CAP_BPS = 100; // min(half, 1% absolute)

    error InvalidTax();
    error QuoteNotAllowed();
    error DistributorNotSet();

    /// @dev Mirrors of ArcadeHookLib events (emitted from the hook via delegatecall).
    event EscrowCreditFailed(uint256 indexed positionId, uint8 slot, uint256 amount);
    event TokenCredited(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Compute + validate the immutable 3-way split from the creator's
    ///         total tax and chosen holders portion. Platform = min(tax/2, 1%); the
    ///         creator freely splits the REST with holders anywhere in [0, remainder]
    ///         (0% = dividends off / plain creator-fee launch; remainder = all to holders).
    function computeSplit(uint16 taxBps, uint16 holdersBps)
        internal
        pure
        returns (uint16 platformBps, uint16 creatorBps, uint16 holdersOut)
    {
        if (taxBps < MIN_TAX_BPS || taxBps > MAX_TAX_BPS) revert InvalidTax();
        uint16 half = taxBps / 2;
        platformBps = half < PLATFORM_CAP_BPS ? half : PLATFORM_CAP_BPS;
        uint16 remainder = taxBps - platformBps;
        // Holders share is FULLY FLEXIBLE: 0 (creator keeps the whole remainder) up
        // to the whole remainder (creator keeps nothing). 0% is allowed so an RWA
        // launch can run with dividends effectively off (a plain creator-fee launch).
        if (holdersBps > remainder) revert InvalidTax();
        holdersOut = holdersBps;
        creatorBps = remainder - holdersBps;
        // Invariant: platformBps + creatorBps + holdersOut == taxBps (exact).
    }

    /// @notice Split a per-trade skim (quote units) using a precomputed bps split.
    ///         Platform + creator floor; holders takes the remainder (no dust).
    function splitAmount(uint256 amount, uint16 taxBps, uint16 platformBps, uint16 creatorBps)
        internal
        pure
        returns (uint256 platformAmt, uint256 creatorAmt, uint256 holdersAmt)
    {
        if (taxBps == 0) return (0, 0, 0);
        platformAmt = (amount * platformBps) / taxBps;
        creatorAmt = (amount * creatorBps) / taxBps;
        holdersAmt = amount - platformAmt - creatorAmt;
    }

    // ------------------------------------------------------------------
    // Launch orchestration (public => delegatecalled in the hook's context)
    // ------------------------------------------------------------------

    /// @dev Value inputs bundled to dodge stack-too-deep. All storage refs are the
    ///      hook's own state, passed by slot pointer.
    struct RwaCreate {
        string name;
        string symbol;
        address quote; // allowlisted RWA quote asset (Phase 1: USYC)
        uint16 taxBps; // 100..300
        uint16 holdersBps; // creator-chosen holders portion (validated)
        uint256 startMcap; // start market cap in quote units (0..100k, hook-clamped)
        address creator; // = msg.sender at the hook entrypoint
        address creator2; // optional alternate recipient of the creator cut ("Another wallet"); 0 = none
        uint16 creator2Bps; // creator2's share of the creator cut (0..10000; 10000 = 100%)
        address distributor; // the wired dividend distributor
        address custody; // POOL_MANAGER: token custodian in V4, excluded from S
        address graveyardSink; // permanent, excluded-from-S sweep sink (MED-1)
        address twitterEscrow; // nonzero => route the creator's quote cut to a @-gated escrow slot
        bool hasDevBuy; // exclude the creator from S for the dividend bootstrap
    }

    function createRwaLaunch(
        IPoolManager pm,
        RwaCreate memory p,
        mapping(address => bool) storage registeredLaunches,
        address[] storage allTokens,
        mapping(address => address) storage quoteAssetOf,
        mapping(address => uint24) storage poolFeeOf,
        mapping(address => PoolId) storage poolIdOf,
        mapping(PoolId => ArcadeHook.CurveState) storage curveStates,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners,
        mapping(address => ArcadeHook.RwaConfig) storage rwaConfigs,
        mapping(address => ArcadeHook.ClankerPos) storage clankerPos,
        mapping(PoolId => uint40) storage lastTradeAt
    ) public returns (address tokenAddr, PoolId poolId) {
        if (p.distributor == address(0)) revert DistributorNotSet();
        computeSplit(p.taxBps, p.holdersBps); // validate the tax split early (result recomputed below)

        // Deploy the dividend-paying token; the full supply mints to the hook
        // (address(this) under delegatecall) => the mint recipient is the hook,
        // which the distributor excludes from the share base (audit HIGH-A).
        tokenAddr = address(
            new ArcadeRwaLaunchToken(p.name, p.symbol, ArcadeV4Curve.TOTAL_SUPPLY, address(this), p.distributor)
        );
        registeredLaunches[tokenAddr] = true;
        allTokens.push(tokenAddr);
        quoteAssetOf[tokenAddr] = p.quote; // set BEFORE the seed unlock reads it

        // The tax is the pool's NATIVE V4 LP fee (like CLANKER): it accrues into
        // the locked position on every trade (no hook take -- a take can't work on
        // a single-sided pool with no quote reserves mid-swap) and is collected +
        // split 3-way + accrued by harvestRwaFees(). taxBps (100..300) -> V4 fee
        // units (1e6 = 100%): *100, matching _tierToV4Fee.
        uint24 nativeFee = uint24(p.taxBps) * 100;
        poolFeeOf[tokenAddr] = nativeFee;

        // Canonical pool key: quote paired with the token, sorted ascending.
        PoolKey memory key = PoolKey({
            currency0: p.quote < tokenAddr ? Currency.wrap(p.quote) : Currency.wrap(tokenAddr),
            currency1: p.quote < tokenAddr ? Currency.wrap(tokenAddr) : Currency.wrap(p.quote),
            fee: nativeFee,
            tickSpacing: 200,
            hooks: IHooks(address(this))
        });
        poolId = key.toId();
        poolIdOf[tokenAddr] = poolId;

        // RWA is a DIRECT launch (no bonding curve): Graduated from the first swap.
        curveStates[poolId] = ArcadeHook.CurveState({
            virtualUsdcReserve: 0,
            realUsdcReserve: 0,
            tokensSold: 0,
            mode: uint8(ArcadeHook.LaunchMode.RWA),
            status: 2, // Graduated
            creator: p.creator,
            creator2: p.creator2,
            creator2Bps: p.creator2Bps
        });
        feeOwners[poolId] = ArcadeHook.FeeOwner({
            creator: p.creator,
            creator2: p.creator2, // "Another wallet" recipient of the creator cut
            creator2Bps: p.creator2Bps,
            feeTierBps: 0,
            twitterEscrow: p.twitterEscrow, // @-gated escrow for the creator's quote cut (0 = direct)
            slotIndex: 0
        });
        {
            (uint16 platformBps, uint16 creatorBps, uint16 holdersOut) = computeSplit(p.taxBps, p.holdersBps);
            rwaConfigs[tokenAddr] = ArcadeHook.RwaConfig({
                taxBps: p.taxBps,
                platformBps: platformBps,
                creatorBps: creatorBps,
                holdersBps: holdersOut
            });
        }

        // Register with the dividend distributor. Exclude the V4 token custodian
        // (PoolManager) and the permanent graveyard sink from the share base.
        address[] memory excl = new address[](2);
        excl[0] = p.custody;
        excl[1] = p.graveyardSink;
        IArcadeDividendDistributor(p.distributor).registerLaunch(
            tokenAddr, p.quote, p.creator, p.hasDevBuy ? 1 : 0, excl
        );

        // Seed the full supply single-sided into the locked V4 LP against the quote
        // at the starting market cap (reuses the CLANKER seed; quote-generalized).
        ArcadeHookLib.launchDirect(pm, Currency.wrap(p.quote), clankerPos, tokenAddr, key, poolId, p.startMcap);

        // Start the graveyard clock (a never-traded RWA pool is sweepable later).
        lastTradeAt[poolId] = uint40(block.timestamp);
    }

    // ------------------------------------------------------------------
    // Swap-time dividend accrual (always-quote-side capture + 3-way split)
    // ------------------------------------------------------------------

    /// @dev PoolManager.take that reports a recipient revert instead of bubbling it.
    function _tryTake(IPoolManager pm, Currency currency, address to, uint256 amount) internal returns (bool) {
        try pm.take(currency, to, amount) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Take `amount` to the hook and credit `to` a pending pull-payment: the
    ///      one fallback every leg of the harvest shares when a recipient rejects
    ///      the transfer.
    function _creditPending(
        IPoolManager pm,
        mapping(address => mapping(address => uint256)) storage pending,
        Currency currency,
        address to,
        uint256 amount
    ) internal {
        pm.take(currency, address(this), amount);
        address tokenAddr = Currency.unwrap(currency);
        pending[tokenAddr][to] += amount;
        emit TokenCredited(tokenAddr, to, amount); // parity with ArcadeHookLib (audit LOW-3)
    }

    /// @dev Best-effort PoolManager.take: on a recipient revert, take to the hook
    ///      and credit a pending pull-payment (mirrors ArcadeHookLib._safeTake).
    function _safeTake(
        IPoolManager pm,
        mapping(address => mapping(address => uint256)) storage pending,
        Currency currency,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0 || to == address(0)) return;
        if (_tryTake(pm, currency, to, amount)) return;
        _creditPending(pm, pending, currency, to, amount);
    }

    function _pos(int128 x) internal pure returns (uint256) {
        return x > 0 ? uint256(uint128(x)) : 0;
    }

    function _neg(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : 0;
    }

    /// @notice Permissionless RWA fee HARVEST (called from the hook's kind-5
    ///         unlock). The tax accrues into the locked position as the pool's
    ///         native LP fee; this collects it (quote from buys + token from sells),
    ///         CONVERTS the token part to quote via a swap through the same pool
    ///         (batched, low-MEV = Ponks' "convert on-chain"), then routes the total
    ///         3-way: platform -> treasury, creator -> creator (both pull-safe),
    ///         holders -> the distributor (+accrue). Holders are ALWAYS paid in quote.
    /// @dev Value inputs for the harvest, bundled to keep param counts (and the
    ///      stack) shallow under via_ir. The hook resolves these from its storage.
    struct HarvestCtx {
        address token;
        address quoteAddr;
        uint24 poolFee;
        address treasury;
        address distributor;
        // The permanent, dividend-EXCLUDED sink (== the hook's immutable
        // rwaGraveyardSink). The token-side partial-fill residual is routed here,
        // NOT to the rotatable treasury (RWA system audit MEDIUM-1): a launch
        // token parked at the treasury would desync the distributor's share base
        // the moment the treasury is rotated (S understated -> reserve insolvency
        // + a full-history over-claim via excludeHolder). The sink is excluded at
        // every launch's registration, so a residual here never pollutes S.
        address sink;
    }

    function harvestRwaUnlock(
        IPoolManager pm,
        HarvestCtx memory ctx,
        mapping(address => ArcadeHook.RwaConfig) storage rwaConfigs,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners,
        mapping(address => ArcadeHook.ClankerPos) storage clankerPos,
        mapping(address => mapping(address => uint256)) storage pending
    ) public {
        Currency quote = Currency.wrap(ctx.quoteAddr);
        bool quoteIs0 = ctx.quoteAddr < ctx.token;
        PoolKey memory key = PoolKey({
            currency0: quoteIs0 ? quote : Currency.wrap(ctx.token),
            currency1: quoteIs0 ? Currency.wrap(ctx.token) : quote,
            fee: ctx.poolFee,
            tickSpacing: 200,
            hooks: IHooks(address(this))
        });
        uint256 totalQuote =
            _collectAndConvert(pm, key, quoteIs0, clankerPos[ctx.token], ctx.token, ctx.sink, pending);
        if (totalQuote == 0) return;
        quote; // silence unused (helpers derive it from ctx.quoteAddr)
        _splitAndRoute(pm, pending, ctx, key.toId(), totalQuote, rwaConfigs, feeOwners);
    }

    /// @dev Realize the position's accrued fees (quote from buys + token from sells),
    ///      convert the token part to quote via a swap through the same pool, and
    ///      settle any partial-fill residual pull-safe to the dividend-EXCLUDED sink
    ///      (audit M-1 + RWA system audit MEDIUM-1: NEVER the rotatable treasury,
    ///      which would desync the distributor share base on a treasury rotation).
    function _collectAndConvert(
        IPoolManager pm,
        PoolKey memory key,
        bool quoteIs0,
        ArcadeHook.ClankerPos memory pos,
        address token,
        address residualSink,
        mapping(address => mapping(address => uint256)) storage pending
    ) internal returns (uint256) {
        (, BalanceDelta fees) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );
        uint256 quoteFee = _pos(quoteIs0 ? fees.amount0() : fees.amount1());
        uint256 tokenFee = _pos(quoteIs0 ? fees.amount1() : fees.amount0());
        if (tokenFee == 0) return quoteFee;

        bool zeroForOne = !quoteIs0; // token is the input side of a token->quote swap
        // Bound the conversion's price impact to MAX_CONVERT_SLIP_BPS from spot so a
        // sandwich can only push the fill this far (the rest partial-fills -> the
        // M-1 residual -> treasury), keeping the extractable value below the LP-fee
        // cost of the sandwich (audit MEDIUM-1).
        uint160 limit;
        {
            (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
            limit = zeroForOne
                ? uint160((uint256(sqrtP) * (10_000 - MAX_CONVERT_SLIP_BPS)) / 10_000)
                : uint160((uint256(sqrtP) * (10_000 + MAX_CONVERT_SLIP_BPS)) / 10_000);
            if (zeroForOne && limit < TickMath.MIN_SQRT_PRICE + 1) limit = TickMath.MIN_SQRT_PRICE + 1;
            if (!zeroForOne && limit > TickMath.MAX_SQRT_PRICE - 1) limit = TickMath.MAX_SQRT_PRICE - 1;
        }
        BalanceDelta sd = pm.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(tokenFee), sqrtPriceLimitX96: limit}),
            ""
        );
        // Partial-fill residual (thin quote depth) -> the EXCLUDED sink (never the
        // rotatable treasury); holders stay 100% quote.
        uint256 consumed = _neg(quoteIs0 ? sd.amount1() : sd.amount0());
        if (tokenFee > consumed) _safeTake(pm, pending, Currency.wrap(token), residualSink, tokenFee - consumed);
        return quoteFee + _pos(quoteIs0 ? sd.amount0() : sd.amount1());
    }

    /// @dev Split totalQuote per the launch config and route: platform -> treasury,
    ///      creator -> creator/escrow, holders -> distributor (+accrue).
    function _splitAndRoute(
        IPoolManager pm,
        mapping(address => mapping(address => uint256)) storage pending,
        HarvestCtx memory ctx,
        PoolId poolId,
        uint256 totalQuote,
        mapping(address => ArcadeHook.RwaConfig) storage rwaConfigs,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners
    ) internal {
        Currency quote = Currency.wrap(ctx.quoteAddr);
        uint256 platformAmt;
        uint256 creatorAmt;
        uint256 holdersAmt;
        {
            ArcadeHook.RwaConfig memory cfg = rwaConfigs[ctx.token];
            (platformAmt, creatorAmt, holdersAmt) =
                splitAmount(totalQuote, cfg.taxBps, cfg.platformBps, cfg.creatorBps);
        }
        _safeTake(pm, pending, quote, ctx.treasury, platformAmt);
        _payCreatorCut(pm, pending, quote, ctx.quoteAddr, poolId, feeOwners, creatorAmt);
        if (holdersAmt > 0) {
            // The holders leg is pull-safe like the other two (audit 2026-09-18
            // LOW-1): a transfer-gated quote whose issuer blocks the distributor
            // must not brick every harvest of that quote and strand the platform
            // and creator legs with it. On a rejected take nothing is accrued
            // (the distributor never received the funds, so its reserve must not
            // say it did) and the amount follows the treasury leg's own failure
            // route, a pending credit to the treasury: the distributor's precedent
            // for a holders bucket it cannot serve (accrue below MIN_SHARE_BASE
            // forwards to the treasury). Nothing is lost, and the next harvest
            // after the issuer unblocks the distributor accrues normally.
            if (_tryTake(pm, quote, ctx.distributor, holdersAmt)) {
                IArcadeDividendDistributor(ctx.distributor).accrue(ctx.token, holdersAmt);
            } else {
                _creditPending(pm, pending, quote, ctx.treasury, holdersAmt);
            }
        }
    }

    /// @dev Pay the creator's QUOTE cut: to a Twitter-@-gated escrow slot if the
    ///      launch attributed fees to a handle, else direct to the creator. Both
    ///      pull-safe. Extracted from harvestRwaUnlock to keep its stack shallow.
    function _payCreatorCut(
        IPoolManager pm,
        mapping(address => mapping(address => uint256)) storage pending,
        Currency quote,
        address quoteAddr,
        PoolId poolId,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners,
        uint256 creatorAmt
    ) internal {
        if (creatorAmt == 0) return;
        ArcadeHook.FeeOwner memory fo = feeOwners[poolId];
        if (fo.twitterEscrow != address(0)) {
            _safeTake(pm, pending, quote, fo.twitterEscrow, creatorAmt);
            uint256 positionId = uint256(PoolId.unwrap(poolId));
            try IArcadeTwitterEscrowV4Min(fo.twitterEscrow).creditSlot(positionId, fo.slotIndex, quoteAddr, creatorAmt) {}
            catch {
                emit EscrowCreditFailed(positionId, fo.slotIndex, creatorAmt);
            }
        } else if (fo.creator2 != address(0) && fo.creator2Bps > 0) {
            // "Another wallet": route creator2Bps of the creator cut to creator2,
            // the remainder to the creator (both in quote). 10000 bps = 100% to creator2.
            uint256 c2 = (creatorAmt * fo.creator2Bps) / 10_000;
            if (c2 > 0) _safeTake(pm, pending, quote, fo.creator2, c2);
            uint256 c1 = creatorAmt - c2;
            if (c1 > 0) _safeTake(pm, pending, quote, fo.creator, c1);
        } else {
            _safeTake(pm, pending, quote, fo.creator, creatorAmt);
        }
    }
}
