// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IArcadeDividendDistributor} from "./interfaces/IArcadeDividendDistributor.sol";

/// @dev The RWA launch token exposes the address it minted its full supply to at
///      deploy (the launchpad = the hook). registerLaunch excludes it so its
///      pre-registration balance never corrupts S (audit HIGH-A).
interface ILaunchpadMinted {
    function launchpad() external view returns (address);
}

/**
 * @title ArcadeDividendDistributor
 * @notice No-keeper, O(1)-per-holder volume-funded dividend distributor for the
 *         RWA launch mode. Cumulative-per-share accumulator ("dividend-paying
 *         token" pattern): `accPerShare` rises as the hook accrues the
 *         holders-bucket of the trade tax, ALWAYS in the launch's QUOTE asset
 *         (never the launch token). A holder's claimable is the distance the
 *         accumulator moved since they were last settled, times their balance.
 *         Settlement is driven by the launch token's `_update` transfer hook;
 *         payout auto-pushes to the moving holders in their own buy/sell
 *         (try/catch, fallback to claimable) and is otherwise pulled via
 *         claim()/claimFor().
 *
 *         SEPARATE contract on purpose: own reentrancy domain (the token->settle
 *         callback never re-enters the hook's guard during
 *         createLaunch/seed/dev-buy/graveyard, audit RWA H1) and own storage (can
 *         never corrupt the delegatecalled hook layout).
 *
 *  Audit fixes baked in (skeleton v2, post distributor audit):
 *    A1  SCALE=1e36 + FullMath.mulDiv (no truncation-to-zero, no overflow).
 *    A2/M2  S maintained across the excluded<->included boundary; _isIncluded is
 *           the single authority (treasury/hook/self resolved DYNAMICALLY so a
 *           treasury rotation never pollutes S -- fixes MEDIUM-5).
 *    A3  CEI + nonReentrant on the external pulls.
 *    A4  settle both parties on PRE-move balances.
 *    A6/H2  S<MIN_SHARE_BASE routes accrual to treasury.
 *    M6  self-transfer / zero-amount short-circuit.
 *    B3  dev bootstrap exclusion + LAZY fold on the PRE-move balance (fixes the
 *        CRITICAL double-count of the in-flight amount).
 *    Containment: per-launch `reserve[token]` + per-asset `totalReserve[quote]`
 *        ledgers bound every payout so one launch can never drain another's quote
 *        (fixes HIGH-2 commingling) and give sweepDust an exact dust figure (A7).
 *    Settlement is fully reconciled BEFORE any external push (fixes MEDIUM-7).
 *    Global exclusion is ONE-WAY; safe per-token re-inclusion via includeHolder
 *        (fixes HIGH-3 full-history over-claim on re-inclusion).
 *
 *  NOTE (skeleton): Phase 1 pays the single quote asset. Multi-asset (max 2,
 *        Phase 2, convert-at-claim) is a TODO.
 */
contract ArcadeDividendDistributor is IArcadeDividendDistributor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Accumulator fixed-point scale. 1e36 so a small-decimal payout over
    ///         an ~1e27 (1e9 * 1e18) share base never truncates to zero and
    ///         `balance * deltaAcc` stays far below 2^256 (audit A1/H2).
    uint256 internal constant SCALE = 1e36;

    /// @notice Below this share base the per-share math is unstable, so accrual is
    ///         routed to the treasury (audit A6/H2). 18-dp launch-token units; our
    ///         launch tokens are always 18-dp so this is decimals-safe.
    uint256 internal constant MIN_SHARE_BASE = 1e18; // 1 whole launch token

    /// @notice Dev-buy excluded from S for this window after launch so the founder
    ///         does not capture ~100% of early dividends while S ~ 0 (audit B3).
    uint256 internal constant DEV_BOOTSTRAP = 10 minutes;

    // ------------------------------------------------------------------
    // Ownership (manual; owner = Safe)
    // ------------------------------------------------------------------

    address public owner;
    address public immutable hook; // sole caller of registerLaunch + accrue
    address public treasury; // dust + no-holder accrual sink; excluded from S

    // ------------------------------------------------------------------
    // Per-launch state
    // ------------------------------------------------------------------

    struct DivConfig {
        address launchToken; // == the mapping key; nonzero once registered
        address quoteAsset; // immutable payout asset (Phase 1 = the pool quote)
        address creator; // dev, for the bootstrap exclusion
        uint40 launchedAt;
        uint96 minAutoPush; // auto-push threshold in quote units (from decimals)
        bool devReentered; // has the dev been folded into S post-bootstrap
    }

    mapping(address => DivConfig) public config;
    /// token => cumulative dividends per share, scaled by SCALE, in quote units.
    mapping(address => uint256) public accPerShare;
    /// token => S: sum of balances of INCLUDED holders (18-dp token units).
    mapping(address => uint256) public totalShares;
    /// token => holder => accPerShare checkpoint at last settle.
    mapping(address => mapping(address => uint256)) public acc_h;
    /// token => holder => settled-but-not-yet-withdrawn dividends (quote units).
    mapping(address => mapping(address => uint256)) public withdrawable;
    /// token => quote owed to this launch's holders (deposited minus paid).
    mapping(address => uint256) public reserve;
    /// quoteAsset => sum of `reserve` across every launch using it (for sweepDust).
    mapping(address => uint256) public totalReserve;
    /// token => addr => excluded from S for THIS token (dev during bootstrap,
    ///         pool custody address(es) passed at registration).
    mapping(address => mapping(address => bool)) public excluded;
    /// addr => excluded from S for ALL tokens (owner-curated routers / known DEX
    ///         pools; audit H4). ONE-WAY: can be set, never cleared.
    mapping(address => bool) public globalExcluded;

    // ------------------------------------------------------------------
    // Errors / events
    // ------------------------------------------------------------------

    error NotOwner();
    error NotHook();
    error AlreadyRegistered();
    error NotRegistered();
    error ZeroAddress();
    error NothingToClaim();
    error CannotReinclude(); // global exclusion is one-way
    error BadQuoteDecimals(); // quote asset decimals outside a sane range

    event OwnershipTransferred(address indexed from, address indexed to);
    event TreasurySet(address indexed treasury);
    event GlobalExcluded(address indexed addr);
    event HolderExcluded(address indexed token, address indexed addr, uint256 shareRemoved);
    event HolderIncluded(address indexed token, address indexed addr, uint256 shareAdded);
    event LaunchRegistered(address indexed token, address indexed quoteAsset, address indexed creator);
    event Accrued(address indexed token, uint256 amount, uint256 shareBase);
    event AccrualToTreasury(address indexed token, uint256 amount);
    event DividendPushed(address indexed token, address indexed holder, uint256 amount);
    event DividendClaimed(address indexed token, address indexed holder, uint256 amount);
    event DevFolded(address indexed token, address indexed creator, uint256 balance);
    event DustSwept(address indexed quoteAsset, uint256 amount);
    event ShareBaseUnderflow(address indexed token, uint256 have, uint256 want); // observability

    // ------------------------------------------------------------------
    // Constructor / admin
    // ------------------------------------------------------------------

    constructor(address owner_, address hook_, address treasury_) {
        if (owner_ == address(0) || hook_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        owner = owner_;
        hook = hook_;
        treasury = treasury_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    /// @notice Rotate the treasury. The OLD address is globally excluded (one-way,
    ///         O(1)) BEFORE the switch. Its balance was never in S and its acc_h
    ///         checkpoint is 0, so left included it would claimFor the ENTIRE
    ///         accrual history of every launch on whatever balance anyone parked
    ///         there, out of a reserve that never provisioned for it, short-paying
    ///         the real holders (audit 2026-09-18 MEDIUM-1). Excluding it keeps S
    ///         and the reserve exact with no per-launch fixup; the new treasury is
    ///         excluded dynamically by _isIncluded, as before.
    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        address old = treasury;
        if (old != t && !globalExcluded[old]) {
            globalExcluded[old] = true;
            emit GlobalExcluded(old);
        }
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice Exclude an address from S for EVERY token. Seed with known router /
    ///         canonical-DEX addresses so rogue secondary pools cannot siphon
    ///         dividends (audit H4). ONE-WAY: once excluded an address can never be
    ///         globally re-included (re-inclusion cannot be made O(1)-safe across
    ///         all tokens without re-checkpointing every acc_h). For a per-token
    ///         correction use includeHolder.
    function setGlobalExcluded(address addr) external onlyOwner {
        globalExcluded[addr] = true;
        emit GlobalExcluded(addr);
    }

    /// @notice Per-token exclusion WITH S correction, for a rogue pool discovered
    ///         after launch (audit H4). Settles the address first (its accrued
    ///         dividends stay claimable) then removes its balance from S.
    function excludeHolder(address token, address addr) external onlyOwner {
        if (config[token].launchToken == address(0)) revert NotRegistered();
        if (!_isIncluded(token, addr)) return; // already out of S (fixes MEDIUM-4)
        uint256 bal = IERC20(token).balanceOf(addr);
        _settle(token, addr, bal); // bank what it earned so far
        excluded[token][addr] = true;
        uint256 removed;
        if (bal > 0) {
            uint256 s = totalShares[token];
            removed = bal <= s ? bal : s;
            totalShares[token] = s - removed;
        }
        emit HolderExcluded(token, addr, removed);
    }

    /// @notice Per-token re-inclusion WITH the correct S + checkpoint fixup, so a
    ///         re-included address earns from NOW (never the full history) (fixes
    ///         HIGH-3). Cannot re-include a globally-excluded address (one-way).
    function includeHolder(address token, address addr) external onlyOwner {
        if (config[token].launchToken == address(0)) revert NotRegistered();
        if (globalExcluded[addr]) revert CannotReinclude();
        if (!excluded[token][addr]) return; // already included
        excluded[token][addr] = false;
        acc_h[token][addr] = accPerShare[token]; // no back-pay
        uint256 bal = IERC20(token).balanceOf(addr);
        if (bal > 0) totalShares[token] += bal;
        emit HolderIncluded(token, addr, bal);
    }

    /// @notice Sweep the un-owed dust of `quoteAsset` (truncation remainders) to
    ///         the treasury (audit A7). Dust = held balance minus every launch's
    ///         outstanding reserve in that asset.
    function sweepDust(address quoteAsset) external onlyOwner {
        uint256 bal = IERC20(quoteAsset).balanceOf(address(this));
        uint256 owed = totalReserve[quoteAsset];
        if (bal > owed) {
            uint256 dust = bal - owed;
            IERC20(quoteAsset).safeTransfer(treasury, dust);
            emit DustSwept(quoteAsset, dust);
        }
    }

    // ------------------------------------------------------------------
    // Hook-driven: registration + accrual
    // ------------------------------------------------------------------

    /// @inheritdoc IArcadeDividendDistributor
    function registerLaunch(
        address token,
        address quoteAsset,
        address creator,
        uint256 devBuyAmount,
        address[] calldata excludedAddrs
    ) external onlyHook {
        if (token == address(0) || quoteAsset == address(0)) revert ZeroAddress();
        if (config[token].launchToken != address(0)) revert AlreadyRegistered();

        uint8 dec = IERC20Metadata(quoteAsset).decimals();
        if (dec < 2 || dec > 27) revert BadQuoteDecimals(); // audit LOW-2
        uint256 unit = 10 ** dec;
        config[token] = DivConfig({
            launchToken: token,
            quoteAsset: quoteAsset,
            creator: creator,
            launchedAt: uint40(block.timestamp),
            minAutoPush: uint96(unit / 100), // 0.01 quote units, decimals-correct
            devReentered: devBuyAmount == 0 // nothing to fold if no dev-buy
        });

        // Exclude the mint recipient (the launchpad that holds the full supply at
        // deploy) so its pre-registration balance never corrupts S (audit HIGH-A).
        // It is the hook in practice (already dynamically excluded), but pin it
        // explicitly so a mis-wire cannot break the S invariant.
        excluded[token][ILaunchpadMinted(token).launchpad()] = true;

        // Exclude the pool custody address(es) passed by the hook, and the dev
        // (bootstrap). hook / treasury / self are excluded DYNAMICALLY in
        // _isIncluded, so no snapshot here (fixes MEDIUM-5).
        if (creator != address(0) && devBuyAmount > 0) excluded[token][creator] = true;
        for (uint256 i; i < excludedAddrs.length; ++i) {
            if (excludedAddrs[i] != address(0)) excluded[token][excludedAddrs[i]] = true;
        }
        // S starts at 0: the whole supply is minted to the hook (excluded) and
        // seeded into pool custody (excluded). Buys move custody -> holder,
        // growing S via onTokenTransfer.
        emit LaunchRegistered(token, quoteAsset, creator);
    }

    /// @inheritdoc IArcadeDividendDistributor
    /// @dev The hook MUST have already transferred `amount` of quoteAsset to this
    ///      contract (PoolManager.take -> address(this)) before calling.
    function accrue(address token, uint256 amount) external onlyHook {
        if (amount == 0) return;
        address quote = config[token].quoteAsset;
        uint256 s = totalShares[token];
        if (s < MIN_SHARE_BASE) {
            // No meaningful holder base yet: forward to treasury rather than let
            // the per-share math explode (audit A6/H2). Not tracked in reserve.
            // PULL-SAFE (audit MED-1): accrue runs INSIDE a swap; a permissioned
            // quote (e.g. USYC) that reverts on transfer to the treasury must NOT
            // brick that swap on an immutable pool. On failure the amount simply
            // stays as un-owed balance, reclaimable later via sweepDust(quote).
            try IERC20(quote).transfer(treasury, amount) returns (bool ok) {
                if (ok) emit AccrualToTreasury(token, amount);
            } catch {}
            return;
        }
        accPerShare[token] += FullMath.mulDiv(amount, SCALE, s); // 512-bit safe (A1)
        reserve[token] += amount;
        totalReserve[quote] += amount;
        emit Accrued(token, amount, s);
    }

    // ------------------------------------------------------------------
    // Token-driven: transfer settlement + auto-push
    // ------------------------------------------------------------------

    /// @inheritdoc IArcadeDividendDistributor
    function onTokenTransfer(
        address from,
        address to,
        uint256 amount,
        uint256 fromBalBefore,
        uint256 toBalBefore
    ) external {
        // msg.sender must be the registered launch token itself (audit M1). The
        // constructor mint fires before registration and no-ops here.
        if (config[msg.sender].launchToken != msg.sender) return;
        address token = msg.sender;

        // Lazily fold the dev into S once the bootstrap window has passed, using
        // the PRE-move balance so the subsequent +/-amount reconciles exactly
        // (fixes CRITICAL-1). Runs before settle so the dev earns nothing
        // retroactively (audit B3).
        _maybeFoldDev(token, from, fromBalBefore);
        _maybeFoldDev(token, to, toBalBefore);

        if (from == to || amount == 0) return; // audit M6

        // 1) Pure accounting: settle both parties on PRE-move balances (audit A4).
        if (from != address(0)) _settle(token, from, fromBalBefore);
        if (to != address(0)) _settle(token, to, toBalBefore);

        // 2) Reconcile S across the excluded<->included boundary (audit A2/M2).
        if (from != address(0) && _isIncluded(token, from)) {
            uint256 s = totalShares[token];
            if (s >= amount) {
                totalShares[token] = s - amount;
            } else {
                totalShares[token] = 0;
                emit ShareBaseUnderflow(token, s, amount); // observable, non-bricking
            }
        }
        if (to != address(0) && _isIncluded(token, to)) {
            totalShares[token] += amount;
        }

        // 3) External pushes LAST, once state is fully reconciled (fixes MEDIUM-7).
        if (from != address(0)) _maybePush(token, from);
        if (to != address(0)) _maybePush(token, to);
    }

    // ------------------------------------------------------------------
    // Claims (pull, guarded)
    // ------------------------------------------------------------------

    /// @inheritdoc IArcadeDividendDistributor
    function claim(address token) external nonReentrant {
        _claim(token, msg.sender);
    }

    /// @inheritdoc IArcadeDividendDistributor
    function claimFor(address token, address holder) external nonReentrant {
        _claim(token, holder);
    }

    /// @inheritdoc IArcadeDividendDistributor
    function claimable(address token, address holder) external view returns (uint256) {
        uint256 owed = withdrawable[token][holder];
        if (_isIncluded(token, holder)) {
            uint256 bal = IERC20(token).balanceOf(holder);
            owed += FullMath.mulDiv(bal, accPerShare[token] - acc_h[token][holder], SCALE);
        }
        return owed;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _isIncluded(address token, address addr) internal view returns (bool) {
        return addr != treasury && addr != hook && addr != address(this) && !excluded[token][addr]
            && !globalExcluded[addr];
    }

    /// @dev Pure accounting: bank `holder`'s owed dividends into withdrawable and
    ///      advance their checkpoint. NO external call. Uses the passed `bal`
    ///      (pre-move at transfer time, current at claim time).
    function _settle(address token, address holder, uint256 bal) internal {
        if (!_isIncluded(token, holder)) return;
        uint256 delta = accPerShare[token] - acc_h[token][holder];
        if (delta != 0) {
            uint256 owed = FullMath.mulDiv(bal, delta, SCALE);
            if (owed != 0) withdrawable[token][holder] += owed;
            acc_h[token][holder] = accPerShare[token]; // always checkpoint
        }
    }

    /// @dev Push a holder's settled balance to them (auto-push). Only the transfer
    ///      is wrapped in try/catch; on failure it stays claimable. Bounded by the
    ///      per-launch reserve so a mis-accrual can never overpay.
    function _maybePush(address token, address holder) internal {
        if (!_isIncluded(token, holder)) return;
        uint256 owed = withdrawable[token][holder];
        if (owed < config[token].minAutoPush) return;
        uint256 r = reserve[token];
        uint256 pay = owed <= r ? owed : r;
        if (pay == 0) return;
        address quote = config[token].quoteAsset;
        // Full CEI: reduce withdrawable AND reserve BEFORE the external transfer,
        // restore all three on failure (audit LOW-1: no stale-cache write-back).
        withdrawable[token][holder] = owed - pay;
        reserve[token] = r - pay;
        totalReserve[quote] -= pay;
        try IERC20(quote).transfer(holder, pay) returns (bool ok) {
            if (ok) {
                emit DividendPushed(token, holder, pay);
            } else {
                withdrawable[token][holder] = owed;
                reserve[token] = r;
                totalReserve[quote] += pay;
            }
        } catch {
            withdrawable[token][holder] = owed;
            reserve[token] = r;
            totalReserve[quote] += pay;
        }
    }

    function _claim(address token, address holder) internal {
        _maybeFoldDev(token, holder, IERC20(token).balanceOf(holder));
        _settle(token, holder, IERC20(token).balanceOf(holder));
        uint256 owed = withdrawable[token][holder];
        if (owed == 0) revert NothingToClaim();
        uint256 r = reserve[token];
        uint256 pay = owed <= r ? owed : r; // reserve bound (containment)
        if (pay == 0) revert NothingToClaim();
        withdrawable[token][holder] = owed - pay; // CEI
        reserve[token] = r - pay;
        address quote = config[token].quoteAsset;
        totalReserve[quote] -= pay;
        IERC20(quote).safeTransfer(holder, pay);
        emit DividendClaimed(token, holder, pay);
    }

    /// @dev Post-bootstrap, fold the dev into S exactly once, crediting NO
    ///      retroactive accrual (acc_h set to the current index). Adds the PASSED
    ///      balance to S (pre-move at transfer time), so the caller's later
    ///      +/-amount reconciles to the true post-move balance. Lazy: triggered by
    ///      the dev's next interaction or any claimFor(dev) after the window.
    function _maybeFoldDev(address token, address who, uint256 balForFold) internal {
        DivConfig storage c = config[token];
        if (c.devReentered || who == address(0) || who != c.creator) return;
        if (block.timestamp < uint256(c.launchedAt) + DEV_BOOTSTRAP) return;
        c.devReentered = true; // one-shot regardless of the outcome below
        // If the creator is also globally excluded (owner misconfig / a router-like
        // creator), keep it OUT of S -- do not un-exclude or add to S, or S would
        // overstate vs _isIncluded (audit L-1). Otherwise fold it in from now.
        if (globalExcluded[c.creator]) return;
        excluded[token][c.creator] = false;
        acc_h[token][c.creator] = accPerShare[token]; // no back-pay
        if (balForFold > 0) totalShares[token] += balForFold;
        emit DevFolded(token, c.creator, balForFold);
    }
}
