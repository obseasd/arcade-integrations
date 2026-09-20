// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal view into ArcadeHook.createLaunch. Returning the PoolId as
///      bytes32 avoids pulling v4-core into this contract (PoolId is a
///      bytes32-wrapping value type, ABI-identical to bytes32).
interface IArcadeHookLaunch {
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
    ) external returns (address tokenAddr, bytes32 poolId);
}

/**
 * @title CreatorSplitter
 * @notice One per launch. It is the entity that CALLS `ArcadeHook.createLaunch`,
 *         so the hook records `creator == this splitter` and every creator fee
 *         (curve, post-grad, anti-sniper skim, CLANKER token-side harvest) lands
 *         here. `distribute()` then fans the accrued balance out to a
 *         configurable, owner-editable recipient set, and ownership is
 *         transferable -- so the creator-fee stream becomes a tradeable position
 *         WITHOUT touching the immutable hook (the "Voie A" splitter model).
 *
 *         Blocklist-safe: a recipient that reverts on receipt credits a `pending`
 *         balance it can pull later, so one bad recipient can never DOS the rest.
 *         This contract never enters the hook's swap path, so a bug here can only
 *         misroute this launch's already-earned fees -- never brick a swap.
 */
contract CreatorSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable FACTORY;
    IArcadeHookLaunch public immutable HOOK;
    IERC20 public immutable USDC;

    // Two-step ownership: transferring it hands over the whole fee stream.
    address public owner;
    address public pendingOwner;

    address[] public recipients;
    uint16[] public weightsBps; // sums to 10_000

    /// token => account => amount owed after a failed push (pull fallback).
    mapping(address => mapping(address => uint256)) public pending;
    /// token => total currently owed via `pending`. Excluded from the
    /// distributable balance so a repeat `distribute()` can't re-hand-out funds
    /// already earmarked to a blocked recipient (HIGH fix, audit 2026-07-18).
    mapping(address => uint256) public totalPending;

    bool public launched;
    address public launchToken;
    bytes32 public poolId;

    error NotFactory();
    error NotOwner();
    error AlreadyLaunched();
    error BadWeights();
    error EmptyRecipients();
    error ZeroAddress();
    error LengthMismatch();

    event Launched(address indexed token, bytes32 indexed poolId);
    event RecipientsSet(address[] recipients, uint16[] weightsBps);
    event Distributed(address indexed token, uint256 total);
    event PendingCredited(address indexed token, address indexed account, uint256 amount);
    event PendingClaimed(address indexed token, address indexed account, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    constructor(
        address factory,
        address hook,
        address usdc,
        address owner_,
        address[] memory recips,
        uint16[] memory weights
    ) {
        if (factory == address(0) || hook == address(0) || usdc == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        FACTORY = factory;
        HOOK = IArcadeHookLaunch(hook);
        USDC = IERC20(usdc);
        owner = owner_;
        _setRecipients(recips, weights);
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Called ONCE by the factory. Because THIS contract is the
    ///         `msg.sender` of `createLaunch`, the hook sets `creator == this`.
    ///         No twitterHandle (escrow attribution and the splitter both claim
    ///         the creator cut -- mutually exclusive); no creator2 (the splitter
    ///         does all splitting). The factory funds this contract with the
    ///         creation fee before calling.
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint8 mode,
        uint16 snipeStartBps,
        uint32 snipeDecaySeconds,
        uint8 feeTier,
        uint256 startMcapUsdc
    ) external returns (address token, bytes32 pid) {
        if (msg.sender != FACTORY) revert NotFactory();
        if (launched) revert AlreadyLaunched();
        launched = true;
        // Approve exactly our balance (the factory funded the creation fee).
        USDC.forceApprove(address(HOOK), USDC.balanceOf(address(this)));
        // creatorBuyUsdc = 0: the splitter launches on behalf of a creator and
        // holds only the creation fee, so there is no atomic dev-buy here.
        (token, pid) = HOOK.createLaunch(
            name,
            symbol,
            metadataURI,
            mode,
            address(0),
            0,
            snipeStartBps,
            snipeDecaySeconds,
            feeTier,
            "",
            startMcapUsdc,
            0,
            // Follow the protocol default. A splitter launch has no UI to choose
            // a pair with, so it inherits whatever new launches pair against.
            0
        );
        launchToken = token;
        poolId = pid;
        emit Launched(token, pid);
    }

    /// @notice Permissionless: split this contract's whole `token` balance to the
    ///         recipients per weight. Works for USDC (curve + post-grad fees) and
    ///         the launch token (CLANKER token-side harvest). Rounding dust goes
    ///         to the last recipient; a reverting recipient credits `pending`.
    function distribute(address token) external nonReentrant {
        // Exclude balances already earmarked to pending pull-payments, so a
        // repeat call with no fresh fees is a no-op (never re-distributes a
        // blocked recipient's owed funds).
        uint256 bal = IERC20(token).balanceOf(address(this)) - totalPending[token];
        if (bal == 0) return;
        uint256 n = recipients.length;
        uint256 distributed;
        for (uint256 i; i < n; ++i) {
            uint256 share = (i + 1 == n) ? bal - distributed : (bal * weightsBps[i]) / 10_000;
            distributed += share;
            if (share > 0) _pay(token, recipients[i], share);
        }
        emit Distributed(token, bal);
    }

    function _pay(address token, address to, uint256 amount) internal {
        // Best-effort push; on failure (blocklist, reverting receiver) credit a
        // pull balance instead of reverting the whole distribution.
        try IERC20(token).transfer(to, amount) returns (bool ok) {
            if (ok) return;
        } catch {}
        pending[token][to] += amount;
        totalPending[token] += amount;
        emit PendingCredited(token, to, amount);
    }

    function claimPending(address token) external nonReentrant returns (uint256 amount) {
        amount = pending[token][msg.sender];
        if (amount == 0) return 0;
        pending[token][msg.sender] = 0;
        totalPending[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit PendingClaimed(token, msg.sender, amount);
    }

    // --- Owner: recipient config + 2-step ownership -----------------------

    function setRecipients(address[] calldata recips, uint16[] calldata weights) external onlyOwner {
        _setRecipients(recips, weights);
    }

    function _setRecipients(address[] memory recips, uint16[] memory weights) internal {
        uint256 n = recips.length;
        if (n == 0) revert EmptyRecipients();
        if (n != weights.length) revert LengthMismatch();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (recips[i] == address(0)) revert ZeroAddress();
            sum += weights[i];
        }
        if (sum != 10_000) revert BadWeights();
        recipients = recips;
        weightsBps = weights;
        emit RecipientsSet(recips, weights);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner; // zero allowed = cancel a pending transfer
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }
}

/**
 * @title SplitterLaunchFactory
 * @notice Launches a token whose creator fees route to a fresh CreatorSplitter
 *         (owned by the launcher, with a configurable recipient split). The
 *         splitter -- not the human -- is the `createLaunch` caller, so the hook
 *         records it as `creator`. No change to the immutable hook.
 */
contract SplitterLaunchFactory {
    using SafeERC20 for IERC20;

    IArcadeHookLaunch public immutable HOOK;
    IERC20 public immutable USDC;

    /// @dev Must match ArcadeHook.CREATION_FEE (internal constant 3e6). If the
    ///      hook's fee ever changes, redeploy this factory (cheap, hook untouched).
    uint256 public constant CREATION_FEE = 3e6;

    event SplitterLaunched(bytes32 indexed poolId, address indexed token, address indexed splitter, address owner);

    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        uint8 mode; // 0 = PUMP, 1 = CLANKER
        uint16 snipeStartBps;
        uint32 snipeDecaySeconds;
        uint8 feeTier; // CLANKER only
        uint256 startMcapUsdc; // CLANKER only
    }

    constructor(address hook, address usdc) {
        HOOK = IArcadeHookLaunch(hook);
        USDC = IERC20(usdc);
    }

    /// @notice Deploy a per-launch splitter (owner = caller), fund it with the
    ///         creation fee, and have IT call `createLaunch` so the hook's
    ///         `creator` is the splitter. Caller must approve this factory for
    ///         `CREATION_FEE` USDC first.
    function launch(LaunchParams calldata p, address[] calldata recipients, uint16[] calldata weightsBps)
        external
        returns (address splitter, address token, bytes32 poolId)
    {
        CreatorSplitter s =
            new CreatorSplitter(address(this), address(HOOK), address(USDC), msg.sender, recipients, weightsBps);
        splitter = address(s);
        // Fund the splitter with the creation fee (pulled from the launcher).
        USDC.safeTransferFrom(msg.sender, splitter, CREATION_FEE);
        (token, poolId) =
            s.launch(p.name, p.symbol, p.metadataURI, p.mode, p.snipeStartBps, p.snipeDecaySeconds, p.feeTier, p.startMcapUsdc);
        emit SplitterLaunched(poolId, token, splitter, msg.sender);
    }
}
