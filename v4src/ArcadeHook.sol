// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArcadeLaunchToken} from "../src/launchpad/ArcadeLaunchToken.sol";
import {ArcadeV4Curve} from "./libraries/ArcadeV4Curve.sol";
import {ILaunchpadSnipe} from "./interfaces/ILaunchpadSnipe.sol";

/// @notice Minimal subset of the ArcadeTwitterEscrowV4 surface the hook calls
///         to credit a Twitter-handle slot with creator fees. Kept in this file
///         so the V4 stack does not import the full escrow source. The `slot`
///         is uint256 to match the escrow's ABI byte-for-byte (a uint8 here
///         would compute a DIFFERENT selector and silently miss the call).
interface IArcadeTwitterEscrowV4Min {
    function creditSlot(uint256 positionId, uint256 slot, address token, uint256 amount) external;
}

// v4-core upstream.
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {ArcadeV4Math} from "./libraries/ArcadeV4Math.sol";
import {ArcadeHookLib} from "./libraries/ArcadeHookLib.sol";
import {ArcadeRwaLib} from "./libraries/ArcadeRwaLib.sol";

/**
 * @title ArcadeHook
 * @notice Unified Uniswap V4 hook for the Arcade launchpad. Subsumes the V2
 *         stack (Factory + Pair + Router + Launchpad + V3 Locker) into a
 *         single hook bound to one canonical PoolManager on Arc.
 *
 *         The hook owns the full launch lifecycle:
 *           - createLaunch: deploys ArcadeLaunchToken (1B minted here), pulls
 *             the USDC creation fee, configures fee owners + optional CLANKER
 *             fee tier, anti-sniper, and Twitter-handle fee attribution.
 *           - Bonding curve (hook.buy/hook.sell) during Curving, then atomic
 *             graduation into a locked full-range V4 LP.
 *           - Post-graduation fee capture in before/afterSwap: the whole trading
 *             fee, always in USDC, split 80/20 creator/treasury, with a
 *             mcap-decaying PUMP fee / fixed CLANKER tier + anti-sniper auction.
 *           - Permission bitmap 0x3ECE (10 bits); the 4 unused callbacks revert.
 *
 * @dev    Hook permission flags MUST match the address bits CREATE2-mined by
 *         `v4script/MineHookSalt.s.sol`. Set in `getHookPermissions()`:
 *           bit 13: BEFORE_INITIALIZE_FLAG
 *           bit 12: AFTER_INITIALIZE_FLAG
 *           bit 11: BEFORE_ADD_LIQUIDITY_FLAG
 *           bit 10: AFTER_ADD_LIQUIDITY_FLAG
 *           bit 9:  BEFORE_REMOVE_LIQUIDITY_FLAG
 *           bit 7:  BEFORE_SWAP_FLAG
 *           bit 6:  AFTER_SWAP_FLAG
 *           bit 3:  BEFORE_SWAP_RETURNS_DELTA_FLAG
 *           bit 2:  AFTER_SWAP_RETURNS_DELTA_FLAG
 *           bit 1:  AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
 *         => bitmap 0x3ECE (10 bits set; V4_HOOK_SPEC.md Section 3 has a
 *           typo "0x3EEC" — the correct value matching that table is 0x3ECE).
 *
 *         The hook does NOT inherit BaseHook; it implements IHooks directly
 *         so the permission check happens entirely via address bit pattern
 *         (no validateHookAddress call), letting tests use deployCodeTo to
 *         place the hook at a chosen address with the right bits.
 */
contract ArcadeHook is IHooks, IUnlockCallback, Ownable2Step, Pausable, ReentrancyGuard, ILaunchpadSnipe {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------
    // Launch mode (matches V2 ArcadeLaunchpad.LaunchMode)
    // -------------------------------------------------------------------

    enum LaunchMode {
        PUMP, // 0
        CLANKER, // 1
        CLANKER_V3, // 2
        RWA // 3 -- RWA-quote-paired, volume-funded dividends. APPEND-ONLY: the
            // numeric mode is persisted in CurveState.mode, so NEVER reorder/insert.
    }

    // -------------------------------------------------------------------
    // State structs (frozen per V4_HOOK_SPEC.md Section 2)
    // -------------------------------------------------------------------

    struct CurveState {
        // Stored at init = ArcadeV4Curve.VIRTUAL_USDC_RESERVE (5_500e6), but
        // INFORMATIONAL ONLY: the curve math reads the library constant, never
        // this field. Kept for off-chain readers; do not compute against it.
        uint128 virtualUsdcReserve;
        uint128 realUsdcReserve; // climbs to ~13_473e6 at graduation (GRADUATION_USDC)
        uint128 tokensSold; // climbs to CURVE_SUPPLY (777M)
        uint8 mode; // LaunchMode cast
        uint8 status; // 0=Curving, 1=GraduationStarted, 2=Graduated
        address creator;
        address creator2; // optional secondary recipient
        uint16 creator2Bps; // share of creator fee that routes to creator2
    }

    struct FeeOwner {
        address creator;
        address creator2;
        uint16 creator2Bps;
        uint16 feeTierBps; // CLANKER: creator-chosen fee tier (100/200/300). 0 for PUMP (dynamic).
        address twitterEscrow; // zero = direct transfer; non-zero = creditSlot
        uint8 slotIndex; // 0..3, used when twitterEscrow != address(0)
    }

    struct PositionInfo {
        address owner; // for accounting only; LOCKED_VAULT holds 6909 receipt
        uint128 liquidity;
        bool locked;
    }

    struct SnipeConfig {
        uint16 startBps; // 0 means anti-sniper disabled for this token
        uint32 decaySeconds; // linear decay window
        uint64 launchedAt; // 0 until graduation; then block.timestamp of graduation (decay anchor)
    }

    /// @notice Manipulation-resistant price oracle feeding the PUMP dynamic
    ///         fee. Tracks an EMA of the pool's "mcap tick" (the slot0 tick
    ///         sign-normalised so it always RISES with market cap regardless of
    ///         USDC's currency ordering). Seeded at graduation; updated at most
    ///         once per block timestamp in afterSwap, never on the swap that
    ///         reads it, so a swap can never move the fee it itself pays.
    struct FeeObs {
        int64 emaTickE3; // EMA of the mcap tick, scaled x1e3 for sub-tick precision
        int24 gradMcapTick; // mcap tick captured at graduation (fee-decay reference)
        uint32 lastTs; // timestamp of the last EMA update
        bool init; // true once seeded at graduation
    }

    enum Status {
        Curving, // 0
        GraduationStarted, // 1
        Graduated // 2
    }

    // -------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------

    IPoolManager public immutable POOL_MANAGER;
    /// @notice USDC on the deployment chain. Pool currencies are validated
    ///         in beforeInitialize: exactly one of (currency0, currency1)
    ///         MUST equal USDC.
    Currency public immutable USDC;
    /// @notice Configured recipient of locked LP claim tokens. NOTE: the
    ///         graduation-seed / CLANKER-init position is added by the hook
    ///         itself via POOL_MANAGER.modifyLiquidity, so v4-core keys the
    ///         position to the HOOK (address(this)), and `noSelfCall` skips the
    ///         hook's own afterAddLiquidity, so NO ERC-6909 receipt is minted to
    ///         this vault and the `positions`/`locked` bookkeeping never runs for
    ///         the seed. The LP is nonetheless unremovable: there is no
    ///         negative-delta modifyLiquidity path anywhere in the hook, so the
    ///         position can never be withdrawn. This immutable + the
    ///         `positions`/beforeRemoveLiquidity guard are retained defensively
    ///         but are inert for the seed; do NOT rely on "the vault holds the
    ///         receipts" as the lock proof.
    address public immutable LOCKED_VAULT;
    /// @notice Treasury that receives creation fees + post-graduation royalty
    ///         + anti-sniper skims. Owner-mutable post-bootstrap (see setTreasury).
    address public TREASURY;
    /// @notice TwitterEscrowV3 target. Owner-mutable; address(0) disables the
    ///         creator-fee escrow path entirely.
    address public twitterEscrow;

    /// @notice Recipient of the TOKEN-side CLANKER fees for a handle-attributed
    ///         launch (the USDC side is escrowed on-chain; the escrow slot pins
    ///         one token, so the token side cannot co-habit it). Set to the
    ///         backend operator so the off-chain forwarder delivers the token
    ///         side to the verified @ owner on claim -- WITHOUT this, a UI launch
    ///         (FeeOwner.creator = the launcher) leaves the token side in the
    ///         launcher's wallet. Owner-mutable; address(0) falls back to the
    ///         launcher (legacy behaviour). Only affects handle launches.
    address public tokenForwarder;

    // -------------------------------------------------------------------
    // Constants (curve math lives in ArcadeV4Curve; these are V4-specific)
    // -------------------------------------------------------------------

    /// @notice Curve trade fee, 1%. Encoded as a dynamic-fee override that
    ///         `beforeSwap` returns as the third tuple element while the pool
    ///         is in Curving status.
    uint24 internal constant TRADE_FEE_BPS = 100;

    // --- New fee model (2026-07-17 redesign, replaces the 1% pool fee + 0.30%
    //     royalty). Pool LP fee set to 0; the hook captures the WHOLE trading
    //     fee in before/afterSwap, always in USDC, split creator/treasury.
    //     Being wired in slices: capture -> PUMP dynamic mcap fee -> CLANKER
    //     tier -> mode merge. See project_arcade_v4_analysis memory. ---
    /// @notice Creator's share of the post-graduation trading fee (80%);
    ///         treasury takes the remaining 20%.
    uint16 internal constant POST_GRAD_CREATOR_BPS = 8_000;
    /// @notice CLANKER-mode selectable fee tiers (creator picks one at launch).
    ///         PUMP mode ignores this and uses the mcap-decaying dynamic fee.
    uint16 internal constant FEE_TIER_1 = 100; // 1%
    uint16 internal constant FEE_TIER_2 = 200; // 2%
    uint16 internal constant FEE_TIER_3 = 300; // 3%
    /// @notice PUMP dynamic-fee bounds: starts at ~1% for a fresh graduate and
    ///         decays with market cap down to 0.30% for a mature token.
    uint16 internal constant PUMP_FEE_MAX_BPS = 100; // 1% at graduation
    uint16 internal constant PUMP_FEE_MIN_BPS = 30; // 0.30% mature floor
    /// @notice Market-cap growth (measured in EMA ticks above the graduation
    ///         tick) at which the PUMP fee reaches its 0.30% floor. Ticks are
    ///         log-price, so a fixed tick span is a fixed MCAP MULTIPLE:
    ///         23_026 ticks = ln(10)/ln(1.0001) ~= 10x market cap. The PUMP fee
    ///         decays LINEARLY IN LOG-MCAP from 1% at graduation to 0.30% once
    ///         the token has ~10x'd. Retunable without touching the math.
    int256 internal constant PUMP_FEE_FLOOR_TICKS = 23_026;
    /// @notice Smoothing time-constant (seconds) for the price EMA that feeds
    ///         the PUMP dynamic fee. A single update moves the EMA at most
    ///         dt/(dt+TAU) toward spot, capped at 50% (dt clamped to TAU), so a
    ///         one-block price spike can never swing the fee: the oracle only
    ///         updates once per timestamp and never on the swap that reads it.
    uint256 internal constant EMA_TAU_SECONDS = 3_600; // 1 hour

    /// @notice CLANKER (direct) launch: default + bounds for the starting market
    ///         cap when the creator passes 0. The full supply is seeded
    ///         single-sided in the V4 pool at this FDV; buyers push the price up
    ///         from here (no bonding curve). Mirrors V2 CLANKER_V3's ~$35k start.
    uint256 internal constant CLANKER_DEFAULT_START_MCAP = 35_000e6; // $35k
    uint256 internal constant CLANKER_MIN_START_MCAP = 1_000e6; // $1k
    uint256 internal constant CLANKER_MAX_START_MCAP = 10_000_000e6; // $10M
    /// @notice RWA start market cap, in QUOTE units (Phase 1 quotes are 6-dp):
    ///         0 => 35k default, hard-capped at 100k (spec: 35k default, 0-100k).
    uint256 internal constant RWA_DEFAULT_START_MCAP = 35_000e6; // 35k
    uint256 internal constant RWA_MIN_START_MCAP = 1_000e6; // 1k floor (avoid a degenerate seed)
    uint256 internal constant RWA_MAX_START_MCAP = 100_000e6; // 100k
    /// @notice Hard safety cap on the TOTAL afterSwap take (fee + anti-sniper).
    ///         v4-core bricks a swap when the take exceeds 100% of the
    ///         unspecified side; we clamp well below. Max legit = 50% snipe +
    ///         3% fee = 53%, so 60% leaves margin while staying < 100%.
    uint16 internal constant MAX_TOTAL_TAKE_BPS = 6_000; // 60%, hard brick guard

    /// @notice Max allowed anti-sniper starting tax (50%). Decays linearly to 0.
    uint16 internal constant MAX_SNIPE_START_BPS = 5_000;

    /// @notice Max anti-sniper decay window (1h). Bounds a self-routed skim so a
    ///         creator cannot levy a near-50% buy tax over a multi-year window.
    ///         The UI already caps this at 60min; this is the on-chain backstop
    ///         for direct (non-UI) createLaunch calls. (Audit fee M-1, 2026-08-16.)
    uint32 internal constant MAX_SNIPE_DECAY_SECONDS = 3_600;

    /// @notice Share of the CURVE anti-sniper tax routed to the treasury (20%).
    ///         The remaining 80% goes to the token creator. Applies only to the
    ///         curve-phase tax on public buys; the creator's atomic dev-buy is
    ///         exempt (it bypasses the public buy() path entirely).
    uint16 internal constant SNIPE_TREASURY_BPS = 2_000; // 20%

    /// @notice Flat USDC creation fee charged at createLaunch (6 dp).
    uint256 internal constant CREATION_FEE = 3e6; // 3 USDC

    // -------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------

    mapping(PoolId => CurveState) public curveStates;
    mapping(PoolId => FeeOwner) public feeOwners;
    /// @notice positionKey => info. Key = keccak(PoolId, tickLower, tickUpper, salt).
    mapping(bytes32 => PositionInfo) public positions;
    /// @notice Launch token => true once createLaunch registers it. Cleared
    ///         intentionally never; a token is registered for life.
    mapping(address => bool) public registeredLaunches;
    /// @notice Anti-sniper config per launch token.
    mapping(address => SnipeConfig) public snipeConfigs;
    /// @notice Price EMA per graduated pool, feeding the PUMP dynamic fee.
    mapping(PoolId => FeeObs) public feeObs;
    /// @notice Static V4 LP fee baked into each launch's PoolKey. PUMP = 0 (the
    ///         hook captures the fee in before/afterSwap); CLANKER = its tier
    ///         (1%/2%/3% -> 10000/20000/30000) charged natively by the pool and
    ///         accrued to the hook-owned locked LP, harvested via collectFees.
    ///         Read by _buildPoolKey so the PoolId is consistent everywhere; MUST
    ///         be set before the first _buildPoolKey call for a token.
    mapping(address => uint24) public poolFeeOf;

    /// @notice CLANKER single-sided locked-LP position range per token, so
    ///         collectFees can address it (modifyLiquidity keys by tick range).
    struct ClankerPos {
        int24 tickLower;
        int24 tickUpper;
        bool seeded;
        uint64 launchedAt; // for the first-window anti-snipe buy cap
    }
    mapping(address => ClankerPos) public clankerPos;

    /// @notice CLANKER anti-snipe buy cap: reject buys whose CUMULATIVE token
    ///         output in a single block tops `clankerMaxBuyBps` of TOTAL_SUPPLY,
    ///         within `clankerCapWindowSecs` of launch. Per-BLOCK cumulative (not
    ///         per-swap) so an atomic multi-swap batch can't split under the cap.
    ///         Owner-tunable (setClankerBuyCap); 0 bps disables.
    uint16 public clankerMaxBuyBps;
    uint32 public clankerCapWindowSecs;
    /// @dev token => (block number, tokens bought so far this block). Resets on
    ///      a new block. Bounds total in-window block-0 accumulation.
    struct BlockBuy {
        uint64 blockNumber;
        uint192 bought;
    }
    mapping(address => BlockBuy) internal clankerBlockBuy;

    /// @dev Transient flag set ONLY for the duration of a CLANKER atomic dev-buy
    ///      (the creator's frontrun-proof first buy, executed inline in
    ///      createLaunch through the kind-4 unlock). The dev-buy's 10% ceiling is
    ///      enforced in the kind-4 handler (ArcadeHookLib) on the delivered amount,
    ///      because the PoolManager does NOT re-enter this hook's afterSwap on its
    ///      own swap. This flag remains as a defensive gate in `_enforceClankerBuyCap`
    ///      so that, should afterSwap ever be reached with it set, the dev-buy is
    ///      not blocked by (or counted against) the third-party first-window cap.
    ///      It is set just before the unlock and cleared immediately after; any
    ///      revert unwinds the whole (nonReentrant) tx, so it can never leak `true`
    ///      into an unrelated swap.
    bool internal _creatorBuying;
    /// @notice Launch token => PoolId so `currentSnipeBps` callers (the hook
    ///         itself + indexers) can look up the curve state from a token addr.
    mapping(address => PoolId) public poolIdOf;

    /// @notice Append-only registry for indexer enumeration.
    address[] public allTokens;

    /// @notice (token, recipient) => credited amount the recipient can pull via
    ///         `claimPendingToken`. Populated whenever an inline payout (curve
    ///         fee, migration fee, post-grad royalty) reverts because the
    ///         recipient is USDC-blocked (or any other transfer-rejecting
    ///         condition). CSEC-001: prevents one blocked address from DOSing
    ///         every swap on a graduated pool.
    mapping(address => mapping(address => uint256)) public pendingTokenWithdrawals;

    // -------------------------------------------------------------------
    // Graveyard sweep (permissionless recovery of a DEAD pool's locked LP)
    // -------------------------------------------------------------------

    /// @notice Last time the pool was traded. Written once per trade: on every
    ///         curve buy / curve sell during Curving, and on every swap on a
    ///         Graduated pool (both PUMP and CLANKER, either side). Seeded when
    ///         the LP first exists (curve buy that graduates the pool / CLANKER
    ///         seed at launch) so the graveyard clock starts from a real LP.
    ///         ANY trade resets it, so a live pool can never look "dead".
    mapping(PoolId => uint40) public lastTradeAt;
    /// @notice True once a dead pool's stranded locked LP has been swept to the
    ///         treasury. One-shot per pool: a second sweep reverts AlreadySwept.
    mapping(PoolId => bool) public graveyardSwept;
    /// @notice No-trade period after which a pool's locked LP may be swept.
    ///         Set to 365 days in the constructor; owner-tunable DOWN TO A HARD
    ///         180-day FLOOR only (setGraveyardPeriod). The floor is the critical
    ///         anti-rug guard -- without it an owner could shrink the window to
    ///         ~0 and sweep a live pool.
    uint40 public graveyardPeriod;
    /// @dev Set true only for the duration of the graveyardSweep unlock so the
    ///      beforeRemoveLiquidity guard admits ONLY the hook's own sweep removal.
    ///      DEFENSIVE: v4-core's `noSelfCall` already skips beforeRemoveLiquidity
    ///      for the hook's self-initiated modifyLiquidity, so this flag never
    ///      actually gates an external LP (which is neither address(this) nor
    ///      able to set it). It exists as belt-and-suspenders around the single
    ///      negative-delta removal path in the whole contract.
    bool internal _graveyardSweeping;

    // -------------------------------------------------------------------
    // RWA launch mode (dividend-paying, RWA-quote-paired). Additive: PUMP /
    // CLANKER read none of these (quoteAssetOf defaults to 0 => USDC).
    // -------------------------------------------------------------------

    /// @notice The dividend distributor (settable ONCE). RWA launches register
    ///         here and route the holders-bucket of the trade tax to it.
    address public dividendDistributor;
    /// @notice Owner-selected pair asset for NEW CLANKER launches. Zero => USDC,
    ///         which is the default and the shipped state.
    ///
    ///         Setting it makes every subsequent Clanker launch pair against this
    ///         asset WITHOUT any caller change: the tweet-launch cron, the agent
    ///         API and the web launcher all call `createLaunch` with the same
    ///         arguments they always did. That is deliberate - a pair asset is a
    ///         protocol-level choice, not a per-caller one, and threading it
    ///         through every entrypoint would have meant a 13th parameter on a
    ///         function already compiled under via_ir for stack pressure.
    ///
    ///         PUMP is never affected. Its bonding curve is denominated in
    ///         6-decimal USDC by hard constants, and a curve priced in a volatile
    ///         asset would have a graduation target that moves with that asset.
    address public clankerQuote;
    /// @notice Start-mcap default and bounds IN `clankerQuote`'s OWN UNITS.
    ///         They cannot be derived from the USDC constants: this contract has
    ///         no oracle and cannot know what a quote token is worth, so the owner
    ///         states them when selecting the quote or a pool would open at a
    ///         nonsense price.
    uint256 public clankerQuoteDefaultMcap;
    uint256 public clankerQuoteMinMcap;
    uint256 public clankerQuoteMaxMcap;
    /// @notice When true, a launch that expresses NO preference pairs against
    ///         `clankerQuote` rather than USDC. This is what the tweet-launch
    ///         path follows: it has no UI to choose with, so it takes whatever
    ///         the protocol says is default.
    bool public clankerQuoteIsDefault;

    /// @notice `quoteSel` values accepted by createLaunch.
    ///         0 = follow the protocol default, 1 = force USDC, 2 = force the
    ///         configured quote. A caller can only pick between USDC and the ONE
    ///         asset the owner configured; it is not a free address, so nobody
    ///         can open a Clanker pool against an arbitrary token.
    uint8 internal constant QUOTE_SEL_DEFAULT = 0;
    uint8 internal constant QUOTE_SEL_USDC = 1;
    uint8 internal constant QUOTE_SEL_CONFIGURED = 2;

    /// @notice launch token => its pool QUOTE asset. Zero => USDC (PUMP/CLANKER);
    ///         nonzero only for an RWA launch (creator-chosen, allowlisted quote).
    ///         internal (no auto-getter) to stay under EIP-170; ArcadeRwaLib + the
    ///         fee path read it directly, a compact external view is added later.
    /// PUBLIC on purpose. Off-chain has to know what a launch trades against:
    /// the router builds its PoolKey from it, the UI labels the pair with it, and
    /// an auditor cannot otherwise tell an RWA or Arcade-paired launch from a
    /// USDC one. While it was internal there was no way to read it at all.
    mapping(address => address) public quoteAssetOf;
    /// @notice Owner-curated allowlist of assets usable as an RWA quote (Phase 1:
    ///         USYC only). MUST be non-rebasing, non-FoT, non-callback (owner
    ///         verifies before allowlisting -- spec B1/M7).
    mapping(address => bool) internal rwaQuoteAllowed;
    /// @notice Permanent, never-rotated sink for RWA graveyard-swept launch tokens,
    ///         so a treasury rotation cannot strand them as a phantom dividend
    ///         holder (distributor audit MEDIUM-1). Excluded from S at registration.
    address public rwaGraveyardSink;

    /// @notice Immutable per-RWA-launch fee split (bps of trade volume). Set once
    ///         at createLaunch, never mutated (spec B2 anti bait-and-switch).
    struct RwaConfig {
        uint16 taxBps; // total trade tax: 100..300 (1-3%)
        uint16 platformBps; // -> treasury; = min(taxBps/2, 100) (BaseStonk formula)
        uint16 creatorBps; // -> creator
        uint16 holdersBps; // -> dividend distributor; creator-set in [0, taxBps - platformBps]
    }

    mapping(address => RwaConfig) internal rwaConfigs;

    // -------------------------------------------------------------------
    // Errors (frozen per V4_HOOK_SPEC.md Section 13)
    // -------------------------------------------------------------------

    error NotPoolManager();
    error OnlyLaunchpad(); // beforeInitialize sender check
    error LaunchNotRegistered();
    error NotUsdcPair();
    error GraduationInProgress();
    error LockedPosition();
    error LiquidityNotPermitted();
    error HookNotImplemented();
    error ZeroAmount();
    error Slippage(); // curve buy/sell output below the caller's min
    error InvalidMode();
    error InvalidFeeTier();
    error InvalidStartMcap();
    error InvalidFeeOwner();
    error InvariantBroken();
    error ZeroAddress();
    error EmptyName();
    error InvalidSnipeBps();
    error InvalidDecaySeconds();
    error BuyExceedsCap();
    error AlreadyLaunched();
    error NothingToWithdraw();
    error GraveyardPeriodTooShort(); // setGraveyardPeriod below the 180-day floor
    error UnknownToken(); // graveyardSweep on an unregistered token
    error NothingToSweep(); // no live sweepable LP (curving PUMP / unseeded)
    error NotDead(); // pool traded within graveyardPeriod
    error AlreadySwept(); // graveyard sweep already run for this pool
    error AlreadySet(); // one-time setter called twice (dividendDistributor)
    error QuoteNotAllowed(); // RWA quote asset not on the owner allowlist
    error InvalidTax(); // RWA taxBps / split out of bounds
    error DistributorNotSet(); // RWA launch before the distributor is wired

    // -------------------------------------------------------------------
    // Events (frozen per V4_HOOK_SPEC.md Section 14)
    // -------------------------------------------------------------------

    event LaunchCreated(PoolId indexed poolId, address indexed token, address creator, uint8 mode);
    /// @notice Emitted when a CLANKER launch attributes its creator fees to a
    ///         Twitter handle. The backend binds `poolId` <-> `handle` here; the
    ///         handle is NOT stored on-chain (the escrow keys by poolId only).
    event FeeAttributedToHandle(PoolId indexed poolId, address indexed escrow, string handle);
    event CurveBuy(PoolId indexed poolId, address indexed buyer, uint256 grossUsdcIn, uint256 tokensOut);
    event CurveSell(PoolId indexed poolId, address indexed seller, uint256 tokensIn, uint256 usdcOut);
    event Graduated(PoolId indexed poolId, uint256 finalUsdcReserve, uint256 tokensInLP);
    // `currency` disambiguates the fee token: post-grad PUMP + graduation fees
    // are always USDC, but a CLANKER harvest emits RoyaltyPaid for BOTH the USDC
    // and the launch-token side. Indexers must key USDC fee stats off currency
    // == USDC, or a token-denominated (18dp) amount pollutes the 6dp USDC tally.
    event RoyaltyPaid(
        PoolId indexed poolId,
        address indexed creator,
        uint256 creatorAmount,
        uint256 treasuryAmount,
        address currency
    );
    event AntiSnipeApplied(PoolId indexed poolId, address indexed sniper, uint256 amount, uint16 bps);
    /// @notice Emitted for the PER-SWAP treasury fee ONLY (beforeSwap/afterSwap),
    ///         never on the collectFees harvest. Off-chain referral attribution
    ///         reads THIS (crediting tx.origin/tx.from as the trader) instead of
    ///         RoyaltyPaid, which is also emitted by the permissionless
    ///         collectFees harvest and is therefore spoofable into an over-credit
    ///         via a wrapper contract (audit 2026-07-24). The amount is always
    ///         USDC (both swap fee paths capture in USDC). No indexed trader:
    ///         hooks only see the router as `sender`; the real EOA is the tx
    ///         sender, which the indexer already uses for the paired Swap event.
    event SwapTreasuryFee(PoolId indexed poolId, uint256 treasuryUsdc);
    event DividendDistributorSet(address indexed distributor);
    event ClankerQuoteSet(
        address indexed quote, uint256 defaultMcap, uint256 minMcap, uint256 maxMcap, bool isDefault
    );
    event RwaQuoteAllowedSet(address indexed asset, bool allowed);
    event RwaGraveyardSinkSet(address indexed sink);
    event EscrowCreditFailed(uint256 indexed positionId, uint8 slot, uint256 amount);
    event PositionLocked(bytes32 indexed positionKey, address indexed owner, uint128 liquidity);
    event FeeHarvested(bytes32 indexed positionKey, uint256 amount0, uint256 amount1);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TwitterEscrowUpdated(address indexed oldEscrow, address indexed newEscrow);
    event TokenForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);
    event ClankerBuyCapSet(uint16 maxBuyBps, uint32 windowSecs);
    event SnipeConfigured(address indexed token, uint16 startBps, uint32 decaySeconds);
    event TokenCredited(address indexed token, address indexed recipient, uint256 amount);
    event TokenPendingClaimed(address indexed token, address indexed recipient, uint256 amount);
    event TokenLaunched(
        address indexed token,
        address indexed creator,
        uint8 mode,
        string name,
        string symbol,
        string metadataURI
    );
    /// @notice A dead pool's stranded locked LP was swept to the treasury.
    event GraveyardSwept(PoolId indexed poolId, address indexed token, uint256 usdcOut, uint256 tokenOut);
    event GraveyardPeriodUpdated(uint40 oldPeriod, uint40 newPeriod);

    // -------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    // -------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------

    constructor(
        IPoolManager poolManager_,
        Currency usdc_,
        address lockedVault_,
        address treasury_,
        address twitterEscrow_,
        address owner_
    ) Ownable(owner_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        if (Currency.unwrap(usdc_) == address(0)) revert ZeroAddress();
        if (lockedVault_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        // twitterEscrow_ allowed to be zero; disables the escrow path until
        // an admin wires it via setTwitterEscrow. Keeps mainnet bootstrap from
        // requiring all peripheral contracts to be live on day 1.

        POOL_MANAGER = poolManager_;
        USDC = usdc_;
        LOCKED_VAULT = lockedVault_;
        TREASURY = treasury_;
        twitterEscrow = twitterEscrow_;

        // Default CLANKER anti-snipe cap: 1% of supply per buy for the first 5
        // minutes. Owner-tunable (or disable with 0 bps) via setClankerBuyCap.
        clankerMaxBuyBps = 100;
        clankerCapWindowSecs = 300;

        // Graveyard sweep: a pool with ZERO trading for a full year is treated
        // as dead and its stranded locked LP may be permissionlessly swept to
        // the treasury. Owner-tunable down to a hard 180-day floor only.
        graveyardPeriod = 365 days;
    }

    // -------------------------------------------------------------------
    // Hook permissions (frozen)
    // -------------------------------------------------------------------

    /// @notice Returns the 14-bit hook permission flag bitmap. The deployed
    ///         address MUST encode exactly these bits in its low 14 bits.
    /// @dev Total: 10 bits set. Hex: 0x3ECE = 16078.
    function getHookPermissions() public pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
    }

    // -------------------------------------------------------------------
    // Launch lifecycle
    // -------------------------------------------------------------------

    /**
     * @notice Register a new launch, deploy its ERC20, AND initialise the V4
     *         pool atomically. The hook holds the full token supply during
     *         curving and trades it against the bonding curve in beforeSwap.
     *         At graduation (Round 4), the unsold remainder becomes the LP
     *         seed for a canonical AMM position.
     *
     *         Pulls the flat creation fee in USDC straight to treasury before
     *         anything else, so a token never lands on-chain unless the
     *         caller actually paid.
     *
     * @param name             ERC20 name
     * @param symbol           ERC20 symbol
     * @param metadataURI      off-chain metadata URI (ipfs:// or data:)
     * @param mode             0=PUMP, 1=CLANKER, 2=CLANKER_V3
     * @param creator2         optional secondary fee recipient (CLANKER only).
     *                          Pass address(0) to disable.
     * @param creator2Bps      share of creator fee routed to creator2 (bps).
     *                          Ignored when creator2 == address(0).
     * @param snipeStartBps    starting anti-sniper tax (0..MAX_SNIPE_START_BPS).
     *                          Pass 0 to disable anti-sniper for this token.
     * @param snipeDecaySeconds linear decay window for the anti-sniper tax.
     *                          Required > 0 when snipeStartBps > 0.
     * @param feeTier          CLANKER only: the fixed post-graduation trading
     *                          fee tier, 1 (1%), 2 (2%) or 3 (3%). IGNORED for
     *                          PUMP, which uses the mcap-decaying dynamic fee.
     * @param twitterHandle    CLANKER only: pass a non-empty handle to route the
     *                          launch's creator fees to a handle-gated escrow
     *                          slot (claimable by the verified handle owner)
     *                          instead of the launcher's wallet. Requires the
     *                          hook to have a `twitterEscrow` wired. Emitted
     *                          (not stored) so the backend binds poolId<->handle.
     *                          Empty string (or PUMP) = fees go direct.
     * @param creatorBuyUsdc    PUMP only: optional USDC the launcher buys on the
     *                          curve ATOMICALLY in this same tx (the first buy,
     *                          unbypassable). 0 = no creator buy. Reverts on
     *                          CLANKER. Approve CREATION_FEE + creatorBuyUsdc.
     */
    /// @notice Create a launch. `quoteSel` picks the pair: 0 follow the
    ///         protocol default, 1 force USDC, 2 force the configured quote.
    ///
    /// @dev ONE entrypoint on purpose. A twelve-argument overload that forwarded
    ///      with quoteSel = 0 would be friendlier to existing callers, and it was
    ///      measured: it cost 1,847 bytes because the forwarder has to re-encode
    ///      three `string calldata` arguments, which pushed the hook 923 bytes
    ///      OVER EIP-170 and made it undeployable. Every caller is ours, so they
    ///      pass the extra argument instead. `quoteSel`: 0 follow
    ///         the default, 1 force USDC, 2 force the configured quote. This is
    ///         what the web launcher calls once a user picks.
    function createLaunch(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint8 mode,
        address creator2,
        uint16 creator2Bps,
        uint16 snipeStartBps,
        uint32 snipeDecaySeconds,
        uint8 feeTier,
        string calldata twitterHandle,
        uint256 startMcapUsdc,
        uint256 creatorBuyUsdc,
        uint8 quoteSel
    ) external nonReentrant whenNotPaused returns (address tokenAddr, PoolId poolId) {
        // Common PUMP/CLANKER setup (validation, deploy, state, events, CLANKER
        // seed) lives in ArcadeHookLib.createLaunchCore (delegatecall) so the hook
        // stays under EIP-170. The two atomic DEV-BUYS stay here: they use the
        // standalone `_creatorBuying` flag and `_doCurveBuy`, which cannot cross
        // the library boundary.
        (tokenAddr, poolId) = ArcadeHookLib.createLaunchCore(
            POOL_MANAGER,
            USDC,
            ArcadeHookLib.CreateParams({
                name: name,
                symbol: symbol,
                metadataURI: metadataURI,
                twitterHandle: twitterHandle,
                mode: mode,
                creator: msg.sender,
                creator2: creator2,
                creator2Bps: creator2Bps,
                snipeStartBps: snipeStartBps,
                snipeDecaySeconds: snipeDecaySeconds,
                feeTier: feeTier,
                startMcapUsdc: startMcapUsdc,
                twitterEscrow: twitterEscrow,
                tokenForwarder: tokenForwarder,
                treasury: TREASURY,
                // CLANKER only. PUMP stays on USDC whatever the hook holds.
                quote: _resolveClankerQuote(mode, quoteSel),
                quoteDefaultMcap: clankerQuoteDefaultMcap,
                quoteMinMcap: clankerQuoteMinMcap,
                quoteMaxMcap: clankerQuoteMaxMcap
            }),
            registeredLaunches,
            allTokens,
            poolFeeOf,
            poolIdOf,
            curveStates,
            feeOwners,
            snipeConfigs,
            clankerPos,
            lastTradeAt,
            quoteAssetOf
        );

        // CLANKER optional atomic DEV BUY: swap creatorBuyUsdc USDC -> the launch
        // token through the just-seeded pool, delivering to the creator. Runs
        // inline (after the seed's unlock returned, before createLaunch returns) so
        // the creator is provably the first buyer. Bounded to CREATOR_DEV_BUY_MAX_BPS
        // (10%) inside the kind-4 handler; over-cap reverts the whole launch.
        // createLaunchCore already recorded the pair (it must: the seed unlocks
        // inside it). Read it back rather than re-deriving, so the dev-buy can
        // never disagree with the pool that was just opened.
        address clankerQuoteUsed = quoteAssetOf[tokenAddr];

        if (mode == uint8(LaunchMode.CLANKER) && creatorBuyUsdc > 0) {
            // Pull the PAIR asset, not USDC. `creatorBuyUsdc` keeps its name
            // because the external signature is unchanged; it is denominated in
            // whatever this launch pairs against.
            IERC20(clankerQuoteUsed == address(0) ? Currency.unwrap(USDC) : clankerQuoteUsed)
                .safeTransferFrom(msg.sender, address(this), creatorBuyUsdc);
            _creatorBuying = true;
            POOL_MANAGER.unlock(abi.encode(uint8(4), tokenAddr, creatorBuyUsdc, uint256(0), int24(0)));
            _creatorBuying = false;
            // (The old per-block cumulative cap recorded the dev-buy into
            // clankerBlockBuy here; the per-tx ramp judges each buy alone, so no
            // recording is needed -- the dev-buy is exempt regardless.)
        }

        // PUMP optional CREATOR BUY: atomic first purchase, exempt from the curve
        // anti-sniper tax (applyTax=false) but bounded to CREATOR_DEV_BUY_MAX_BPS
        // (10%) on the delivered amount; over-cap reverts.
        if (mode == uint8(LaunchMode.PUMP) && creatorBuyUsdc > 0) {
            CurveState storage freshState = curveStates[poolId];
            (uint256 devTokens,) =
                _doCurveBuy(tokenAddr, poolId, freshState, msg.sender, creatorBuyUsdc, 0, false);
            if (devTokens > (ArcadeV4Curve.TOTAL_SUPPLY * ArcadeHookLib.CREATOR_DEV_BUY_MAX_BPS) / 10_000) {
                revert ArcadeHookLib.DevBuyExceedsCap();
            }
        }
    }

    /// @notice RWA launch mode: a DIRECT single-sided launch paired against an
    ///         allowlisted RWA quote (Phase 1: USYC), paying volume-funded
    ///         dividends to holders. Separate entrypoint from createLaunch (the
    ///         RWA params differ: quote + tax split, no curve/twitter/creator2).
    ///         The heavy orchestration lives in ArcadeRwaLib (delegatecall) to
    ///         stay under EIP-170. `startMcap` is in QUOTE units (Phase 1 quotes
    ///         are 6-dp); 0 => 35k default, hard-capped at 100k.
    function createRwaLaunch(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        address quote,
        uint16 taxBps,
        uint16 holdersBps,
        uint256 startMcap,
        uint256 creatorBuyQuote,
        string calldata twitterHandle,
        address creator2,
        uint16 creator2Bps
    ) external nonReentrant whenNotPaused returns (address tokenAddr, PoolId poolId) {
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyName();
        if (dividendDistributor == address(0)) revert DistributorNotSet();
        if (rwaGraveyardSink == address(0)) revert ZeroAddress();
        if (!rwaQuoteAllowed[quote]) revert QuoteNotAllowed();
        // The quote must not itself be one of our launch tokens, or _tokenQuote /
        // the anti-sniper side-resolution would misfire (audit INFO-2).
        if (registeredLaunches[quote]) revert QuoteNotAllowed();
        uint256 mcap = startMcap == 0 ? RWA_DEFAULT_START_MCAP : startMcap;
        if (mcap < RWA_MIN_START_MCAP || mcap > RWA_MAX_START_MCAP) revert InvalidStartMcap();

        // Optional Twitter-@ fee attribution: a non-empty handle + the owner-wired
        // escrow routes the creator's QUOTE cut to a handle-gated escrow slot (the
        // verified @ owner claims it), else the creator is paid directly.
        address launchEscrow =
            (bytes(twitterHandle).length > 0 && twitterEscrow != address(0)) ? twitterEscrow : address(0);

        // "Another wallet" (creator2) routes a share of the creator's quote cut to
        // an alternate address. It is mutually exclusive with the @handle escrow
        // (the escrow takes precedence in _payCreatorCut) and needs a real recipient.
        if (creator2 == address(0) || launchEscrow != address(0)) creator2Bps = 0;
        if (creator2Bps > 10_000) creator2Bps = 10_000;

        // Creation fee (same 3 USDC as createLaunch), pulled before any deploy.
        IERC20(Currency.unwrap(USDC)).safeTransferFrom(msg.sender, TREASURY, CREATION_FEE);

        (tokenAddr, poolId) = ArcadeRwaLib.createRwaLaunch(
            POOL_MANAGER,
            ArcadeRwaLib.RwaCreate({
                name: name,
                symbol: symbol,
                quote: quote,
                taxBps: taxBps,
                holdersBps: holdersBps,
                startMcap: mcap,
                creator: msg.sender,
                creator2: creator2,
                creator2Bps: creator2Bps,
                distributor: dividendDistributor,
                custody: address(POOL_MANAGER),
                graveyardSink: rwaGraveyardSink,
                twitterEscrow: launchEscrow,
                hasDevBuy: creatorBuyQuote > 0 // exclude the dev from S for the bootstrap
            }),
            registeredLaunches,
            allTokens,
            quoteAssetOf,
            poolFeeOf,
            poolIdOf,
            curveStates,
            feeOwners,
            rwaConfigs,
            clankerPos,
            lastTradeAt
        );

        emit TokenLaunched(tokenAddr, msg.sender, uint8(LaunchMode.RWA), name, symbol, metadataURI);
        emit LaunchCreated(poolId, tokenAddr, msg.sender, uint8(LaunchMode.RWA));
        if (launchEscrow != address(0)) emit FeeAttributedToHandle(poolId, launchEscrow, twitterHandle);

        // Optional atomic DEV BUY: swap creatorBuyQuote of the QUOTE (e.g. USYC) ->
        // the launch token through the just-seeded pool, delivering to the creator.
        // Runs inline (after the seed's unlock returned, before this call returns) so
        // the creator is provably the first buyer. Exempt from the per-tx anti-sniper
        // (afterSwap is not re-entered on the hook's own swap) but bounded to
        // CREATOR_DEV_BUY_MAX_BPS (10%) in the kind-4 handler; over-cap reverts.
        if (creatorBuyQuote > 0) {
            IERC20(quote).safeTransferFrom(msg.sender, address(this), creatorBuyQuote);
            _creatorBuying = true;
            POOL_MANAGER.unlock(abi.encode(uint8(4), tokenAddr, creatorBuyQuote, uint256(0), int24(0)));
            _creatorBuying = false;
        }
    }

    // -------------------------------------------------------------------
    // ILaunchpadSnipe (anti-sniper config read by the prior hook prototype,
    // kept here so the same surface works against the unified hook).
    // -------------------------------------------------------------------

    /// @notice Current snipe tax rate (bps) for `token`. Linear decay from
    ///         `startBps` at launch to 0 after `decaySeconds`. Returns 0 if
    ///         the token has no snipe config or the window has elapsed.
    function currentSnipeBps(address token) external view returns (uint256) {
        return _currentSnipeBps(token);
    }

    /// @notice The live trading fee (bps) a GRADUATED pool currently charges.
    ///         PUMP pools decay from 1% at graduation toward the 0.30% floor as
    ///         market cap grows (driven by the manipulation-resistant price
    ///         EMA); CLANKER pools return their fixed tier. Returns 0 for a
    ///         token that has not graduated. For UI display + off-chain quoting.
    function currentFeeBps(address token) external view returns (uint256) {
        PoolId poolId = poolIdOf[token];
        CurveState memory state = curveStates[poolId];
        if (state.status != uint8(Status.Graduated)) return 0;
        // RWA: the fee is the creator-set tax (native LP fee), not the PUMP/CLANKER
        // _feeBps path (which would mis-report 1%) -- audit LOW-1.
        if (state.mode == uint8(LaunchMode.RWA)) return rwaConfigs[token].taxBps;
        return _feeBps(state.mode, poolId);
    }

    /// @notice Harvest a CLANKER launch's accrued pool LP fees from its locked
    ///         position and distribute them 80/20 (creator/treasury; the USDC
    ///         creator cut routes to the handle escrow when the launch attributed
    ///         to a Twitter handle, the token cut goes direct to the creator).
    ///         Permissionless: anyone can trigger a harvest; funds always follow
    ///         the fixed split. Only CLANKER direct launches (which use the
    ///         native pool fee) have a position to harvest.
    function collectFees(address token) external nonReentrant whenNotPaused {
        if (!clankerPos[token].seeded) revert InvalidMode();
        // RWA reuses the same single-sided seeded position, so its seeded flag is
        // also true -- but its fees MUST go through harvestRwaFees (3-way split +
        // dividend accrual), NOT the CLANKER 80/20 collect. Reject RWA here or the
        // holders' dividend share would be diverted to the creator (audit HIGH-1).
        if (curveStates[poolIdOf[token]].mode == uint8(LaunchMode.RWA)) revert InvalidMode();
        POOL_MANAGER.unlock(abi.encode(uint8(2), token, uint256(0), uint256(0), int24(0)));
    }

    /// @notice Permissionlessly harvest an RWA launch's accrued fees: collect the
    ///         native LP fee from the locked position, convert the token part to
    ///         quote, and route it 3-way (platform/creator/holders) -- the holders
    ///         bucket funds + accrues to the dividend distributor. Anyone can call
    ///         it (a holder, a keeper, the creator); dividends accrue on each harvest.
    function harvestRwaFees(address token) external nonReentrant whenNotPaused {
        if (curveStates[poolIdOf[token]].mode != uint8(LaunchMode.RWA)) revert InvalidMode();
        POOL_MANAGER.unlock(abi.encode(uint8(5), token, uint256(0), uint256(0), int24(0)));
    }

    /// @notice Permissionlessly sweep a DEAD pool's stranded locked LP to the
    ///         treasury. Dead tokens otherwise strand their permanently-locked
    ///         liquidity forever. This is the ONLY removal path on the locked LP;
    ///         it is gated so it is IMPOSSIBLE to trigger on a live pool:
    ///           - the token must be registered (UnknownToken);
    ///           - a live sweepable LP must exist: PUMP must be GRADUATED, or
    ///             CLANKER must be seeded (NothingToSweep);
    ///           - the pool must have traded at least once (lastTradeAt != 0);
    ///           - and NOT traded for `graveyardPeriod` (>= 180 days) -- ANY
    ///             curve trade or graduated swap resets lastTradeAt, so a pool
    ///             touched within the window reverts NotDead;
    ///           - one-shot: a second sweep reverts AlreadySwept.
    ///         Both withdrawn sides go to the treasury via the SAME pull-safe
    ///         path fee distribution uses (_safeTake, with a pending fallback),
    ///         so a blocked treasury can never brick the sweep. Permissionless,
    ///         nonReentrant, CEI-ordered (graveyardSwept set before the unlock).
    function graveyardSweep(address token) external nonReentrant {
        if (!registeredLaunches[token]) revert UnknownToken();
        PoolId poolId = poolIdOf[token];
        CurveState memory state = curveStates[poolId];

        // A live, sweepable LP must exist. PUMP: only a GRADUATED pool has an LP
        // (a curving pool holds none). CLANKER: the single-sided seed must be in.
        bool pumpGraduated = state.mode == uint8(LaunchMode.PUMP) && state.status == uint8(Status.Graduated);
        bool clankerSeeded = state.mode == uint8(LaunchMode.CLANKER) && clankerPos[token].seeded;
        bool rwaSeeded = state.mode == uint8(LaunchMode.RWA) && clankerPos[token].seeded;
        if (!pumpGraduated && !clankerSeeded && !rwaSeeded) revert NothingToSweep();

        uint40 last = lastTradeAt[poolId];
        // Never traded/seeded (defensive: seeding always stamps it) OR still
        // within the no-trade window => the pool is alive, not dead.
        if (last == 0) revert NotDead();
        if (block.timestamp - uint256(last) < uint256(graveyardPeriod)) revert NotDead();
        if (graveyardSwept[poolId]) revert AlreadySwept();

        // CEI: mark swept BEFORE the external unlock / transfers. Combined with
        // nonReentrant + the one-shot flag, the removal can never run twice.
        // INVARIANT (audit L-1): a qualifying pool (graduated/seeded + not yet
        // swept) always holds liq > 0 because this is the ONLY removal path, so
        // marking swept here never strands real liquidity. If a future change adds
        // another way to zero the position, gate this on liq > 0 instead.
        graveyardSwept[poolId] = true;

        // For RWA, pack the never-rotated sink into the data so the kind-3 handler
        // routes the swept launch TOKEN there (excluded from S), quote -> treasury.
        // CLANKER/PUMP pass 0 -> both sides to treasury (unchanged).
        uint256 sinkPacked = rwaSeeded ? uint256(uint160(rwaGraveyardSink)) : 0;
        _graveyardSweeping = true;
        bytes memory ret = POOL_MANAGER.unlock(abi.encode(uint8(3), token, sinkPacked, uint256(0), int24(0)));
        _graveyardSweeping = false;

        (uint256 usdcOut, uint256 tokenOut) = abi.decode(ret, (uint256, uint256));
        emit GraveyardSwept(poolId, token, usdcOut, tokenOut);
    }

    // -------------------------------------------------------------------
    // Owner controls
    // -------------------------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(TREASURY, newTreasury);
        TREASURY = newTreasury;
    }

    function setTwitterEscrow(address newEscrow) external onlyOwner {
        // Zero address is intentional: clears the escrow target entirely.
        emit TwitterEscrowUpdated(twitterEscrow, newEscrow);
        twitterEscrow = newEscrow;
    }

    /// @notice Set the token-side fee forwarder for handle-attributed launches
    ///         (see tokenForwarder). Zero clears it (token side falls back to the
    ///         launcher). Only affects launches created AFTER this call -- each
    ///         launch snapshots FeeOwner.creator at createLaunch time.
    function setTokenForwarder(address newForwarder) external onlyOwner {
        emit TokenForwarderUpdated(tokenForwarder, newForwarder);
        tokenForwarder = newForwarder;
    }

    /// @notice Wire the dividend distributor once (RWA mode). One-way: it cannot be
    ///         re-pointed after being set, so every RWA launch's registration
    ///         target is stable and un-rug-able.
    function setDividendDistributor(address d) external onlyOwner {
        if (d == address(0)) revert ZeroAddress();
        if (dividendDistributor != address(0)) revert AlreadySet();
        dividendDistributor = d;
        emit DividendDistributorSet(d);
    }

    /// @notice Owner-curate the RWA quote-asset allowlist (Phase 1: USYC). Only
    ///         gates NEW launches; an existing launch snapshots its quote immutably
    ///         at createLaunch, so de-listing never traps a live launch's dividends.
    ///         The owner MUST verify an asset is non-rebasing / non-FoT / non-callback
    ///         before allowlisting it (spec B1/M7).
    /// @notice Select the pair asset for NEW Clanker launches, or clear it.
    ///
    ///         Pass `quote = 0` to go back to USDC. Existing launches are NOT
    ///         touched: a pool's pair is fixed at creation, so this only ever
    ///         changes what the NEXT launch opens against. That is what makes it
    ///         safe to flip on and off.
    ///
    /// @dev The bounds are in the quote's own units and are validated as an
    ///      ordered triple. Getting them wrong is the one way this can hurt: a
    ///      default that is nonsense in the quote's decimals opens every pool at
    ///      the wrong price, and there is no oracle here to catch it.
    function setClankerQuote(
        address quote,
        uint256 defaultMcap,
        uint256 minMcap,
        uint256 maxMcap,
        bool makeDefault
    ) external onlyOwner {
        if (quote == address(0)) {
            clankerQuote = address(0);
            clankerQuoteDefaultMcap = 0;
            clankerQuoteMinMcap = 0;
            clankerQuoteMaxMcap = 0;
            // Clearing the asset must clear the default with it, or a later
            // launch would resolve "default" to an asset that is no longer set.
            clankerQuoteIsDefault = false;
            emit ClankerQuoteSet(address(0), 0, 0, 0, false);
            return;
        }
        // USDC is expressed as the zero address, so a caller cannot end up with
        // two different encodings of the same default.
        if (quote == Currency.unwrap(USDC)) revert QuoteNotAllowed();
        // Same guard the RWA path uses: a quote that is itself one of our launch
        // tokens would make the anti-sniper side-resolution misfire.
        if (registeredLaunches[quote]) revert QuoteNotAllowed();
        // An EOA here would deploy pools against an address that cannot transfer.
        if (quote.code.length == 0) revert QuoteNotAllowed();
        if (minMcap == 0 || defaultMcap < minMcap || maxMcap < defaultMcap) revert InvalidStartMcap();
        clankerQuote = quote;
        clankerQuoteDefaultMcap = defaultMcap;
        clankerQuoteMinMcap = minMcap;
        clankerQuoteMaxMcap = maxMcap;
        clankerQuoteIsDefault = makeDefault;
        emit ClankerQuoteSet(quote, defaultMcap, minMcap, maxMcap, makeDefault);
    }

    /// @notice Flip which asset a no-preference launch pairs against, without
    ///         re-stating the bounds. This is the switch the tweet-launch path
    ///         follows.
    /// @dev Pair asset for this launch. PUMP is always USDC. A caller may only
    ///      choose between USDC and the ONE owner-configured asset, never an
    ///      arbitrary address, so a launch can never open against a token the
    ///      protocol has not vetted. Asking for the configured quote when none
    ///      is set REVERTS rather than silently falling back to USDC: a creator
    ///      who chose a pair should not get a different one without being told.
    function _resolveClankerQuote(uint8 mode, uint8 quoteSel) internal view returns (address) {
        if (mode != uint8(LaunchMode.CLANKER)) return address(0);
        if (quoteSel == QUOTE_SEL_USDC) return address(0);
        if (quoteSel == QUOTE_SEL_CONFIGURED) {
            if (clankerQuote == address(0)) revert QuoteNotAllowed();
            return clankerQuote;
        }
        if (quoteSel != QUOTE_SEL_DEFAULT) revert QuoteNotAllowed();
        return clankerQuoteIsDefault ? clankerQuote : address(0);
    }

    function setClankerQuoteIsDefault(bool makeDefault) external onlyOwner {
        if (makeDefault && clankerQuote == address(0)) revert QuoteNotAllowed();
        clankerQuoteIsDefault = makeDefault;
        emit ClankerQuoteSet(
            clankerQuote, clankerQuoteDefaultMcap, clankerQuoteMinMcap, clankerQuoteMaxMcap, makeDefault
        );
    }

    function setRwaQuoteAllowed(address asset, bool allowed) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        rwaQuoteAllowed[asset] = allowed;
        emit RwaQuoteAllowedSet(asset, allowed);
    }

    /// @notice Set the permanent RWA graveyard sink (distributor audit MEDIUM-1):
    ///         a never-rotated, dividend-excluded address that receives RWA
    ///         graveyard-swept launch tokens AND the harvest partial-fill residual,
    ///         so the rotatable treasury never custodies launch tokens and pollutes
    ///         the dividend share base.
    /// @dev ONE-WAY (RWA system audit LOW-1): the sink is excluded from the
    ///      distributor's share base at each launch's REGISTRATION. If it could
    ///      rotate, a later graveyard sweep / harvest residual would deposit the
    ///      full launch-token supply at a NON-excluded address, inflating S and
    ///      letting claimFor over-claim the reserve. Set once, never re-pointed --
    ///      so the wired sink always equals every launch's registered excluded sink.
    function setRwaGraveyardSink(address sink) external onlyOwner {
        if (sink == address(0)) revert ZeroAddress();
        if (rwaGraveyardSink != address(0)) revert AlreadySet();
        rwaGraveyardSink = sink;
        emit RwaGraveyardSinkSet(sink);
    }

    /// @notice Tune the CLANKER first-window anti-snipe buy cap. A single buy
    ///         whose token output exceeds `maxBuyBps` of TOTAL_SUPPLY within
    ///         `windowSecs` of launch reverts. `maxBuyBps == 0` disables it.
    ///         The single-sided CLANKER pool cannot carry a take-based tax, so
    ///         this revert-based cap is its only block-0 snipe defense.
    function setClankerBuyCap(uint16 maxBuyBps, uint32 windowSecs) external onlyOwner {
        // No upper bound needed: bps > 10_000 makes the cap exceed TOTAL_SUPPLY,
        // i.e. unreachable (a harmless "disabled"), same as bps == 0.
        clankerMaxBuyBps = maxBuyBps;
        clankerCapWindowSecs = windowSecs;
        emit ClankerBuyCapSet(maxBuyBps, windowSecs);
    }

    /// @notice Tune the graveyard no-trade period. Hard 180-day FLOOR: a shorter
    ///         window is rejected (GraveyardPeriodTooShort). This floor is the
    ///         critical anti-rug guard -- it makes it impossible for the owner to
    ///         shrink the window toward zero and sweep a live pool. There is no
    ///         upper bound (a longer window only makes sweeping harder).
    function setGraveyardPeriod(uint40 newPeriod) external onlyOwner {
        if (newPeriod < 180 days) revert GraveyardPeriodTooShort();
        emit GraveyardPeriodUpdated(graveyardPeriod, newPeriod);
        graveyardPeriod = newPeriod;
    }

    // -------------------------------------------------------------------
    // Pull-payment escape hatch (CSEC-001)
    // -------------------------------------------------------------------

    /// @notice Withdraw any token credited to `msg.sender` from a failed inline
    ///         payout. Permissionless; always pays back to the original
    ///         recipient. The recipient must be unblocked on the underlying
    ///         token before calling.
    function claimPendingToken(address token) external nonReentrant returns (uint256 amount) {
        amount = pendingTokenWithdrawals[token][msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingTokenWithdrawals[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenPendingClaimed(token, msg.sender, amount);
    }

    // -------------------------------------------------------------------
    // Hook callbacks - FOUNDATION ONLY
    //
    // All callbacks the hook claims (per getHookPermissions) return the
    // selector + safe default delta. Round 3 fills in beforeSwap, Round 4
    // graduation, Round 5 royalty + locked LP.
    //
    // The unused slots (after-remove, both donates, after-remove-returns-delta)
    // revert HookNotImplemented so a misconfigured PoolManager that
    // dispatched to them anyway gets a clear signal.
    // -------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160 /*sqrtPriceX96*/ )
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Only the hook's own createLaunch can spawn pools. Random callers
        // hitting pm.initialize(key, ...) with our hook address would
        // otherwise be able to register a pool with a token that isn't ours.
        if (sender != address(this)) revert OnlyLaunchpad();

        // Exactly one side must be one of OUR registered launch tokens, and the
        // other side must be that launch's snapshotted QUOTE: USDC for PUMP/CLANKER
        // (quoteAssetOf == 0), the RWA quote (e.g. USYC) for an RWA launch. This
        // guards against registering an unexpected pair under our hook. Backward-
        // compatible: for a USDC-paired launch, expectedQuote resolves to USDC and
        // the check is identical to the old "exactly one side == USDC".
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool c0Reg = registeredLaunches[c0];
        bool c1Reg = registeredLaunches[c1];
        if (c0Reg == c1Reg) revert LaunchNotRegistered(); // exactly one side is ours

        address launchToken = c0Reg ? c0 : c1;
        address other = c0Reg ? c1 : c0;
        address expectedQuote = quoteAssetOf[launchToken];
        if (expectedQuote == address(0)) expectedQuote = Currency.unwrap(USDC);
        if (other != expectedQuote) revert NotUsdcPair();

        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(
        address, /*sender*/
        PoolKey calldata, /*key*/
        uint160, /*sqrtPriceX96*/
        int24 /*tick*/
    ) external view override onlyPoolManager returns (bytes4) {
        // State for this pool (CurveState + FeeOwner + poolIdOf) was already
        // populated atomically in createLaunch, before the initialize call.
        // Nothing else to do here; the selector return is the contract.
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata, /*params*/
        bytes calldata /*hookData*/
    ) external view override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        CurveState storage state = curveStates[poolId];

        // No LP during the bonding curve phase: LPs would extract value from
        // curve buyers. The post-grad pool is also locked after the
        // graduation seed.
        //
        // IMPORTANT: the graduation seed itself does NOT reach this callback.
        // v4-core's Hooks.beforeModifyLiquidity carries `noSelfCall`, so when
        // the hook calls POOL_MANAGER.modifyLiquidity on its OWN pool during
        // _graduate/unlockCallback, this hook is skipped -- otherwise the
        // GraduationStarted guard below would revert the seed and brick
        // graduation. The seed LP's immutability therefore rests on (a) it being
        // a v4 position OWNED BY THE HOOK (v4 keys positions by caller) and (b)
        // the hook exposing no modifyLiquidity(negative delta) path -- NOT on
        // the PositionInfo.locked bookkeeping, which noSelfCall leaves unset.
        if (state.status == uint8(Status.GraduationStarted)) revert GraduationInProgress();
        if (state.status == uint8(Status.Curving)) revert LiquidityNotPermitted();
        // status == Graduated: only the hook itself can add LP. Any external add
        // is rejected so post-graduation LP stays as the locked seed forever.
        if (sender != address(this)) revert LiquidityNotPermitted();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta, /*delta*/
        BalanceDelta, /*feesAccrued*/
        bytes calldata /*hookData*/
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // Mark the graduation-seed position as locked. Subsequent
        // beforeRemoveLiquidity calls revert unless liquidityDelta == 0
        // (fee harvest path).
        if (sender == address(this) && params.liquidityDelta > 0) {
            bytes32 positionKey = keccak256(
                abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt)
            );
            // The locked-LP owner is the real launcher (CurveState.creator), NOT
            // FeeOwner.creator -- for a handle launch the latter is the token-fee
            // forwarder, which must not appear as the position owner.
            address positionOwner = curveStates[key.toId()].creator;
            uint128 liquidity = uint128(uint256(params.liquidityDelta));
            positions[positionKey] =
                PositionInfo({owner: positionOwner, liquidity: liquidity, locked: true});
            emit PositionLocked(positionKey, positionOwner, liquidity);
        }
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata, /*key*/
        ModifyLiquidityParams calldata params,
        bytes calldata /*hookData*/
    ) external view override onlyPoolManager returns (bytes4) {
        // ORDER MATTERS: the harvest exception MUST be checked before the
        // locked check, or a fee harvest of a locked position would revert.
        // Inverting these creates a fee-harvest DOS on the hook's own LP.
        if (params.liquidityDelta == 0 && sender == address(this)) {
            return IHooks.beforeRemoveLiquidity.selector;
        }

        // Graveyard-sweep exception: the hook's own FULL-liquidity removal of a
        // dead pool's locked LP, admitted ONLY while a sweep is in progress.
        // NARROW: requires BOTH sender == this hook AND the in-progress flag,
        // which only graveyardSweep sets (and clears in the same tx). An external
        // LP is neither, so this never weakens the lock for anyone else. In
        // practice v4-core's noSelfCall skips this callback for the hook's own
        // modifyLiquidity, so this branch is a defensive belt, never the gate.
        if (sender == address(this) && _graveyardSweeping) {
            return IHooks.beforeRemoveLiquidity.selector;
        }

        bytes32 positionKey = keccak256(
            abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt)
        );
        if (positions[positionKey].locked) revert LockedPosition();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        CurveState memory state = curveStates[poolId];

        // GraduationStarted: every concurrent swap during graduation reverts so
        // there is exactly one tx that observes the transition. Round 4 sets
        // and clears this status atomically inside its own graduation path.
        if (state.status == uint8(Status.GraduationStarted)) revert GraduationInProgress();

        // Curving: the pool has no LP during the bonding curve phase, so the
        // V4 swap path cannot work (PoolManager.take would fail trying to
        // pull USDC from a manager with no reserves). Force traders through
        // the direct hook.buy / hook.sell entrypoints below which use plain
        // ERC20 transferFrom, matching the V2 production launchpad's pattern.
        if (state.status == uint8(Status.Curving)) revert LiquidityNotPermitted();

        // Only graduated pools take a trading fee here.
        if (state.status != uint8(Status.Graduated)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // CLANKER charges its fee via the pool's NATIVE static LP fee (the tier),
        // which accrues to the hook-owned locked LP and is harvested by
        // collectFees. The hook takes NOTHING here -- a hook take would try to
        // pull USDC the single-sided pool doesn't hold. Only PUMP (fee-0 pool)
        // captures in the hook.
        if (state.mode == uint8(LaunchMode.CLANKER)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // RWA: the tax is the pool's NATIVE V4 LP fee (like CLANKER), so it accrues
        // into the locked position on every trade with NO hook take here (a hook
        // take can't work on a single-sided pool: the PoolManager holds no quote
        // reserves mid-swap). It is harvested + split 3-way + accrued to the
        // dividend distributor by harvestRwaFees(). The hook takes NOTHING here.
        if (state.mode == uint8(LaunchMode.RWA)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Always-USDC fee guarantee. The fee is ALWAYS charged in USDC. We can
        // only cleanly take on the SPECIFIED side here (beforeSwap deltas act
        // on the specified currency); afterSwap covers the UNSPECIFIED side.
        // So beforeSwap takes iff USDC is the specified currency (buy exact-in
        // = spend exact USDC; sell exact-out = receive exact USDC). When USDC
        // is unspecified, afterSwap takes instead. Exactly one path fires per
        // swap, so the fee is never double-charged.
        bool specifiedIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        Currency specifiedCurrency = specifiedIs0 ? key.currency0 : key.currency1;
        if (Currency.unwrap(specifiedCurrency) != Currency.unwrap(USDC)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Fee is on the specified USDC magnitude.
        uint256 amount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        if (amount == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 feeBps = _feeBps(state.mode, poolId);
        if (feeBps > MAX_TOTAL_TAKE_BPS) feeBps = MAX_TOTAL_TAKE_BPS;
        uint256 fee = (amount * feeBps) / 10_000;

        // Anti-sniper auction skim on BUYS only. A buy with USDC specified is
        // buy-exact-in (spending exact USDC). USDC specified on a SELL is
        // sell-exact-out (receiving exact USDC), not a buy, so no skim there.
        uint256 snipeSkim = 0;
        if (_isUsdcToTokenSwap(key, params, USDC)) {
            address launchToken = Currency.unwrap(key.currency0) == Currency.unwrap(USDC)
                ? Currency.unwrap(key.currency1)
                : Currency.unwrap(key.currency0);
            uint256 bps = _currentSnipeBps(launchToken);
            if (bps > 0) snipeSkim = (amount * bps) / 10_000;
        }

        // Combined hard cap: fee + snipe <= MAX_TOTAL_TAKE_BPS of the swap.
        // Clamp the snipe first (fee is the creator's core revenue); never
        // revert (a reverting hook bricks every swap on an immutable pool).
        uint256 maxTake = (amount * MAX_TOTAL_TAKE_BPS) / 10_000;
        if (fee > maxTake) fee = maxTake;
        if (fee + snipeSkim > maxTake) snipeSkim = maxTake - fee;

        ArcadeHookLib.payAntiSnipe(POOL_MANAGER, feeOwners, pendingTokenWithdrawals, poolId, USDC, snipeSkim, amount);
        ArcadeHookLib.distributeFee(
            POOL_MANAGER, feeOwners, pendingTokenWithdrawals, TREASURY, poolId, USDC, fee, state.mode, true
        );
        // Per-swap treasury fee for referral attribution (USDC). Mirrors
        // distributeFee's split: treasuryCut = fee - creatorCut.
        if (fee > 0) emit SwapTreasuryFee(poolId, fee - (fee * POST_GRAD_CREATOR_BPS) / 10_000);

        // Positive specified delta = the hook takes this many USDC units off
        // the specified side, so the swapper pays for everything taken above.
        uint256 totalTaken = fee + snipeSkim;
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(int256(totalTaken)), int128(0)),
            0
        );
    }

    // -------------------------------------------------------------------
    // Direct curve entrypoints (used during the Curving phase)
    //
    // The V4 swap mechanism is incompatible with a zero-liquidity custom
    // curve: PoolManager.take fails if the manager has no underlying balance
    // to forward, and adding LP during curving defeats the curve's purpose
    // (LPs would extract value from buyers). Instead, the hook exposes its
    // own buy / sell entrypoints that move USDC and launch tokens via plain
    // ERC20 transferFrom + transfer. This mirrors the V2 production
    // launchpad pattern and is what the Arcade frontend already speaks.
    //
    // Post-graduation (Round 4+), swaps return to the V4 router path because
    // the graduated pool has real liquidity backing the AMM math.
    // -------------------------------------------------------------------

    /**
     * @notice Buy launch tokens on the bonding curve. Pulls USDC from the
     *         caller via transferFrom, executes the curve math, distributes
     *         the curve fee per mode, and transfers tokens to the caller.
     *
     * @param token       Launch token (must be in registeredLaunches).
     * @param amountIn    USDC the buyer is willing to spend (6 dp).
     * @param minTokensOut Slippage floor on the tokens received.
     * @return tokensOut  Tokens delivered to the caller.
     * @return actualGross USDC actually consumed (== amountIn unless the
     *                    buy hits the graduation cap, deferred to Round 4).
     */
    function buy(address token, uint256 amountIn, uint256 minTokensOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut, uint256 actualGross)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (!registeredLaunches[token]) revert LaunchNotRegistered();

        PoolId poolId = poolIdOf[token];
        CurveState storage state = curveStates[poolId];
        if (state.status == uint8(Status.GraduationStarted)) revert GraduationInProgress();
        if (state.status == uint8(Status.Graduated)) revert LiquidityNotPermitted();
        if (state.mode == uint8(LaunchMode.CLANKER_V3)) revert InvalidMode();

        return _doCurveBuy(token, poolId, state, msg.sender, amountIn, minTokensOut, true);
    }

    /**
     * @dev Core bonding-curve buy, shared by the public {buy} and the atomic
     *      creator-buy inside {createLaunch}. Assumes the caller already checked
     *      status/mode. NOT nonReentrant itself: both call sites are external
     *      nonReentrant functions, and USDC + ArcadeLaunchToken have no transfer
     *      callbacks, so the pre-state-update transfers cannot be re-entered.
     */
    function _doCurveBuy(
        address token,
        PoolId poolId,
        CurveState storage state,
        address buyer,
        uint256 amountIn,
        uint256 minTokensOut,
        bool applyTax
    ) internal returns (uint256 tokensOut, uint256 actualGross) {
        ArcadeV4Curve.BuyResult memory r =
            ArcadeV4Curve.simulateBuy(state.tokensSold, state.realUsdcReserve, amountIn);

        if (r.tokensOut == 0) revert ZeroAmount();

        // Anti-sniper CURVE tax: a decaying skim (startBps -> 0 over the window,
        // anchored at createLaunch) taken as a TOKEN haircut on early buys and
        // split 80% creator / 20% treasury. `applyTax` is true ONLY from the
        // public buy(); the creator's atomic dev-buy calls this with false, so it
        // is structurally exempt (it never enters buy()). The skimmed tokens come
        // out of the buyer's allocation, i.e. from the hook's curve inventory.
        uint256 taxTokens = 0;
        if (applyTax) {
            uint256 bps = _currentSnipeBps(token);
            if (bps > 0) taxTokens = (r.tokensOut * bps) / 10_000;
        }
        uint256 netTokensOut = r.tokensOut - taxTokens;

        // Slippage guard on the NET tokens the buyer actually receives (never the
        // pre-tax gross, or the tax could silently break the buyer's minOut floor).
        if (netTokensOut < minTokensOut) revert Slippage();

        // Pull only what the curve actually accepts. In the cap (graduation)
        // path actualGross < amountIn and the residual stays with the buyer
        // automatically since we never transferFrom'd it.
        IERC20(Currency.unwrap(USDC)).safeTransferFrom(buyer, address(this), r.actualGross);

        // Distribute the curve fee out of the hook's accumulating balance.
        _distributeCurveFee(state.mode, r.fee, state.creator, state.creator2, state.creator2Bps);

        // Route the anti-sniper tax 80/20 creator/treasury (tokens from inventory).
        if (taxTokens > 0) {
            uint256 treasuryCut = (taxTokens * SNIPE_TREASURY_BPS) / 10_000;
            uint256 creatorCut = taxTokens - treasuryCut;
            if (treasuryCut > 0) IERC20(token).safeTransfer(TREASURY, treasuryCut);
            if (creatorCut > 0) IERC20(token).safeTransfer(state.creator, creatorCut);
            emit AntiSnipeApplied(poolId, buyer, taxTokens, uint16((taxTokens * 10_000) / r.tokensOut));
        }

        // Ship the NET launch tokens to the buyer from the hook's balance.
        IERC20(token).safeTransfer(buyer, netTokensOut);

        // NOTE: the transfers above run BEFORE this state update (not CEI). This
        // is safe ONLY because (a) both entry points are `nonReentrant`, and (b)
        // USDC and ArcadeLaunchToken have no transfer callbacks, so no re-entrant
        // read of the stale reserves is possible. Do NOT introduce a
        // callback-bearing fee currency or launch token without moving these
        // effects earlier.
        state.tokensSold += uint128(r.tokensOut);
        state.realUsdcReserve += uint128(r.actualGross - r.fee);

        emit CurveBuy(poolId, buyer, r.actualGross, r.tokensOut);

        // Graveyard clock: a trade just moved the pool. The graduating buy runs
        // through here too, so this also SEEDS the clock at graduation (the LP
        // first exists), satisfying "start the clock when the LP exists".
        lastTradeAt[poolId] = uint40(block.timestamp);

        // The curve is exhausted when tokensSold reaches CURVE_SUPPLY. Graduate
        // on that, NOT on `refund > 0`: an exact-fill buy (newUsdcReserve lands
        // exactly at the cap) and the cap-branch ceil-clip both fill the curve
        // with refund == 0, and gating on refund would leave the launch
        // permanently stuck at the cap (every later buy reverts ZeroAmount, so
        // _graduate becomes unreachable and the AMM pool is never seeded).
        if (ArcadeV4Curve.isGraduated(state.tokensSold)) {
            ArcadeHookLib.graduate(
                POOL_MANAGER,
                USDC,
                TREASURY,
                pendingTokenWithdrawals,
                feeObs,
                snipeConfigs,
                state,
                _buildPoolKey(token),
                token
            );
        }

        return (netTokensOut, r.actualGross);
    }

    /**
     * @notice Sell launch tokens back into the bonding curve. Pulls tokens
     *         from the caller via transferFrom, executes the curve math,
     *         distributes the curve fee per mode, and pays USDC to the
     *         caller. Dust sells that round to zero output revert with
     *         ZeroAmount rather than silently no-op'ing so the UI surfaces a
     *         clear "too small to sell" message.
     *
     * @param token       Launch token (must be in registeredLaunches).
     * @param tokensIn    Tokens the seller is sending in (18 dp).
     * @param minUsdcOut  Slippage floor on the USDC received.
     * @return usdcOut    USDC delivered to the caller (after curve fee).
     */
    function sell(address token, uint256 tokensIn, uint256 minUsdcOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        if (tokensIn == 0) revert ZeroAmount();
        if (!registeredLaunches[token]) revert LaunchNotRegistered();

        PoolId poolId = poolIdOf[token];
        CurveState storage state = curveStates[poolId];
        if (state.status == uint8(Status.GraduationStarted)) revert GraduationInProgress();
        if (state.status == uint8(Status.Graduated)) revert LiquidityNotPermitted();
        if (state.mode == uint8(LaunchMode.CLANKER_V3)) revert InvalidMode();

        ArcadeV4Curve.SellResult memory r =
            ArcadeV4Curve.simulateSell(state.tokensSold, state.realUsdcReserve, tokensIn);
        if (r.usdcOut == 0) revert ZeroAmount();
        if (r.usdcOut < minUsdcOut) revert Slippage();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        // Distribute the curve fee out of the hook's accumulated USDC, then
        // pay the net to the seller. The fee comes out FIRST so the seller's
        // payout never includes USDC that's about to be re-routed to creator
        // or treasury.
        _distributeCurveFee(state.mode, r.fee, state.creator, state.creator2, state.creator2Bps);
        IERC20(Currency.unwrap(USDC)).safeTransfer(msg.sender, r.usdcOut);

        state.tokensSold -= uint128(tokensIn);
        state.realUsdcReserve -= uint128(r.grossOut);

        emit CurveSell(poolId, msg.sender, tokensIn, r.usdcOut);
        lastTradeAt[poolId] = uint40(block.timestamp); // graveyard clock reset
        return r.usdcOut;
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /*hookData*/
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        CurveState memory state = curveStates[poolId];

        // Curving / GraduationStarted: nothing to do. Curving fees are taken
        // in hook.buy / hook.sell; GraduationStarted swaps revert in
        // beforeSwap before reaching here.
        if (state.status != uint8(Status.Graduated)) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        // Graveyard clock: reset on EVERY graduated swap (both modes, either
        // side), once per swap. afterSwap fires exactly once per swap for a
        // graduated pool, so this single cheap write keeps any live pool from
        // ever aging into a sweepable "dead" state.
        lastTradeAt[poolId] = uint40(block.timestamp);

        // CLANKER: fee is the pool's native LP fee (no hook take, no PUMP
        // oracle). The only hook action is the first-window anti-snipe buy cap.
        if (state.mode == uint8(LaunchMode.CLANKER)) {
            _enforcePerTxBuyLimit(key, params, delta);
            return (IHooks.afterSwap.selector, int128(0));
        }

        // RWA: nothing to take here -- the tax is the pool's native LP fee,
        // accruing into the locked position, harvested by harvestRwaFees(). Just
        // enforce the per-tx anti-sniper max-buy. The graveyard clock was reset above.
        if (state.mode == uint8(LaunchMode.RWA)) {
            _enforcePerTxBuyLimit(key, params, delta);
            return (IHooks.afterSwap.selector, int128(0));
        }

        // Identify the unspecified currency and the magnitude swapped through
        // it. Matches the V4 FeeTakingHook pattern: fee taken on the side
        // V4 hook deltas can affect cleanly. For Arcade this means royalty
        // is in token for USDC -> token buys and in USDC for token -> USDC
        // sells. Creators / treasury auto-convert on the token side via the
        // MultiSwap aggregator when needed.
        bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == Currency.unwrap(USDC);

        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (swapAmount < 0) swapAmount = -swapAmount;
        if (swapAmount == 0) {
            _updateFeeObs(poolId, usdcIsCurrency0); // keep the oracle live
            return (IHooks.afterSwap.selector, int128(0));
        }

        // Always-USDC fee guarantee. afterSwap can only take on the UNSPECIFIED
        // side, so it takes iff USDC is the unspecified currency (buy exact-out
        // = spend USDC input; sell exact-in = receive USDC output). When USDC
        // is the specified side, beforeSwap already took the fee. Exactly one
        // path fires per swap, so the fee is never double-charged. Either way we
        // still advance the price oracle so the dynamic fee keeps tracking mcap.
        if (Currency.unwrap(feeCurrency) != Currency.unwrap(USDC)) {
            _updateFeeObs(poolId, usdcIsCurrency0);
            return (IHooks.afterSwap.selector, int128(0));
        }

        uint256 amount = uint256(uint128(swapAmount));

        // The hook captures the WHOLE trading fee (the pool LP fee is 0), split
        // 80/20 creator/treasury. feeBps is mode-driven (PUMP: mcap-decaying;
        // CLANKER: the creator-chosen tier). Hard-clamped for immutable safety.
        uint256 feeBps = _feeBps(state.mode, poolId);
        if (feeBps > MAX_TOTAL_TAKE_BPS) feeBps = MAX_TOTAL_TAKE_BPS;
        uint256 fee = (amount * feeBps) / 10_000;

        // Anti-sniper auction top-up: during the decay window post-grad, BUYS
        // pay an additional skim that goes to the CREATOR. Only USDC -> token
        // swaps count as buys. Sits ALONGSIDE the fee, same unspecified USDC side.
        uint256 snipeSkim = 0;
        if (_isUsdcToTokenSwap(key, params, USDC)) {
            address launchToken =
                Currency.unwrap(key.currency0) == Currency.unwrap(USDC)
                    ? Currency.unwrap(key.currency1)
                    : Currency.unwrap(key.currency0);
            uint256 bps = _currentSnipeBps(launchToken);
            if (bps > 0) snipeSkim = (amount * bps) / 10_000;
        }

        // Combined hard cap: fee + snipe can never exceed MAX_TOTAL_TAKE_BPS of
        // the swap (v4-core bricks the swap at 100%). Clamp the SNIPE down first
        // (the fee is the creator's core revenue), never revert -- a reverting
        // afterSwap would brick every swap on an immutable pool.
        uint256 maxTake = (amount * MAX_TOTAL_TAKE_BPS) / 10_000;
        if (fee > maxTake) fee = maxTake;
        if (fee + snipeSkim > maxTake) snipeSkim = maxTake - fee;
        ArcadeHookLib.payAntiSnipe(
            POOL_MANAGER, feeOwners, pendingTokenWithdrawals, poolId, feeCurrency, snipeSkim, amount
        );

        ArcadeHookLib.distributeFee(
            POOL_MANAGER, feeOwners, pendingTokenWithdrawals, TREASURY, poolId, feeCurrency, fee, state.mode, true
        );
        // Per-swap treasury fee for referral attribution (feeCurrency is USDC
        // here: the early return above bails when it is not). Mirrors
        // distributeFee's split: treasuryCut = fee - creatorCut.
        if (fee > 0) emit SwapTreasuryFee(poolId, fee - (fee * POST_GRAD_CREATOR_BPS) / 10_000);

        // Advance the price oracle AFTER taking the fee, so this swap's own
        // price impact never influences the fee it just paid.
        _updateFeeObs(poolId, usdcIsCurrency0);

        // Return the total taken on the unspecified side so the swapper pays.
        uint256 totalTaken = fee + snipeSkim;
        return (IHooks.afterSwap.selector, int128(int256(totalTaken)));
    }

    /// @dev The trading-fee rate (bps) for a graduated pool, by mode. PUMP uses
    ///      an mcap-decaying dynamic fee driven by the price EMA; CLANKER uses
    ///      the creator-chosen tier stored at launch (slice 3 wires selection;
    ///      for now tier 1 = 1%). Reads ONLY stored oracle state, never the
    ///      current swap's price, so a swap can't move the fee it itself pays.
    function _feeBps(uint8 mode, PoolId poolId) internal view returns (uint256) {
        if (mode != uint8(LaunchMode.PUMP)) {
            // CLANKER: the creator's chosen static tier. Fall back to tier 1 if
            // somehow unset (defensive; createLaunch always sets it for CLANKER).
            uint16 tier = feeOwners[poolId].feeTierBps;
            return tier == 0 ? FEE_TIER_1 : tier;
        }

        FeeObs storage o = feeObs[poolId];
        // Un-seeded (shouldn't happen post-graduation) -> charge the max.
        if (!o.init) return PUMP_FEE_MAX_BPS;

        int256 emaTick = int256(o.emaTickE3) / 1_000;
        int256 growth = emaTick - int256(o.gradMcapTick); // ticks of mcap growth
        if (growth <= 0) return PUMP_FEE_MAX_BPS; // at/below graduation mcap
        if (growth >= PUMP_FEE_FLOOR_TICKS) return PUMP_FEE_MIN_BPS; // matured

        // Linear decay in log-mcap from MAX at graduation to MIN at the floor.
        uint256 drop =
            (uint256(PUMP_FEE_MAX_BPS - PUMP_FEE_MIN_BPS) * uint256(growth)) / uint256(PUMP_FEE_FLOOR_TICKS);
        return uint256(PUMP_FEE_MAX_BPS) - drop;
    }

    /// @dev Map a CLANKER fee-tier selector (1/2/3) to its bps (100/200/300).
    ///      Reverts on any other value so a launch can't be created with an
    ///      out-of-range or zero tier.
    function _resolveFeeTierBps(uint8 tier) internal pure returns (uint16) {
        if (tier == 1) return FEE_TIER_1;
        if (tier == 2) return FEE_TIER_2;
        if (tier == 3) return FEE_TIER_3;
        revert InvalidFeeTier();
    }

    /// @dev The pool's current "mcap tick": the slot0 tick sign-normalised so it
    ///      RISES with market cap regardless of whether USDC is currency0 or
    ///      currency1. slot0.tick is log-price of currency1 per currency0; when
    ///      USDC is currency0 that price FALLS as the token appreciates, so we
    ///      negate it. Reads live pool state (post-swap when called in afterSwap).
    function _mcapTick(PoolId poolId, bool usdcIsCurrency0) internal view returns (int24) {
        (, int24 tick,,) = POOL_MANAGER.getSlot0(poolId);
        return usdcIsCurrency0 ? -tick : tick;
    }

    /// @dev Advance the price EMA toward the current mcap tick. Manipulation
    ///      resistance: (1) at most one update per block timestamp (dt==0 skips),
    ///      so an intra-block spike + revert never moves the oracle; (2) the
    ///      per-update weight is capped at 50% (dt clamped to TAU) so even a long
    ///      quiet gap can't snap the EMA to a single manipulated print; (3) the
    ///      FEE always reads the PRE-update EMA (callers update AFTER taking the
    ///      fee), so a swap never influences the fee it itself pays.
    function _updateFeeObs(PoolId poolId, bool usdcIsCurrency0) internal {
        FeeObs storage o = feeObs[poolId];
        if (!o.init) return; // only graduated pools carry an oracle
        uint32 nowTs = uint32(block.timestamp);
        uint256 dt = nowTs > o.lastTs ? uint256(nowTs - o.lastTs) : 0;
        if (dt == 0) return; // one update per timestamp

        int256 spotE3 = int256(_mcapTick(poolId, usdcIsCurrency0)) * 1_000;
        int256 ema = int256(o.emaTickE3);
        uint256 wdt = dt > EMA_TAU_SECONDS ? EMA_TAU_SECONDS : dt; // cap weight at 50%
        // ema += (spot - ema) * wdt / (wdt + TAU)
        ema += ((spotE3 - ema) * int256(wdt)) / int256(wdt + EMA_TAU_SECONDS);
        o.emaTickE3 = int64(ema);
        o.lastTs = nowTs;
    }

    /// @dev Revert a CLANKER buy whose token output tops the first-window
    ///      anti-snipe cap (clankerMaxBuyBps of TOTAL_SUPPLY within
    ///      clankerCapWindowSecs of launch). The single-sided CLANKER pool
    ///      can't carry a take-based tax, so this revert is its only block-0
    ///      snipe defense. Sells and post-window buys pass through.
    /// @dev Per-TX anti-sniper max-buy in tokens: ramps 1% (minute 1) -> 5%
    ///      (minute 5) of TOTAL_SUPPLY over the first 5 minutes, then uncapped.
    ///      PER-TRANSACTION (not cumulative): each buy is judged alone, so a normal
    ///      buyer never hits a shared-race revert and the frontend can clamp the
    ///      input exactly. Batch-bypassable by design (a UX guardrail against a
    ///      single-tx whale grab, not a hard anti-snipe -- the accepted trade-off).
    function _perTxMaxBuyTokens(uint64 launchedAt) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - uint256(launchedAt);
        if (elapsed >= 300) return type(uint256).max; // 5 min elapsed -> uncapped
        uint256 step = elapsed / 60; // 0..4
        uint256 capBps = 100 + step * 100; // 100..500 (1%..5%)
        return (ArcadeV4Curve.TOTAL_SUPPLY * capBps) / 10_000;
    }

    /// @dev Enforce the per-tx ramp on a graduated single-sided BUY (CLANKER + RWA).
    ///      The creator's atomic dev-buy is exempt (bounded 10% in the kind-4
    ///      handler; afterSwap is not re-entered on the hook's own swap, but the
    ///      flag guard stays as defense-in-depth). Resolves the launch token as the
    ///      registered side and the quote as the other (USDC for CLANKER, the RWA
    ///      quote otherwise), so one path serves both direct modes.
    function _enforcePerTxBuyLimit(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        view
    {
        if (_creatorBuying) return;
        if (clankerMaxBuyBps == 0) return; // owner-disabled globally (Safe-controlled)
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        address token = registeredLaunches[c0] ? c0 : c1;
        address quoteAddr = quoteAssetOf[token];
        if (quoteAddr == address(0)) quoteAddr = Currency.unwrap(USDC);
        if (!_isUsdcToTokenSwap(key, params, Currency.wrap(quoteAddr))) return; // buys only (quote -> token)
        bool quoteIs0 = c0 == quoteAddr;
        int128 tokenDelta = quoteIs0 ? delta.amount1() : delta.amount0();
        uint256 tokensOut = tokenDelta < 0 ? uint256(uint128(-tokenDelta)) : uint256(uint128(tokenDelta));
        if (tokensOut > _perTxMaxBuyTokens(clankerPos[token].launchedAt)) revert BuyExceedsCap();
    }

    /// @dev True iff the swap routes USDC -> launch token (a buy).
    function _isUsdcToTokenSwap(PoolKey calldata key, SwapParams calldata params, Currency usdcCurrency)
        internal
        pure
        returns (bool)
    {
        address usdcAddr = Currency.unwrap(usdcCurrency);
        bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == usdcAddr;
        // zeroForOne == true means swap currency0 for currency1.
        return (usdcIsCurrency0 && params.zeroForOne) || (!usdcIsCurrency0 && !params.zeroForOne);
    }

    /// @dev Internal copy of currentSnipeBps that avoids an external self-call.
    ///      Anti-sniper is now a CURVE-phase tax: it decays from `launchedAt`
    ///      (createLaunch time) and is FULLY INERT once the token graduates. The
    ///      graduated guard makes the unchanged before/afterSwap snipe blocks a
    ///      guaranteed post-grad no-op and closes the fast-graduation edge (a
    ///      curve that fills inside the decay window would otherwise still skim
    ///      the first post-grad buys).
    function _currentSnipeBps(address token) internal view returns (uint256) {
        SnipeConfig memory cfg = snipeConfigs[token];
        if (cfg.startBps == 0 || cfg.decaySeconds == 0 || cfg.launchedAt == 0) return 0;
        if (curveStates[poolIdOf[token]].status == uint8(Status.Graduated)) return 0;
        uint256 elapsed = block.timestamp - cfg.launchedAt;
        if (elapsed >= cfg.decaySeconds) return 0;
        return (uint256(cfg.startBps) * (cfg.decaySeconds - elapsed)) / cfg.decaySeconds;
    }

    // -------------------------------------------------------------------
    // Unused IHooks slots - revert. The mined address has zero bits at
    // positions 8, 5, 4, 0 so PoolManager never dispatches here.
    // -------------------------------------------------------------------

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // -------------------------------------------------------------------
    // Views for indexers + the frontend
    // -------------------------------------------------------------------

    function tokensCount() external view returns (uint256) {
        return allTokens.length;
    }

    function getCurveState(PoolId poolId) external view returns (CurveState memory) {
        return curveStates[poolId];
    }

    function getFeeOwner(PoolId poolId) external view returns (FeeOwner memory) {
        return feeOwners[poolId];
    }

    // -------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------

    // -------------------------------------------------------------------
    // Graduation
    // -------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @dev Thin entrypoint. The full LP-add / graduation-seed / CLANKER-harvest
    ///      body lives in ArcadeHookLib (delegatecalled, so address(this) stays
    ///      the hook and PoolManager sees the hook as the unlocker). Storage
    ///      mappings are passed by reference; behaviour is byte-identical to the
    ///      former inline implementation.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        // kind 5 = RWA fee harvest (its own routing: collect + convert + 3-way split
        // + accrue). Peek the kind cheaply and dispatch to ArcadeRwaLib.
        if (uint8(uint256(bytes32(data[0:32]))) == 5) {
            (, address rwaToken,,,) = abi.decode(data, (uint8, address, uint256, uint256, int24));
            ArcadeRwaLib.harvestRwaUnlock(
                POOL_MANAGER,
                ArcadeRwaLib.HarvestCtx({
                    token: rwaToken,
                    quoteAddr: quoteAssetOf[rwaToken],
                    poolFee: poolFeeOf[rwaToken],
                    treasury: TREASURY,
                    distributor: dividendDistributor,
                    // The token-side partial-fill residual routes to the immutable,
                    // dividend-excluded sink -- never the rotatable treasury (RWA
                    // system audit MEDIUM-1). One-way setRwaGraveyardSink guarantees
                    // this equals every launch's registration-time excluded sink.
                    sink: rwaGraveyardSink
                }),
                rwaConfigs,
                feeOwners,
                clankerPos,
                pendingTokenWithdrawals
            );
            return "";
        }
        return ArcadeHookLib.unlockCallback(
            POOL_MANAGER,
            USDC,
            TREASURY,
            data,
            clankerPos,
            curveStates,
            feeOwners,
            poolFeeOf,
            pendingTokenWithdrawals,
            quoteAssetOf
        );
    }

    /// @dev Canonical PoolKey for a launch. Sorts the currencies by address
    ///      so currency0 < currency1 (v4 invariant), then sets the hook to
    ///      this contract.
    ///      POOL FEE = 0: the pool itself charges NOTHING. The hook captures
    ///      the entire trading fee in before/afterSwap (always in USDC, split
    ///      80/20 creator/treasury). A nonzero pool LP fee would accrue into
    ///      the hook's locked position with no collect surface (dead value);
    ///      taking it in the hook pays the creator per-swap instead. tickSpacing
    ///      200 unchanged.
    function _buildPoolKey(address launchToken) internal view returns (PoolKey memory key) {
        // Quote side: USDC for PUMP/CLANKER; the launch's snapshotted quote asset
        // for an RWA launch (quoteAssetOf nonzero). Backward-compatible: a zero
        // quoteAssetOf resolves to USDC, so PUMP/CLANKER pool keys are unchanged.
        address quote = quoteAssetOf[launchToken];
        if (quote == address(0)) quote = Currency.unwrap(USDC);
        (Currency c0, Currency c1) = quote < launchToken
            ? (Currency.wrap(quote), Currency.wrap(launchToken))
            : (Currency.wrap(launchToken), Currency.wrap(quote));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: poolFeeOf[launchToken], // 0 for PUMP (hook captures); CLANKER tier / RWA tax as native LP fee
            tickSpacing: 200,
            hooks: IHooks(address(this))
        });
    }

    /// @dev CLANKER fee tier (bps) -> V4 static LP fee units (1e6 = 100%).
    ///      100bps(1%)->10000, 200->20000, 300->30000.
    function _tierToV4Fee(uint16 tierBps) internal pure returns (uint24) {
        return uint24(tierBps) * 100;
    }

    /// @dev PUMP curve fee split = 50/50 platform/creator. Only PUMP reaches
    ///      here: CLANKER launches are Graduated (buy/sell revert
    ///      LiquidityNotPermitted) and CLANKER_V3 is rejected at createLaunch,
    ///      so `mode` is always PUMP and the split is unconditional. Transfers
    ///      happen synchronously in USDC out of the hook's own balance, NOT via
    ///      pm.take, because curve fees are bookkept in the hook's accumulating
    ///      realUsdcReserve balance. Each payout goes through `_safePayUsdc` so
    ///      a USDC-blocked recipient credits a pending balance instead of
    ///      reverting the whole curve trade.
    function _distributeCurveFee(uint8 mode, uint256 fee, address creator, address creator2, uint16 creator2Bps)
        internal
    {
        if (fee == 0) return;
        // Silence unused-param warnings; the args are kept for call-site
        // symmetry with the post-grad path but PUMP has no creator2 curve cut.
        mode;
        creator2;
        creator2Bps;

        uint256 platformCut = fee / 2; // 50/50
        uint256 creatorCut = fee - platformCut;

        if (platformCut > 0) ArcadeHookLib.safePayUsdc(USDC, pendingTokenWithdrawals, TREASURY, platformCut);
        if (creatorCut > 0) ArcadeHookLib.safePayUsdc(USDC, pendingTokenWithdrawals, creator, creatorCut);
    }

}
