// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IArcadeDividendDistributor
/// @notice Minimal surface the ArcadeHook (accrual + registration) and the RWA
///         launch token (transfer notifications) need from the dividend
///         distributor. Kept small so the token stays a thin ERC20.
interface IArcadeDividendDistributor {
    /// @notice The ONE hook this distributor is bound to (immutable): the sole
    ///         caller of registerLaunch + accrue. The hook reads it in its
    ///         one-way setDividendDistributor so a distributor bound to another
    ///         hook can never be wired (audit 2026-09-19 L2).
    function hook() external view returns (address);

    /// @notice Called by the hook once per launch, at createLaunch, to freeze the
    ///         immutable per-launch dividend config. `excludedAddrs` seeds the
    ///         share-base (S) exclusion set with the pool custody address(es), the
    ///         hook and the treasury. The dev is excluded separately (bootstrap).
    function registerLaunch(
        address token,
        address quoteAsset,
        address creator,
        uint256 devBuyAmount,
        address[] calldata excludedAddrs
    ) external;

    /// @notice Called by the hook after it has already transferred `amount` of the
    ///         launch's quote asset to THIS contract (via PoolManager.take). Only
    ///         updates the per-share index; funds are already custodied here.
    function accrue(address token, uint256 amount) external;

    /// @notice Called by the launch token from its `_update` override, AFTER the
    ///         balances have moved, passing the PRE-move balances so settle is
    ///         computed on the correct (old) balances. msg.sender MUST be the token.
    function onTokenTransfer(
        address from,
        address to,
        uint256 amount,
        uint256 fromBalBefore,
        uint256 toBalBefore
    ) external;

    /// @notice Pull the caller's accrued dividends for `token`.
    function claim(address token) external;

    /// @notice Permissionless: pull `holder`'s accrued dividends for `token`.
    function claimFor(address token, address holder) external;

    /// @notice View: dividends `holder` can currently withdraw for `token`.
    function claimable(address token, address holder) external view returns (uint256);
}
