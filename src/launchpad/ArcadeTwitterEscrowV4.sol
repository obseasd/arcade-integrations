// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ArcadeTwitterEscrow v4 (hook-native)
 * @notice Holds a launch's post-graduation CREATOR fees attributed to a Twitter
 *         handle until the verified owner claims them. Purpose-built for the
 *         V4 ArcadeHook: a CLANKER creator can point their fee stream at a
 *         handle that has no wallet yet; the fees accrue here per launch and the
 *         handle owner claims them after OAuth verification.
 *
 *         This is a LEAN rewrite of ArcadeTwitterEscrowV3 that keeps V3's
 *         audited security primitives (EIP-712 signed two-step claim, mutable
 *         trusted signer, claim timelock + owner veto, pause, per-slot on-chain
 *         balances, rescue bounded by earmarked funds, forfeit of abandoned
 *         handles, pull-payment failure ledger, recipient==msg.sender phishing
 *         guard) but DROPS the machinery V3 carried for the locker:
 *
 *           1. CREDITER ALLOWLIST instead of a one-shot immutable LOCKER. The
 *              owner (Safe) authorises the hook via `setCrediter`. Any number of
 *              trusted depositors can be added/removed. (fixes: the live V3
 *              escrow's `onlyLOCKER` + one-shot LOCKER blocked the hook forever.)
 *           2. BALANCE-DIFF credit. `creditSlot` credits at most the USDC that
 *              actually ARRIVED (balanceOf - creditedTotal), so a credit whose
 *              paired transfer silently pended cannot inflate the books past the
 *              real balance and let one slot drain another. (V3 trusted the
 *              caller's amount because the locker was trusted; the hook's take
 *              can pend on a blocklisted recipient, so we verify delivery.)
 *           3. REPEATABLE claims. There is no permanent per-slot `claimed` lock:
 *              each claim SWEEPS the current balance and reopens the slot, so
 *              fees that accrue after a claim can be claimed again later. (V3's
 *              one-shot claim + locker rotation assumed the locker redirected
 *              future fees; the hook has no rotation, so the handle owner
 *              re-claims periodically.)
 *           4. SINGLE fee token per credit (no paired/clanker slot pairs). Fees
 *              are always USDC, but the accounting stays token-generic.
 *
 *         The handle <-> (positionId) binding lives OFF-CHAIN: the hook emits
 *         the handle in its launch event and the backend records it; at claim
 *         time the OAuth-verified handle is compared to that record before the
 *         trusted signer issues an EIP-712 authorization. positionId is the
 *         launch's PoolId (unique per launch); slotIndex is 0 for every launch.
 */
contract ArcadeTwitterEscrowV4 is Ownable2Step, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // ====================== Domain / typehash ======================

    bytes32 private immutable _DOMAIN_SEPARATOR_CACHED;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private constant CLAIM_TYPEHASH = keccak256(
        "Claim(uint256 positionId,uint256 slotIndex,address recipient,address token,uint256 amount,uint256 deadline,bytes32 nonce)"
    );

    uint64 public constant MAX_TIMELOCK = 7 days;
    /// @notice Floor for a NON-ZERO claim timelock, so the owner-veto window is
    ///         always meaningful (a tiny value would be useless). 0 stays allowed
    ///         to explicitly disable the veto.
    uint64 public constant MIN_TIMELOCK = 15 minutes;
    /// @notice Constructor default, so a fresh escrow ships with a real veto
    ///         window instead of 0. A 0 default collapses authorize+claim into
    ///         one block, letting a compromised signer drain before the owner can
    ///         veto/pause; the owner can setClaimTimelock(0) later to opt out.
    uint64 public constant DEFAULT_TIMELOCK = 1 hours;
    /// @notice Delay before a rotated trusted signer takes effect.
    uint64 public constant SIGNER_ROTATION_DELAY = 24 hours;
    /// @notice A slot with no `creditSlot` activity for this long can be
    ///         forfeited by the owner (abandoned-handle case).
    uint64 public constant FORFEIT_DELAY = 180 days;

    // ====================== Security primitives ======================

    /// @notice Backend EIP-712 signer (the single Vercel key; a Safe cannot
    ///         produce the off-chain ECDSA sig). Rotated via a 24h two-step
    ///         timelock so a compromised key can be replaced without a redeploy
    ///         but an attacker who steals the OWNER key still can't instantly
    ///         swap in a hostile signer.
    address public trustedSigner;
    address public pendingSigner;
    uint64 public pendingSignerAfter;

    /// @notice Delay between `authorize` and the earliest `claimByTwitter`,
    ///         snapshotted per claim so changes never affect in-flight claims.
    uint64 public claimTimelock;

    /// @notice Depositors authorised to call `creditSlot` (the ArcadeHook).
    mapping(address => bool) public allowedCrediter;

    // ====================== Accounting ======================

    /// @notice On-chain per-(positionId, slot, token) credited balance. Claims
    ///         debit from this; `authorize`/claim can never pay more than was
    ///         credited.
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public balances;
    /// @notice Sum of `balances[*][*][token]`. `rescue` refuses to touch it, so
    ///         the owner can only sweep un-earmarked dust, never user balances.
    mapping(address => uint256) public creditedTotal;
    /// @notice Forfeit clock anchor per slot = the FIRST credit (launch) time,
    ///         reset ONLY on a successful claim. NOT bumped by later credits, so
    ///         an actively-traded-but-never-claimed slot still becomes forfeitable
    ///         FORFEIT_DELAY after launch (a permissionless collectFees can no
    ///         longer grief the clock by re-crediting). "Time since launch with
    ///         no successful claim." (Audit 2026-07-18.)
    mapping(uint256 => mapping(uint256 => uint64)) public forfeitAnchorAt;
    /// @notice The single token a slot has been credited with (fees are USDC).
    ///         Pins forfeit/claim to that token so the owner can't name another.
    mapping(uint256 => mapping(uint256 => address)) public slotToken;

    /// @notice Fixed destination for the PERMISSIONLESS stale-slot forfeit
    ///         (forfeitStaleToTreasury). Owner-set; 0 disables that path (the
    ///         owner-only forfeitStaleClaim still works). Funds can ONLY go here,
    ///         so a permissionless trigger has no redirection vector -- it lets an
    ///         automated keeper settle a stale USDC slot to the treasury without an
    ///         owner tx, mirroring the off-chain token-side sweep so BOTH sides
    ///         land at the treasury once the 180d clock elapses.
    address public forfeitTreasury;

    /// @notice Pull-payment ledger for forfeit payouts whose transfer reverted.
    mapping(address => mapping(address => uint256)) public pendingForfeit;
    /// @notice Sum of `pendingForfeit[token][*]`. These tokens are earmarked for
    ///         a pull-payment recipient (already debited from `creditedTotal`),
    ///         so `rescue` must exclude them too or the owner could sweep funds
    ///         owed to a forfeit recipient before they pull.
    mapping(address => uint256) public pendingForfeitTotal;

    // ====================== Claim state ======================

    mapping(bytes32 => bool) public nonceUsed;
    /// @notice At most one pending authorization per slot at a time.
    mapping(uint256 => mapping(uint256 => bool)) public hasPending;
    mapping(bytes32 => PendingClaim) public pendingClaims;

    struct PendingClaim {
        address recipient;
        address token;
        uint256 amount;
        uint256 positionId;
        uint256 slotIndex;
        uint256 executeAfter;
        uint256 deadline;
        bool consumed;
        bool vetoed;
    }

    // ====================== Events ======================

    event CrediterSet(address indexed crediter, bool allowed);
    event Credited(uint256 indexed positionId, uint256 indexed slotIndex, address indexed token, uint256 amount);
    event Authorized(bytes32 indexed nonce, uint256 indexed positionId, uint256 indexed slotIndex, uint256 executeAfter);
    event Claimed(uint256 indexed positionId, uint256 indexed slotIndex, address indexed recipient, address token, uint256 amount);
    event Vetoed(bytes32 indexed nonce);
    event TimelockChanged(uint64 newTimelock);
    event SignerRotationStarted(address indexed next, uint64 effectiveAt);
    event TrustedSignerUpdated(address indexed previous, address indexed next);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Forfeited(uint256 indexed positionId, uint256 indexed slotIndex, address indexed to, address token, uint256 amount);
    event ForfeitTransferFailed(uint256 indexed positionId, uint256 indexed slotIndex, address indexed token, address to, uint256 amount);
    event ForfeitTreasuryUpdated(address indexed previous, address indexed next);

    // ====================== Errors ======================

    error ZeroAddress();
    error NotCrediter();
    error NothingDelivered();
    error InvalidToken();
    error Expired();
    error DeadlineInPast();
    error RecipientNotSender();
    error NonceReused();
    error SlotPending();
    error InvalidSignature();
    error InsufficientBalance();
    error NothingToClaim();
    error NotAuthorized();
    error AlreadyClaimed();
    error Timelocked();
    error Already();
    error TimelockTooLong();
    error TimelockTooShort();
    error ExceedsFreeBalance();
    error NotStaleYet();
    error RotationNotReady();
    error NothingPending();
    error RenounceDisabled();

    // ====================== Construction ======================

    constructor(address trustedSigner_, address owner_) Ownable(owner_) {
        if (trustedSigner_ == address(0)) revert ZeroAddress();
        trustedSigner = trustedSigner_;
        // Ship with a real veto window instead of a silent 0 (audit MEDIUM).
        claimTimelock = DEFAULT_TIMELOCK;
        _CACHED_CHAIN_ID = block.chainid;
        _DOMAIN_SEPARATOR_CACHED = _buildDomainSeparator();
        emit TrustedSignerUpdated(address(0), trustedSigner_);
        emit TimelockChanged(DEFAULT_TIMELOCK);
    }

    // ====================== Owner admin ======================

    function setCrediter(address crediter, bool allowed) external onlyOwner {
        if (crediter == address(0)) revert ZeroAddress();
        allowedCrediter[crediter] = allowed;
        emit CrediterSet(crediter, allowed);
    }

    /// @notice Set the fixed destination for permissionless stale forfeits. 0
    ///         disables forfeitStaleToTreasury. Should be the treasury Safe.
    function setForfeitTreasury(address newTreasury) external onlyOwner {
        emit ForfeitTreasuryUpdated(forfeitTreasury, newTreasury);
        forfeitTreasury = newTreasury;
    }

    function setClaimTimelock(uint64 newTimelock) external onlyOwner {
        if (newTimelock > MAX_TIMELOCK) revert TimelockTooLong();
        // A non-zero timelock must clear the floor so the veto stays meaningful;
        // 0 is still allowed to explicitly disable it.
        if (newTimelock != 0 && newTimelock < MIN_TIMELOCK) revert TimelockTooShort();
        claimTimelock = newTimelock;
        emit TimelockChanged(newTimelock);
    }

    /// @notice Step 1 of signer rotation: schedule `next` to take over after
    ///         SIGNER_ROTATION_DELAY. Overwrites any in-flight rotation.
    function startSignerRotation(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        pendingSigner = next;
        pendingSignerAfter = uint64(block.timestamp) + SIGNER_ROTATION_DELAY;
        emit SignerRotationStarted(next, pendingSignerAfter);
    }

    /// @notice Step 2: finalise the scheduled rotation once the delay elapsed.
    function finalizeSignerRotation() external onlyOwner {
        if (pendingSigner == address(0)) revert NothingPending();
        if (block.timestamp < pendingSignerAfter) revert RotationNotReady();
        address prev = trustedSigner;
        trustedSigner = pendingSigner;
        pendingSigner = address(0);
        pendingSignerAfter = 0;
        emit TrustedSignerUpdated(prev, trustedSigner);
    }

    /// @notice Cancel a scheduled rotation (e.g. the new key was also lost).
    function cancelSignerRotation() external onlyOwner {
        pendingSigner = address(0);
        pendingSignerAfter = 0;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Renouncing ownership would strand every admin lever (signer
    ///      rotation, veto, pause) forever; disable it.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ====================== Deposit ======================

    /**
     * @notice A trusted crediter (the ArcadeHook) records that `amount` of
     *         `token` has arrived for (positionId, slotIndex). The crediter is
     *         expected to have transferred the tokens to this contract BEFORE
     *         this call. We VERIFY delivery with a balance-diff: `amount` may
     *         not exceed the un-earmarked balance (balanceOf - creditedTotal),
     *         so a credit whose transfer pended cannot inflate the books.
     */
    function creditSlot(uint256 positionId, uint256 slotIndex, address token, uint256 amount) external {
        if (!allowedCrediter[msg.sender]) revert NotCrediter();
        if (token == address(0)) revert InvalidToken();

        // Balance-diff: the newly-arrived, not-yet-earmarked balance.
        uint256 free = IERC20(token).balanceOf(address(this)) - creditedTotal[token];
        if (amount == 0 || amount > free) revert NothingDelivered();

        // A slot holds exactly one token (fees are USDC). Pin it on first
        // credit; reject a different token so forfeit/claim can't be aimed at
        // an unrelated balance.
        address pinned = slotToken[positionId][slotIndex];
        if (pinned == address(0)) {
            slotToken[positionId][slotIndex] = token;
        } else if (pinned != token) {
            revert InvalidToken();
        }

        balances[positionId][slotIndex][token] += amount;
        creditedTotal[token] += amount;
        // Anchor the forfeit clock on the FIRST credit only; later credits do
        // NOT push it out (that reset is what let a permissionless collectFees
        // keep an abandoned slot un-forfeitable forever).
        if (forfeitAnchorAt[positionId][slotIndex] == 0) {
            forfeitAnchorAt[positionId][slotIndex] = uint64(block.timestamp);
        }
        emit Credited(positionId, slotIndex, token, amount);
    }

    // ====================== Claim (two-step) ======================

    /**
     * @notice Step 1: deposit a backend-signed claim authorization. The wallet
     *         submitting this MUST equal `recipient` (anti-phishing), so a
     *         signature tricked out of a user with an attacker `recipient`
     *         cannot settle. No funds move here.
     */
    function authorize(
        uint256 positionId,
        uint256 slotIndex,
        address recipient,
        address token,
        uint256 amount,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata signature
    ) external whenNotPaused {
        if (deadline < block.timestamp) revert DeadlineInPast();
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient != msg.sender) revert RecipientNotSender();
        if (nonceUsed[nonce]) revert NonceReused();
        if (hasPending[positionId][slotIndex]) revert SlotPending();

        bytes32 digest = _hashClaim(positionId, slotIndex, recipient, token, amount, deadline, nonce);
        if (digest.recover(signature) != trustedSigner) revert InvalidSignature();

        uint256 bal = balances[positionId][slotIndex][token];
        if (bal == 0) revert NothingToClaim();
        // Signed amount is a MINIMUM guarantee; claim sweeps the live balance.
        if (amount > bal) revert InsufficientBalance();

        uint256 executeAfter = block.timestamp + claimTimelock;
        if (deadline < executeAfter) revert DeadlineInPast();

        pendingClaims[nonce] = PendingClaim({
            recipient: recipient,
            token: token,
            amount: amount,
            positionId: positionId,
            slotIndex: slotIndex,
            executeAfter: executeAfter,
            deadline: deadline,
            consumed: false,
            vetoed: false
        });
        nonceUsed[nonce] = true;
        hasPending[positionId][slotIndex] = true;
        emit Authorized(nonce, positionId, slotIndex, executeAfter);
    }

    /**
     * @notice Step 2: execute an authorized claim after the timelock. Sweeps
     *         the slot's CURRENT balance to `recipient` (>= the signed amount)
     *         and REOPENS the slot -- fees credited later can be claimed again.
     *         Permissionless (anyone pays gas; funds go to the stored recipient).
     */
    function claimByTwitter(bytes32 nonce) external whenNotPaused nonReentrant {
        PendingClaim storage p = pendingClaims[nonce];
        if (p.executeAfter == 0) revert NotAuthorized();
        if (p.consumed || p.vetoed) revert AlreadyClaimed();
        if (block.timestamp < p.executeAfter) revert Timelocked();
        if (block.timestamp > p.deadline) revert Expired();

        uint256 positionId = p.positionId;
        uint256 slotIndex = p.slotIndex;
        address recipient = p.recipient;
        address token = p.token;

        uint256 sweep = balances[positionId][slotIndex][token];
        if (p.amount > sweep) revert InsufficientBalance();

        // Effects (CEI): consume, clear the slot balance, reopen the slot.
        p.consumed = true;
        hasPending[positionId][slotIndex] = false;
        balances[positionId][slotIndex][token] = 0;
        creditedTotal[token] -= sweep;

        // A successful claim proves the handle owner is present: reset the
        // forfeit clock so an actively-claimed slot is never swept.
        forfeitAnchorAt[positionId][slotIndex] = uint64(block.timestamp);

        // Interaction.
        if (sweep > 0) IERC20(token).safeTransfer(recipient, sweep);
        emit Claimed(positionId, slotIndex, recipient, token, sweep);
    }

    /// @notice Cancel a pending authorization (suspected signer compromise).
    ///         Frees the slot so a fresh nonce can be authorized.
    function veto(bytes32 nonce) external onlyOwner {
        PendingClaim storage p = pendingClaims[nonce];
        if (p.executeAfter == 0) revert NotAuthorized();
        if (p.consumed) revert AlreadyClaimed();
        if (p.vetoed) revert Already();
        p.vetoed = true;
        hasPending[p.positionId][p.slotIndex] = false;
        emit Vetoed(nonce);
    }

    // ====================== Forfeit (abandoned handle) ======================

    /**
     * @notice After FORFEIT_DELAY with NO successful claim (clock anchored at
     *         launch, reset only on claim), the owner may route the slot's
     *         stranded balance elsewhere (the handle never appeared). Ongoing
     *         credits do NOT delay this. Bounded to the slot's pinned token and
     *         its exact credited amount; a reverting transfer stashes to
     *         `pendingForfeit` (pull-payment).
     */
    function forfeitStaleClaim(uint256 positionId, uint256 slotIndex, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _forfeit(positionId, slotIndex, to);
    }

    /// @notice Permissionless forfeit of an abandoned slot to the FIXED
    ///         `forfeitTreasury`. Anyone may trigger it once the slot is stale,
    ///         but the funds can only go to the owner-set treasury, so there is no
    ///         redirection vector. Lets an automated keeper settle stale USDC to
    ///         the treasury without an owner tx -- the on-chain half of "both
    ///         sides to the treasury at 180d" (the token side is swept off-chain).
    ///         Reverts if `forfeitTreasury` is unset.
    function forfeitStaleToTreasury(uint256 positionId, uint256 slotIndex) external {
        address to = forfeitTreasury;
        if (to == address(0)) revert ZeroAddress();
        _forfeit(positionId, slotIndex, to);
    }

    /// @dev Shared forfeit core. CEI: all state (balance, creditedTotal, anchor)
    ///      is cleared BEFORE the transfer, so even the permissionless entrypoint
    ///      cannot reenter (a second call sees amount == 0 -> NothingToClaim).
    function _forfeit(uint256 positionId, uint256 slotIndex, address to) internal {
        uint64 anchor = forfeitAnchorAt[positionId][slotIndex];
        if (anchor == 0 || block.timestamp < anchor + FORFEIT_DELAY) revert NotStaleYet();
        if (hasPending[positionId][slotIndex]) revert SlotPending();

        address token = slotToken[positionId][slotIndex];
        if (token == address(0)) revert InvalidToken();
        uint256 amount = balances[positionId][slotIndex][token];
        if (amount == 0) revert NothingToClaim();

        balances[positionId][slotIndex][token] = 0;
        creditedTotal[token] -= amount;
        // Reset the anchor so the slot is "fresh" again: the NEXT credit
        // re-anchors a new FORFEIT_DELAY window (matches creditSlot's
        // first-credit semantics). Without this, every post-forfeit credit
        // lands already past the old anchor and is instantly forfeitable,
        // voiding the 180-day protection for a late-arriving handle owner.
        // (Audit 2026-07-18 MEDIUM.)
        forfeitAnchorAt[positionId][slotIndex] = 0;

        try this.pushForfeit(token, to, amount) {
            emit Forfeited(positionId, slotIndex, to, token, amount);
        } catch {
            pendingForfeit[token][to] += amount;
            pendingForfeitTotal[token] += amount; // keep it out of rescue's free window
            emit ForfeitTransferFailed(positionId, slotIndex, token, to, amount);
        }
    }

    /// @dev External-self so the forfeit transfer can be try/catch'd without a
    ///      low-level call. Only callable by this contract.
    function pushForfeit(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Recover a forfeit payout whose transfer previously reverted.
    function withdrawForfeitFailure(address token) external nonReentrant {
        uint256 amount = pendingForfeit[token][msg.sender];
        if (amount == 0) revert NothingPending();
        pendingForfeit[token][msg.sender] = 0;
        pendingForfeitTotal[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // ====================== Rescue (un-earmarked only) ======================

    /**
     * @notice Sweep tokens that are NOT earmarked to any slot (stray transfers,
     *         credit dust). Bounded by `creditedTotal` so the owner can never
     *         touch a user's credited balance.
     */
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        // Exclude BOTH slot-credited balances and pending-forfeit payouts so the
        // owner can only ever sweep genuinely un-earmarked dust.
        uint256 free = bal - creditedTotal[token] - pendingForfeitTotal[token];
        if (amount > free) revert ExceedsFreeBalance();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ====================== Views / EIP-712 ======================

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) return _DOMAIN_SEPARATOR_CACHED;
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ArcadeTwitterEscrow"),
                keccak256("4"),
                block.chainid,
                address(this)
            )
        );
    }

    function _hashClaim(
        uint256 positionId,
        uint256 slotIndex,
        address recipient,
        address token,
        uint256 amount,
        uint256 deadline,
        bytes32 nonce
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, positionId, slotIndex, recipient, token, amount, deadline, nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }
}
