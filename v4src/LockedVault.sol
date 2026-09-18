// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title LockedVault
 * @notice Immutable recipient of ERC-6909 LP claim tokens minted by the V4
 *         PoolManager whenever ArcadeHook's afterAddLiquidity locks a
 *         graduation-seed position.
 *
 *         The PoolManager holds the 6909 accounting internally; this contract
 *         is just the owner-of-record address. It exposes ZERO functions to
 *         move, approve, or burn anything. The PoolManager's transfer /
 *         transferFrom / approve surface all require msg.sender to either own
 *         the balance or be approved by the owner, and since this contract
 *         calls neither, the 6909 it accumulates is effectively burned.
 *
 *         There is no admin, no upgrade path, no setter. Once deployed, the
 *         LP claim tokens it holds are unreachable forever.
 *
 *         Design note: an EOA-style burn address (0xdEaD, 0x0) is rejected by
 *         some contracts as a sentinel; using a deployed contract with empty
 *         executable surface is the cleanest no-transfer guarantee.
 */
contract LockedVault {
    // Intentionally empty. The contract's only purpose is to exist at a
    // unique address that nobody can sign for.
}
