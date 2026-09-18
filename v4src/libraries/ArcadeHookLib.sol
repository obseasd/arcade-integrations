// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {ArcadeV4Curve} from "./ArcadeV4Curve.sol";
import {ArcadeV4Math} from "./ArcadeV4Math.sol";
import {ArcadeHook, IArcadeTwitterEscrowV4Min} from "../ArcadeHook.sol";
import {ArcadeLaunchToken} from "../../src/launchpad/ArcadeLaunchToken.sol";

/// @title ArcadeHookLib
/// @notice EXTERNAL library carrying the ArcadeHook fee-routing + LP
///         seeding/settlement code so the immutable ArcadeHook stays under the
///         EIP-170 24576-byte deploy limit (Arc enforces it). Deployed once and
///         delegatecalled: because a Solidity `public`/`external` library
///         function invoked on the caller's storage runs via DELEGATECALL,
///         `address(this)`, `msg.sender` and the whole storage layout stay the
///         HOOK's inside these functions. Storage mappings are passed by
///         reference (slot pointers) so the moved code reads/writes exactly the
///         hook state it did when inlined. Every function is a faithful,
///         behaviour-preserving move of what used to live in ArcadeHook.sol
///         (verified by the unchanged v4 test suite).
///
/// @dev    Events are re-declared here so they are emitted (from the hook's
///         address, under delegatecall) with byte-identical topics/data.
library ArcadeHookLib {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Mirrors ArcadeHook.POST_GRAD_CREATOR_BPS (80% creator / 20% treasury).
    uint16 internal constant POST_GRAD_CREATOR_BPS = 8_000;

    // --- Events (mirrors of ArcadeHook's; emitted from the hook via delegatecall) ---
    event RoyaltyPaid(
        PoolId indexed poolId,
        address indexed creator,
        uint256 creatorAmount,
        uint256 treasuryAmount,
        address currency
    );
    event AntiSnipeApplied(PoolId indexed poolId, address indexed sniper, uint256 amount, uint16 bps);
    event EscrowCreditFailed(uint256 indexed positionId, uint8 slot, uint256 amount);
    event FeeHarvested(bytes32 indexed positionKey, uint256 amount0, uint256 amount1);
    event TokenCredited(address indexed token, address indexed recipient, uint256 amount);
    event Graduated(PoolId indexed poolId, uint256 finalUsdcReserve, uint256 tokensInLP);
    // Mirrors of ArcadeHook's launch events (emitted from the hook via delegatecall).
    event SnipeConfigured(address indexed token, uint16 startBps, uint32 decaySeconds);
    event TokenLaunched(
        address indexed token, address indexed creator, uint8 mode, string name, string symbol, string metadataURI
    );
    event LaunchCreated(PoolId indexed poolId, address indexed token, address creator, uint8 mode);
    event FeeAttributedToHandle(PoolId indexed poolId, address indexed escrow, string handle);

    error ZeroAmount();
    /// @dev The creator's atomic dev-buy delivered more than CREATOR_DEV_BUY_MAX_BPS
    ///      (10%) of TOTAL_SUPPLY. Reverts the whole createLaunch.
    error DevBuyExceedsCap();

    /// @dev Hard ceiling on the creator's atomic launch dev-buy: at most this
    ///      share of TOTAL_SUPPLY. The dev-buy is un-frontrunnable (it runs inline
    ///      in createLaunch before any other account can trade) but is still
    ///      BOUNDED so a launch can never hand the creator an unlimited opening
    ///      position. Enforced HERE (not in afterSwap: the PoolManager does not
    ///      re-enter the hook's afterSwap on the hook's own kind-4 swap).
    uint16 internal constant CREATOR_DEV_BUY_MAX_BPS = 1_000; // 10%

    // --- Mirrors of ArcadeHook constants (MUST match exactly) + errors (same
    //     selectors as the hook's, so revert behaviour is byte-identical). Used by
    //     createLaunchCore, which is the faithful move of ArcadeHook.createLaunch's
    //     body (dev-buys stay in the hook). ---
    uint16 internal constant MAX_SNIPE_START_BPS = 5_000;
    uint32 internal constant MAX_SNIPE_DECAY_SECONDS = 3_600;
    uint256 internal constant CLANKER_DEFAULT_START_MCAP = 35_000e6;
    uint256 internal constant CLANKER_MIN_START_MCAP = 1_000e6;
    uint256 internal constant CLANKER_MAX_START_MCAP = 10_000_000e6;
    uint256 internal constant CREATION_FEE = 3e6;

    error EmptyName();
    error InvalidMode();
    error InvalidFeeOwner();
    error InvalidSnipeBps();
    error InvalidDecaySeconds();
    error InvalidStartMcap();
    error InvalidFeeTier();
    error AlreadyLaunched();

    /// @dev Bundled createLaunch value inputs (dodges stack-too-deep).
    struct CreateParams {
        string name;
        string symbol;
        string metadataURI;
        string twitterHandle;
        uint8 mode;
        address creator; // = msg.sender at the hook entrypoint (preserved under delegatecall)
        address creator2;
        uint16 creator2Bps;
        uint16 snipeStartBps;
        uint32 snipeDecaySeconds;
        uint8 feeTier;
        uint256 startMcapUsdc;
        address twitterEscrow; // the hook's owner-configured escrow
        address tokenForwarder; // the hook's owner-configured token forwarder
        address treasury;
        // CLANKER pair asset, owner-selected on the hook. ZERO => USDC, which is
        // the default and the only value PUMP ever sees: the bonding curve is
        // denominated in 6-decimal USDC by hard constants, and a curve priced in
        // a volatile asset would have a graduation target that moves with that
        // asset. Clanker has no curve, so it is free to pair against anything.
        address quote;
        // The mcap default and bounds IN THE QUOTE'S OWN UNITS. They cannot be
        // derived from the USDC constants: the hook has no oracle, so it cannot
        // know what a quote token is worth. The owner sets them alongside the
        // quote or the pool opens at a nonsense price.
        uint256 quoteDefaultMcap;
        uint256 quoteMinMcap;
        uint256 quoteMaxMcap;
    }

    // -------------------------------------------------------------------
    // Internal money-movement helpers (inlined into the public entrypoints)
    // -------------------------------------------------------------------

    /// @dev Best-effort PoolManager.take. If the recipient rejects the transfer
    ///      the funds are taken to the hook instead and credited as a pending
    ///      pull-payment. CSEC-001.
    function _safeTake(
        IPoolManager pm,
        mapping(address => mapping(address => uint256)) storage pending,
        Currency currency,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0 || to == address(0)) return;
        try pm.take(currency, to, amount) {
            return;
        } catch {
            // Fall through: take to the hook, credit the recipient.
        }
        pm.take(currency, address(this), amount);
        address tokenAddr = Currency.unwrap(currency);
        pending[tokenAddr][to] += amount;
        emit TokenCredited(tokenAddr, to, amount);
    }

    /// @dev Pay `amount` of `currency` to the PoolManager, balancing a
    ///      modifyLiquidity delta.
    function _settleSide(IPoolManager pm, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        pm.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(pm), amount);
        pm.settle();
    }

    /// @dev The pool's current "mcap tick": slot0 tick sign-normalised so it
    ///      RISES with market cap regardless of USDC's currency ordering.
    function _mcapTick(IPoolManager pm, PoolId poolId, bool usdcIsCurrency0) internal view returns (int24) {
        (, int24 tick,,) = pm.getSlot0(poolId);
        return usdcIsCurrency0 ? -tick : tick;
    }

    /// @dev Canonical PoolKey for a launch. Sorts currencies (v4 invariant), sets
    ///      the hook to this contract, fee = the stored per-token pool fee.
    function _buildKey(Currency usdc, uint24 poolFee, address launchToken)
        internal
        view
        returns (PoolKey memory key)
    {
        address usdcAddr = Currency.unwrap(usdc);
        (Currency c0, Currency c1) = usdcAddr < launchToken
            ? (usdc, Currency.wrap(launchToken))
            : (Currency.wrap(launchToken), usdc);
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: poolFee,
            tickSpacing: 200,
            hooks: IHooks(address(this))
        });
    }

    // -------------------------------------------------------------------
    // Fee routing (called from before/afterSwap and the CLANKER harvest)
    // -------------------------------------------------------------------

    /// @dev Route anti-sniper auction proceeds to the launch CREATOR. No-op when
    ///      the skim is zero. Blocklist-safe via _safeTake.
    function payAntiSnipe(
        IPoolManager pm,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners,
        mapping(address => mapping(address => uint256)) storage pending,
        PoolId poolId,
        Currency currency,
        uint256 snipeSkim,
        uint256 amount
    ) public {
        if (snipeSkim == 0) return;
        _safeTake(pm, pending, currency, feeOwners[poolId].creator, snipeSkim);
        emit AntiSnipeApplied(poolId, msg.sender, snipeSkim, uint16((snipeSkim * 10_000) / amount));
    }

    /// @dev Split `fee` (already computed, in `feeCurrency`) 80/20 creator/treasury
    ///      and route it via _safeTake. The creator cut flows through the optional
    ///      creator2 split (CLANKER only) and the Twitter-escrow slot when wired,
    ///      falling back to a direct creator take if the escrow reverts. Every
    ///      take is blocklist-safe (CSEC-001). `allowEscrow` gates the escrow
    ///      route (true for USDC fees, false for a CLANKER collect's token side).
    function distributeFee(
        IPoolManager pm,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners,
        mapping(address => mapping(address => uint256)) storage pending,
        address treasury,
        PoolId poolId,
        Currency feeCurrency,
        uint256 fee,
        uint8 mode,
        bool allowEscrow
    ) public {
        if (fee == 0) return;
        ArcadeHook.FeeOwner memory fo = feeOwners[poolId];
        uint256 creatorCut = (fee * POST_GRAD_CREATOR_BPS) / 10_000;
        uint256 treasuryCut = fee - creatorCut;

        // Optional creator2 split (CLANKER only, when configured).
        if (fo.creator2 != address(0) && fo.creator2Bps > 0 && mode == uint8(1)) {
            uint256 creator2Cut = (creatorCut * fo.creator2Bps) / 10_000;
            if (creator2Cut > 0) {
                _safeTake(pm, pending, feeCurrency, fo.creator2, creator2Cut);
                creatorCut -= creator2Cut;
            }
        }

        // Route the creator cut. Twitter-escrow slot if the launch attributed
        // fees to a handle (USDC only), else direct to the creator.
        if (creatorCut > 0) {
            if (allowEscrow && fo.twitterEscrow != address(0)) {
                address feeTokenAddr = Currency.unwrap(feeCurrency);
                uint256 positionId = uint256(PoolId.unwrap(poolId));
                // Deliver the USDC to the escrow FIRST, then credit the slot.
                _safeTake(pm, pending, feeCurrency, fo.twitterEscrow, creatorCut);
                try IArcadeTwitterEscrowV4Min(fo.twitterEscrow).creditSlot(
                    positionId, fo.slotIndex, feeTokenAddr, creatorCut
                ) {
                    // credited to the handle slot
                } catch {
                    emit EscrowCreditFailed(positionId, fo.slotIndex, creatorCut);
                }
            } else {
                _safeTake(pm, pending, feeCurrency, fo.creator, creatorCut);
            }
        }
        if (treasuryCut > 0) _safeTake(pm, pending, feeCurrency, treasury, treasuryCut);

        emit RoyaltyPaid(poolId, fo.creator, creatorCut, treasuryCut, Currency.unwrap(feeCurrency));
    }

    /// @dev Best-effort USDC payout from the hook's own balance (curve fee /
    ///      migration fee path). Credits a pending pull if the transfer fails.
    function safePayUsdc(
        Currency usdc,
        mapping(address => mapping(address => uint256)) storage pending,
        address to,
        uint256 amount
    ) public {
        if (amount == 0 || to == address(0)) return;
        address usdcAddr = Currency.unwrap(usdc);
        try IERC20(usdcAddr).transfer(to, amount) returns (bool ok) {
            if (ok) return;
        } catch {
            // fall through to credit
        }
        pending[usdcAddr][to] += amount;
        emit TokenCredited(usdcAddr, to, amount);
    }

    // -------------------------------------------------------------------
    // LP seeding / graduation / settlement
    // -------------------------------------------------------------------

    /// @dev CLANKER direct launch: initialise the V4 pool at the starting market
    ///      cap and seed the FULL supply as a SINGLE-SIDED locked position.
    function launchDirect(
        IPoolManager pm,
        Currency usdc,
        mapping(address => ArcadeHook.ClankerPos) storage clankerPos,
        address token,
        PoolKey memory key,
        PoolId poolId,
        uint256 startMcap
    ) public {
        bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(usdc);
        uint256 supply = ArcadeV4Curve.TOTAL_SUPPLY;

        (uint256 amount0, uint256 amount1) = usdcIsCurrency0 ? (startMcap, supply) : (supply, startMcap);
        uint160 startSqrt = ArcadeV4Math.sqrtPriceX96FromAmounts(amount0, amount1);
        pm.initialize(key, startSqrt);

        int24 spacing = key.tickSpacing;
        int24 aligned = ArcadeV4Math.seedEdgeTick(startSqrt, spacing, usdcIsCurrency0);
        (int24 minT, int24 maxT) = ArcadeV4Math.fullRange(spacing);

        uint64 nowTs = uint64(block.timestamp);
        if (usdcIsCurrency0) {
            clankerPos[token] =
                ArcadeHook.ClankerPos({tickLower: minT, tickUpper: aligned, seeded: true, launchedAt: nowTs});
        } else {
            clankerPos[token] =
                ArcadeHook.ClankerPos({tickLower: aligned, tickUpper: maxT, seeded: true, launchedAt: nowTs});
        }

        pm.unlock(abi.encode(uint8(1), token, supply, uint256(0), aligned));

        emit Graduated(poolId, 0, supply);
    }

    /// @dev CLANKER fee tier (1/2/3) -> bps (100/200/300). Mirrors
    ///      ArcadeHook._resolveFeeTierBps.
    function _tierBps(uint8 tier) internal pure returns (uint16) {
        if (tier == 1) return 100;
        if (tier == 2) return 200;
        if (tier == 3) return 300;
        revert InvalidFeeTier();
    }

    /// @notice The faithful move of ArcadeHook.createLaunch's body (PUMP + CLANKER
    ///         setup) so the hook stays under EIP-170. Behaviour-preserving: same
    ///         validation, same state writes, same events (emitted from the hook via
    ///         delegatecall), same CLANKER single-sided seed. The two atomic
    ///         DEV-BUYS stay in the hook wrapper (they use the standalone
    ///         `_creatorBuying` flag + `_doCurveBuy`, which cannot cross the library
    ///         boundary). Verified by the unchanged v4 test suite.
    function createLaunchCore(
        IPoolManager pm,
        Currency usdc,
        CreateParams memory p,
        mapping(address => bool) storage registeredLaunches,
        address[] storage allTokens,
        mapping(address => uint24) storage poolFeeOf,
        mapping(address => PoolId) storage poolIdOf,
        mapping(PoolId => ArcadeHook.CurveState) storage curveStates,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners,
        mapping(address => ArcadeHook.SnipeConfig) storage snipeConfigs,
        mapping(address => ArcadeHook.ClankerPos) storage clankerPos,
        mapping(PoolId => uint40) storage lastTradeAt,
        // Needed HERE, not at the hook after this returns: the CLANKER seed
        // unlocks inside this function, and that callback resolves the pool's
        // currencies through quoteAssetOf. Writing it afterwards built the key
        // against the quote while the callback still settled USDC, which
        // surfaces as PoolNotInitialized rather than anything that names the
        // real cause.
        mapping(address => address) storage quoteAssetOf
    ) public returns (address tokenAddr, PoolId poolId) {
        if (bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert EmptyName();
        if (p.mode >= uint8(ArcadeHook.LaunchMode.CLANKER_V3)) revert InvalidMode();
        if (p.creator2Bps > 10_000) revert InvalidFeeOwner();
        if (p.snipeStartBps > MAX_SNIPE_START_BPS) revert InvalidSnipeBps();
        if (p.snipeStartBps > 0 && p.snipeDecaySeconds == 0) revert InvalidDecaySeconds();
        if (p.snipeDecaySeconds > MAX_SNIPE_DECAY_SECONDS) revert InvalidDecaySeconds();
        if (p.mode == uint8(ArcadeHook.LaunchMode.CLANKER) && p.snipeStartBps > 0) revert InvalidSnipeBps();
        if (p.mode == uint8(ArcadeHook.LaunchMode.PUMP) && (p.creator2 != address(0) || p.creator2Bps > 0)) {
            revert InvalidFeeOwner();
        }

        // The asset this launch is paired against. PUMP is pinned to USDC no
        // matter what the hook is configured with; only CLANKER honours a quote.
        Currency quoteCur = usdc;
        if (p.mode == uint8(ArcadeHook.LaunchMode.CLANKER) && p.quote != address(0)) {
            quoteCur = Currency.wrap(p.quote);
        }

        uint16 feeTierBps = 0;
        uint256 startMcap = 0;
        if (p.mode == uint8(ArcadeHook.LaunchMode.CLANKER)) {
            feeTierBps = _tierBps(p.feeTier);
            // startMcapUsdc is read in the QUOTE's units once a quote is set. It
            // keeps its name because the external signature is unchanged, which
            // is the whole point: flipping the quote must not break the caller,
            // the tweet-launch cron or the agent API.
            if (p.quote != address(0)) {
                startMcap = p.startMcapUsdc == 0 ? p.quoteDefaultMcap : p.startMcapUsdc;
                if (startMcap < p.quoteMinMcap || startMcap > p.quoteMaxMcap) revert InvalidStartMcap();
            } else {
                startMcap = p.startMcapUsdc == 0 ? CLANKER_DEFAULT_START_MCAP : p.startMcapUsdc;
                if (startMcap < CLANKER_MIN_START_MCAP || startMcap > CLANKER_MAX_START_MCAP) {
                    revert InvalidStartMcap();
                }
            }
        }

        // Creation fee (msg.sender == p.creator under delegatecall).
        IERC20(Currency.unwrap(usdc)).safeTransferFrom(p.creator, p.treasury, CREATION_FEE);

        tokenAddr = address(new ArcadeLaunchToken(p.name, p.symbol, ArcadeV4Curve.TOTAL_SUPPLY, address(this)));
        if (registeredLaunches[tokenAddr]) revert AlreadyLaunched();
        registeredLaunches[tokenAddr] = true;
        allTokens.push(tokenAddr);

        // Record the pair BEFORE anything unlocks. Zero stays zero, so a USDC
        // launch writes nothing and reads exactly as it did before.
        if (p.mode == uint8(ArcadeHook.LaunchMode.CLANKER) && p.quote != address(0)) {
            quoteAssetOf[tokenAddr] = p.quote;
        }

        poolFeeOf[tokenAddr] = p.mode == uint8(ArcadeHook.LaunchMode.CLANKER) ? uint24(feeTierBps) * 100 : 0;

        // The creation fee above stays in USDC on purpose: it is a flat 3 USDC
        // charge, not a share of the pair, so it must not follow the quote.
        PoolKey memory key = _buildKey(quoteCur, poolFeeOf[tokenAddr], tokenAddr);
        poolId = key.toId();
        poolIdOf[tokenAddr] = poolId;

        curveStates[poolId] = ArcadeHook.CurveState({
            virtualUsdcReserve: uint128(ArcadeV4Curve.VIRTUAL_USDC_RESERVE),
            realUsdcReserve: 0,
            tokensSold: 0,
            mode: p.mode,
            status: p.mode == uint8(ArcadeHook.LaunchMode.PUMP)
                ? uint8(ArcadeHook.Status.Curving)
                : uint8(ArcadeHook.Status.Graduated),
            creator: p.creator,
            creator2: p.creator2,
            creator2Bps: p.creator2Bps
        });

        address launchEscrow = address(0);
        if (
            bytes(p.twitterHandle).length > 0 && p.mode == uint8(ArcadeHook.LaunchMode.CLANKER)
                && p.twitterEscrow != address(0)
        ) {
            launchEscrow = p.twitterEscrow;
        }
        address feeCreator =
            (launchEscrow != address(0) && p.tokenForwarder != address(0)) ? p.tokenForwarder : p.creator;

        feeOwners[poolId] = ArcadeHook.FeeOwner({
            creator: feeCreator,
            creator2: p.creator2,
            creator2Bps: p.creator2Bps,
            feeTierBps: feeTierBps,
            twitterEscrow: launchEscrow,
            slotIndex: 0
        });

        if (p.snipeStartBps > 0) {
            snipeConfigs[tokenAddr] = ArcadeHook.SnipeConfig({
                startBps: p.snipeStartBps,
                decaySeconds: p.snipeDecaySeconds,
                launchedAt: uint64(block.timestamp)
            });
            emit SnipeConfigured(tokenAddr, p.snipeStartBps, p.snipeDecaySeconds);
        }

        emit TokenLaunched(tokenAddr, p.creator, p.mode, p.name, p.symbol, p.metadataURI);
        emit LaunchCreated(poolId, tokenAddr, p.creator, p.mode);
        if (launchEscrow != address(0)) emit FeeAttributedToHandle(poolId, launchEscrow, p.twitterHandle);

        // CLANKER: seed the full supply single-sided into a locked V4 LP.
        if (p.mode == uint8(ArcadeHook.LaunchMode.CLANKER)) {
            launchDirect(pm, quoteCur, clankerPos, tokenAddr, key, poolId, startMcap);
            lastTradeAt[poolId] = uint40(block.timestamp);
        }
    }

    /// @dev Atomic curve -> AMM migration. Frozen sequence per V4_HOOK_SPEC.md
    ///      Section 5. `state` and `key` come from the calling hook (the curve
    ///      buy that filled the curve); the mappings are the hook's own storage.
    function graduate(
        IPoolManager pm,
        Currency usdc,
        address treasury,
        mapping(address => mapping(address => uint256)) storage pending,
        mapping(PoolId => ArcadeHook.FeeObs) storage feeObs,
        mapping(address => ArcadeHook.SnipeConfig) storage snipeConfigs,
        ArcadeHook.CurveState storage state,
        PoolKey memory key,
        address token
    ) public {
        state.status = uint8(1); // GraduationStarted

        uint256 totalUsdc = state.realUsdcReserve;
        uint256 migrationFee = ArcadeV4Curve.migrationFee(totalUsdc);
        uint256 lpUsdc = totalUsdc - migrationFee;
        if (lpUsdc == 0) revert ZeroAmount();
        uint256 lpTokens = ArcadeV4Curve.MIGRATION_LP_TOKENS;

        // Migration fee (1% of the raise) off the top -> treasury (pull-payment safe).
        safePayUsdc(usdc, pending, treasury, migrationFee);

        bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(usdc);
        (uint256 amount0, uint256 amount1) = usdcIsCurrency0 ? (lpUsdc, lpTokens) : (lpTokens, lpUsdc);

        uint160 sqrtPriceX96 = ArcadeV4Math.sqrtPriceX96FromAmounts(amount0, amount1);
        pm.initialize(key, sqrtPriceX96);

        pm.unlock(abi.encode(uint8(0), token, amount0, amount1, int24(0)));

        state.status = uint8(2); // Graduated

        // Anti-sniper decay clock is anchored at createLaunch (curve-phase tax),
        // NOT re-armed here. The tax now applies to early CURVE buys via
        // _doCurveBuy, so re-stamping launchedAt at graduation would wrongly
        // re-arm a full-strength post-grad tax on the first post-grad buyers.
        // (The `snipeConfigs` param is retained for signature stability.)

        // Seed the PUMP fee oracle at the graduation price.
        PoolId pid = key.toId();
        int24 gmt = _mcapTick(pm, pid, usdcIsCurrency0);
        feeObs[pid] = ArcadeHook.FeeObs({
            emaTickE3: int64(int256(gmt) * 1_000),
            gradMcapTick: gmt,
            lastTs: uint32(block.timestamp),
            init: true
        });

        emit Graduated(pid, totalUsdc, lpTokens);
    }

    /// @dev The IUnlockCallback body. `kind` selects graduation (0), CLANKER
    ///      single-sided seed (1) or CLANKER fee harvest (2). Runs under
    ///      delegatecall so `address(this)` is the hook that PoolManager unlocked.
    function unlockCallback(
        IPoolManager pm,
        Currency usdc,
        address treasury,
        bytes calldata data,
        mapping(address => ArcadeHook.ClankerPos) storage clankerPos,
        mapping(PoolId => ArcadeHook.CurveState) storage curveStates,
        mapping(PoolId => ArcadeHook.FeeOwner) storage feeOwners,
        mapping(address => uint24) storage poolFeeOf,
        mapping(address => mapping(address => uint256)) storage pending,
        mapping(address => address) storage quoteAssetOf
    ) public returns (bytes memory) {
        (uint8 kind, address token, uint256 amount0, uint256 amount1, int24 startTick) =
            abi.decode(data, (uint8, address, uint256, uint256, int24));

        // Quote side: USDC for PUMP/CLANKER; the launch's snapshotted quote for an
        // RWA launch. Backward-compatible (0 => usdc), so PUMP/CLANKER are unchanged.
        Currency quote = quoteAssetOf[token] == address(0) ? usdc : Currency.wrap(quoteAssetOf[token]);
        PoolKey memory key = _buildKey(quote, poolFeeOf[token], token);
        int24 spacing = key.tickSpacing;

        // kind 2 = CLANKER fee harvest.
        if (kind == 2) {
            ArcadeHook.ClankerPos memory pos = clankerPos[token];
            (, BalanceDelta feesAccrued) = pm.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: pos.tickLower,
                    tickUpper: pos.tickUpper,
                    liquidityDelta: 0,
                    salt: bytes32(0)
                }),
                ""
            );
            PoolId poolId = key.toId();
            uint8 mode = curveStates[poolId].mode;
            bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
            uint256 fee0 = feesAccrued.amount0() > 0 ? uint256(uint128(feesAccrued.amount0())) : 0;
            uint256 fee1 = feesAccrued.amount1() > 0 ? uint256(uint128(feesAccrued.amount1())) : 0;
            if (usdcIsCurrency0) {
                distributeFee(pm, feeOwners, pending, treasury, poolId, key.currency0, fee0, mode, true); // USDC
                distributeFee(pm, feeOwners, pending, treasury, poolId, key.currency1, fee1, mode, false); // token
            } else {
                distributeFee(pm, feeOwners, pending, treasury, poolId, key.currency0, fee0, mode, false); // token
                distributeFee(pm, feeOwners, pending, treasury, poolId, key.currency1, fee1, mode, true); // USDC
            }
            emit FeeHarvested(PoolId.unwrap(poolId), fee0, fee1);
            return "";
        }

        // kind 3 = graveyard sweep: remove the FULL liquidity of the hook-owned
        // locked position of a DEAD pool and send BOTH withdrawn sides to the
        // treasury via the pull-safe path. The hook has already enforced the
        // >=180d no-trade window + one-shot flag; here we only execute the
        // removal. Returns (usdcOut, tokenOut) so the hook can emit its event.
        if (kind == 3) {
            PoolId gpid = key.toId();
            int24 gLower;
            int24 gUpper;
            uint8 gMode = curveStates[gpid].mode;
            if (gMode == uint8(1) || gMode == uint8(3)) {
                // CLANKER / RWA: the single-sided seed range.
                ArcadeHook.ClankerPos memory pos = clankerPos[token];
                (gLower, gUpper) = (pos.tickLower, pos.tickUpper);
            } else {
                // PUMP graduation: the full-range two-sided seed.
                (gLower, gUpper) = ArcadeV4Math.fullRange(spacing);
            }
            // The seed is keyed to the HOOK (address(this)) with salt 0 -- the
            // only position the hook ever owns per pool.
            bytes32 posKey = keccak256(abi.encodePacked(address(this), gLower, gUpper, bytes32(0)));
            uint128 liq = pm.getPositionLiquidity(gpid, posKey);
            uint256 usdcOut;
            uint256 tokenOut;
            if (liq > 0) {
                (BalanceDelta rd,) = pm.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: gLower,
                        tickUpper: gUpper,
                        liquidityDelta: -int256(uint256(liq)),
                        salt: bytes32(0)
                    }),
                    ""
                );
                // Removal returns positive deltas (principal + any accrued fees)
                // owed to the hook. Take BOTH sides to the treasury, pull-safe.
                uint256 out0 = rd.amount0() > 0 ? uint256(uint128(rd.amount0())) : 0;
                uint256 out1 = rd.amount1() > 0 ? uint256(uint128(rd.amount1())) : 0;
                // RWA (amount0 packs the never-rotated sink): quote -> treasury, the
                // launch TOKEN -> sink (kept out of the dividend share base). CLANKER/
                // PUMP pack 0 -> both sides to treasury (unchanged).
                bool usdcIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
                address sink = address(uint160(amount0));
                if (sink != address(0)) {
                    _safeTake(pm, pending, key.currency0, usdcIs0 ? treasury : sink, out0);
                    _safeTake(pm, pending, key.currency1, usdcIs0 ? sink : treasury, out1);
                } else {
                    _safeTake(pm, pending, key.currency0, treasury, out0);
                    _safeTake(pm, pending, key.currency1, treasury, out1);
                }
                (usdcOut, tokenOut) = usdcIs0 ? (out0, out1) : (out1, out0);
            }
            return abi.encode(usdcOut, tokenOut);
        }

        // kind 4 = CLANKER atomic DEV BUY: swap the full `amount0` of USDC the
        // hook is holding INTO the freshly-seeded single-sided pool and deliver
        // the bought launch token to the CREATOR. Exact-INPUT for the whole
        // creatorBuyUsdc (no minOut -- atomic against a fresh, deterministic-price
        // pool, mirroring PUMP's creator buy). The exact-in swap consumes exactly
        // `amount0` USDC (we settle precisely what the pool debits, so nothing is
        // stranded in the hook). Runs SEQUENTIALLY after launchDirect's unlock has
        // already returned -- this is a fresh top-level unlock, not nested.
        if (kind == 4) {
            PoolId dpid = key.toId();
            bool usdcIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
            bool zeroForOne = usdcIs0; // quote -> token
            BalanceDelta sd = pm.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amount0),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            // Delta is from the swap's perspective: negative on the side we owe
            // (USDC in), positive on the side we're owed (token out).
            (Currency inputCurrency, Currency outputCurrency, int128 inDelta, int128 outDelta) = zeroForOne
                ? (key.currency0, key.currency1, sd.amount0(), sd.amount1())
                : (key.currency1, key.currency0, sd.amount1(), sd.amount0());
            // Settle exactly what the pool debited (== amount0 for a fresh pool,
            // so no residual USDC lingers in the hook).
            if (inDelta < 0) _settleSide(pm, inputCurrency, uint256(uint128(-inDelta)));
            // Deliver the bought token to the launch creator (set at createLaunch).
            uint256 outAmount = outDelta > 0 ? uint256(uint128(outDelta)) : 0;
            // Bound the dev-buy to CREATOR_DEV_BUY_MAX_BPS (10%) of supply on the
            // amount actually delivered. The hook's afterSwap is NOT re-entered on
            // this self-swap, so the ceiling is enforced here; over-cap unwinds
            // the whole createLaunch.
            if (outAmount > (ArcadeV4Curve.TOTAL_SUPPLY * CREATOR_DEV_BUY_MAX_BPS) / 10_000) {
                revert DevBuyExceedsCap();
            }
            pm.take(outputCurrency, curveStates[dpid].creator, outAmount);
            return "";
        }

        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;

        if (kind == 0) {
            // Graduation: full-range two-sided position at the reserve ratio.
            (tickLower, tickUpper) = ArcadeV4Math.fullRange(spacing);
            uint160 sqrtPriceX96 = ArcadeV4Math.sqrtPriceX96FromAmounts(amount0, amount1);
            liquidity = ArcadeV4Math.liquidityForAmounts(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
        } else {
            // CLANKER / RWA direct: SINGLE-SIDED position of the full supply (amount0).
            bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
            uint256 supply = amount0;
            (int24 minT, int24 maxT) = ArcadeV4Math.fullRange(spacing);
            if (usdcIsCurrency0) {
                tickLower = minT;
                tickUpper = startTick;
                liquidity = ArcadeV4Math.liquidityForAmount1(tickLower, tickUpper, supply);
            } else {
                tickLower = startTick;
                tickUpper = maxT;
                liquidity = ArcadeV4Math.liquidityForAmount0(tickLower, tickUpper, supply);
            }
        }

        (BalanceDelta callerDelta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();
        if (d0 < 0) _settleSide(pm, key.currency0, uint256(uint128(-d0)));
        if (d1 < 0) _settleSide(pm, key.currency1, uint256(uint128(-d1)));

        return "";
    }
}
