// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title HolderAirdropDistributor
 * @notice Airdrop-as-a-service for launch-token holders. A creator (off-chain,
 *         opt-in per token) funds a reward pool; the Arcade keeper computes a
 *         holder snapshot at a finalized block, applies the anti-sybil filters
 *         (per-wallet cap, min balance/hold, MANDATORY protocol-address
 *         exclusion, optional clustering down-weight), and posts a MERKLE ROOT
 *         of {account, amount}. Holders claim with a proof; anything unclaimed
 *         after the window forfeits to the treasury.
 *
 *         Trust model: the KEEPER (operator) is trusted to post correct roots,
 *         but the root + snapshot inputs are published off-chain and are fully
 *         recomputable, and the contract still enforces the hard invariants:
 *           - a distribution can never pay out more than it was funded,
 *           - no account can double-claim an epoch,
 *           - only the operator posts roots, only after funding covers them,
 *           - unclaimed forfeits only after the deadline.
 *         The reward is USDC-native (Arc gas is USDC), so ~100% reaches holders.
 *
 *         This contract holds only opt-in reward funds; it never touches the
 *         hook, a pool, or protocol fees, so a bug here cannot affect any swap.
 */
contract HolderAirdropDistributor {
    using SafeERC20 for IERC20;

    address public owner;
    address public operator; // the keeper that posts Merkle roots
    address public treasury; // forfeit destination

    struct Distribution {
        address rewardToken;
        bytes32 merkleRoot;
        uint256 total; // allocated for this epoch
        uint256 claimed;
        uint64 deadline; // after this, unclaimed can be swept to treasury
        bool swept;
    }

    /// launchToken => rewardToken => unallocated funded balance.
    mapping(address => mapping(address => uint256)) public available;
    /// launchToken => epoch => distribution.
    mapping(address => mapping(uint256 => Distribution)) public distributions;
    /// launchToken => number of epochs posted.
    mapping(address => uint256) public epochCount;
    /// launchToken => epoch => word index => claimed bitmap.
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) private claimedBitMap;

    error NotOwner();
    error NotOperator();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientFunding(uint256 have, uint256 need);
    error AlreadyClaimed();
    error ClaimWindowClosed();
    error InvalidProof();
    error NotEnded();
    error AlreadySwept();
    error BadDeadline();

    event OperatorSet(address indexed operator);
    event TreasurySet(address indexed treasury);
    event OwnershipTransferred(address indexed from, address indexed to);
    event Funded(address indexed launchToken, address indexed rewardToken, address indexed from, uint256 amount);
    event FundingWithdrawn(address indexed launchToken, address indexed rewardToken, address to, uint256 amount);
    event DistributionPosted(
        address indexed launchToken, uint256 indexed epoch, address rewardToken, bytes32 merkleRoot, uint256 total, uint64 deadline
    );
    event Claimed(address indexed launchToken, uint256 indexed epoch, uint256 index, address indexed account, uint256 amount);
    event Swept(address indexed launchToken, uint256 indexed epoch, uint256 amount);

    constructor(address owner_, address operator_, address treasury_) {
        if (owner_ == address(0) || operator_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        owner = owner_;
        operator = operator_;
        treasury = treasury_;
        emit OwnershipTransferred(address(0), owner_);
        emit OperatorSet(operator_);
        emit TreasurySet(treasury_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // --- Admin ------------------------------------------------------------

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- Funding (permissionless: creator or anyone tops up a reward pool) --

    function fund(address launchToken, address rewardToken, uint256 amount) external {
        if (launchToken == address(0) || rewardToken == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // Balance-diff so fee-on-transfer reward tokens credit only what arrived.
        uint256 before = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - before;
        available[launchToken][rewardToken] += received;
        emit Funded(launchToken, rewardToken, msg.sender, received);
    }

    /// @notice Owner can reclaim UNALLOCATED funding (never posted funds). Posted
    ///         distributions are untouchable except via claim/sweep.
    function withdrawUnallocated(address launchToken, address rewardToken, address to, uint256 amount)
        external
        onlyOwner
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = available[launchToken][rewardToken];
        if (amount > avail) revert InsufficientFunding(avail, amount);
        available[launchToken][rewardToken] = avail - amount;
        IERC20(rewardToken).safeTransfer(to, amount);
        emit FundingWithdrawn(launchToken, rewardToken, to, amount);
    }

    // --- Distributions ----------------------------------------------------

    /// @notice Post a new epoch's Merkle root (keeper). `total` is deducted from
    ///         the funded pool now, so the epoch is always fully collateralized.
    function postDistribution(
        address launchToken,
        address rewardToken,
        bytes32 merkleRoot,
        uint256 total,
        uint64 claimWindow
    ) external onlyOperator returns (uint256 epoch) {
        if (total == 0) revert ZeroAmount();
        if (claimWindow == 0) revert BadDeadline();
        uint256 avail = available[launchToken][rewardToken];
        if (total > avail) revert InsufficientFunding(avail, total);
        available[launchToken][rewardToken] = avail - total;

        epoch = epochCount[launchToken]++;
        distributions[launchToken][epoch] = Distribution({
            rewardToken: rewardToken,
            merkleRoot: merkleRoot,
            total: total,
            claimed: 0,
            deadline: uint64(block.timestamp) + claimWindow,
            swept: false
        });
        emit DistributionPosted(launchToken, epoch, rewardToken, merkleRoot, total, distributions[launchToken][epoch].deadline);
    }

    function isClaimed(address launchToken, uint256 epoch, uint256 index) public view returns (bool) {
        uint256 word = index >> 8;
        uint256 bit = index & 0xff;
        return (claimedBitMap[launchToken][epoch][word] >> bit) & 1 == 1;
    }

    function _setClaimed(address launchToken, uint256 epoch, uint256 index) internal {
        uint256 word = index >> 8;
        uint256 bit = index & 0xff;
        claimedBitMap[launchToken][epoch][word] |= (1 << bit);
    }

    /// @notice Claim `amount` for `account` in an epoch with a Merkle proof of the
    ///         leaf keccak256(index, account, amount). Permissionless caller; the
    ///         reward always goes to `account`.
    function claim(
        address launchToken,
        uint256 epoch,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        if (isClaimed(launchToken, epoch, index)) revert AlreadyClaimed();
        Distribution storage d = distributions[launchToken][epoch];
        // Claims only within the live window: after the deadline the remainder
        // may be swept to treasury, so a post-deadline / post-sweep claim would
        // double-pay from the shared reward-token pool (CRITICAL-1 fix).
        if (d.swept) revert AlreadySwept();
        if (block.timestamp > d.deadline) revert ClaimWindowClosed();
        // Never pay out more than this epoch's own collateral, so an
        // oversubscribed root can't drain other campaigns sharing the reward
        // token (CRITICAL-2 fix).
        uint256 newClaimed = d.claimed + amount;
        if (newClaimed > d.total) revert InsufficientFunding(d.total - d.claimed, amount);

        // Leaf is domain-separated by launchToken + epoch so a reused root can
        // never be replayed across epochs/campaigns (L-1 hardening).
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(launchToken, epoch, index, account, amount))));
        if (!MerkleProof.verify(proof, d.merkleRoot, leaf)) revert InvalidProof();

        _setClaimed(launchToken, epoch, index);
        d.claimed = newClaimed;
        IERC20(d.rewardToken).safeTransfer(account, amount);
        emit Claimed(launchToken, epoch, index, account, amount);
    }

    /// @notice After the deadline, forfeit the unclaimed remainder to treasury.
    function sweep(address launchToken, uint256 epoch) external returns (uint256 remainder) {
        Distribution storage d = distributions[launchToken][epoch];
        if (d.deadline == 0) revert BadDeadline(); // no such epoch
        if (block.timestamp <= d.deadline) revert NotEnded();
        if (d.swept) revert AlreadySwept();
        d.swept = true;
        remainder = d.total - d.claimed;
        if (remainder > 0) IERC20(d.rewardToken).safeTransfer(treasury, remainder);
        emit Swept(launchToken, epoch, remainder);
    }
}
