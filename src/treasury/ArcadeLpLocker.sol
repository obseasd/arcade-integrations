// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IV3PositionManager {
    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

/**
 * @title ArcadeLpLocker
 * @notice Holds a Uniswap V3 position NFT forever, and lets its trading fees be
 *         collected forever.
 *
 * @dev THE POINT IS WHAT THIS CONTRACT CANNOT DO. It has no function that moves
 *      the NFT and no function that reduces the position:
 *
 *        - no `transferFrom`, no `safeTransferFrom`, no `approve`, no
 *          `setApprovalForAll` against the position manager, so the NFT can
 *          never leave this address by any route, including an allowance;
 *        - no `decreaseLiquidity`, so the liquidity itself can never shrink;
 *        - no `burn`, no generic `execute(address,bytes)` or `multicall`, no
 *          proxy and no upgrade path, so nothing can be added later.
 *
 *      An owner able to do any of those would make the lock a promise. Here the
 *      only privileged action is choosing where the fees go.
 *
 *      WHY THIS RATHER THAN BURNING THE NFT. Burning to a dead address locks the
 *      liquidity just as well, but only an NFT's owner can call `collect`, so it
 *      also throws away every trading fee the position will ever earn. On a 1%
 *      tier that is 1,000 USDC per 100,000 of volume, permanently. This contract
 *      gives holders the identical guarantee and keeps the fees.
 *
 *      Both references do exactly this. PONS's locker
 *      (0x31ca5E101941A93A7DD6d0497928700625CF54B5 on Robinhood Chain) was read
 *      byte by byte: it has `collect` and no `decreaseLiquidity`, no
 *      `transferFrom`, no `burn` and no upgrade path. Clanker's LP locker is
 *      documented the same way. Their "100% of fees come back to us" is exactly
 *      this: the LP share because they hold the position, plus the protocol
 *      share because they own the factory.
 *
 *      `collect` is PERMISSIONLESS but always pays `feeRecipient`. Anyone may
 *      trigger it, nobody can redirect it, and a keeper needs no privileges. The
 *      owner may change the recipient, which is a revenue decision rather than a
 *      custody one: it can never reach the liquidity.
 *
 *      Ownership may be renounced. That freezes the recipient for good while
 *      leaving `collect` working, which is a real credibility step rather than a
 *      footgun, so it is deliberately NOT disabled here.
 */
contract ArcadeLpLocker is Ownable2Step {
    /// @notice The Uniswap V3 position manager whose NFTs this contract locks.
    IV3PositionManager public immutable POSITION_MANAGER;

    /// @notice Where collected fees are sent.
    address public feeRecipient;

    /// @notice The address permitted to hand positions in, besides the owner.
    ///
    /// @dev Intake is gated because nothing can ever leave. Left open, anyone
    ///      could mint a throwaway position and push it in: it would be stuck
    ///      here forever, it would grow `lockedTokenIds` without bound so
    ///      `collectAll` eventually runs out of gas, and it would muddy any
    ///      claim about what this contract actually holds. Per-position
    ///      `collect` would survive, but the griefing is free and there is no
    ///      reason to accept it.
    ///
    ///      This is the launch EOA in practice, since the Safe is the owner but
    ///      the deployer is what holds the freshly minted position.
    address public depositor;

    /// @notice Positions this contract has accepted, in arrival order. Kept so
    ///         the set is enumerable on-chain rather than only from event logs.
    uint256[] public lockedTokenIds;
    mapping(uint256 => bool) public isLocked;

    uint128 internal constant MAX_UINT128 = type(uint128).max;

    event FeeRecipientSet(address indexed recipient);
    event DepositorSet(address indexed depositor);
    event PositionLocked(uint256 indexed tokenId, address indexed from);
    event FeesCollected(uint256 indexed tokenId, address indexed recipient, uint256 amount0, uint256 amount1);

    error ZeroAddress();
    error NotThePositionManager();
    error NotAnAllowedDepositor();
    error NotLocked();

    constructor(address positionManager_, address feeRecipient_, address depositor_, address owner_)
        Ownable(owner_)
    {
        if (positionManager_ == address(0) || feeRecipient_ == address(0) || depositor_ == address(0)) {
            revert ZeroAddress();
        }
        POSITION_MANAGER = IV3PositionManager(positionManager_);
        feeRecipient = feeRecipient_;
        depositor = depositor_;
        emit FeeRecipientSet(feeRecipient_);
        emit DepositorSet(depositor_);
    }

    /**
     * @notice Accept a position NFT. This is a one-way door.
     *
     * @dev TWO gates, and both matter. `msg.sender` must be the configured
     *      position manager, so no arbitrary NFT contract can register itself
     *      here. And `from` must be the depositor or the owner, so no stranger
     *      can push a throwaway position in: nothing ever leaves, so that would
     *      be permanent, free griefing.
     *
     *      Reverting here makes `safeTransferFrom` revert too, which leaves the
     *      NFT with its sender. Refusing is always the safe direction.
     */
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        if (msg.sender != address(POSITION_MANAGER)) revert NotThePositionManager();
        if (from != depositor && from != owner()) revert NotAnAllowedDepositor();
        if (!isLocked[tokenId]) {
            isLocked[tokenId] = true;
            lockedTokenIds.push(tokenId);
        }
        emit PositionLocked(tokenId, from);
        return this.onERC721Received.selector;
    }

    /**
     * @notice Sweep a locked position's accrued trading fees to `feeRecipient`.
     *
     * @dev Permissionless. There is nothing to protect: the destination is
     *      storage, not an argument, so the worst a caller can do is pay gas to
     *      move our own fees to our own address. Making it privileged would only
     *      add a key that has to stay alive.
     */
    function collect(uint256 tokenId) public returns (uint256 amount0, uint256 amount1) {
        if (!isLocked[tokenId]) revert NotLocked();
        address to = feeRecipient;
        (amount0, amount1) = POSITION_MANAGER.collect(
            IV3PositionManager.CollectParams({
                tokenId: tokenId,
                recipient: to,
                amount0Max: MAX_UINT128,
                amount1Max: MAX_UINT128
            })
        );
        emit FeesCollected(tokenId, to, amount0, amount1);
    }

    /// @notice Collect every locked position in one call.
    function collectAll() external {
        uint256 n = lockedTokenIds.length;
        for (uint256 i = 0; i < n; ++i) {
            collect(lockedTokenIds[i]);
        }
    }

    // ---------------------------------------------------------------- admin

    /// @notice Redirect future fee collections.
    /// @dev The only privileged function in this contract, and it cannot touch
    ///      the liquidity. Deliberately does not affect fees already collected.
    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    /// @notice Change who may hand positions in.
    /// @dev Also cannot touch the liquidity: the worst it does is decide who is
    ///      allowed to give this contract something it can never give back.
    function setDepositor(address d) external onlyOwner {
        if (d == address(0)) revert ZeroAddress();
        depositor = d;
        emit DepositorSet(d);
    }

    // ----------------------------------------------------------------- views

    function lockedCount() external view returns (uint256) {
        return lockedTokenIds.length;
    }

    /// @notice The liquidity held for a locked position, straight from the
    ///         position manager. For anyone verifying that it never falls.
    function lockedLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
    }
}
