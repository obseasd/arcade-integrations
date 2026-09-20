// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The anti-sniper read surface: a per-token, time-decaying tax rate in
///         bps. Implemented by the production `ArcadeHook` (which reads its OWN
///         snipeConfigs, not an external launchpad's). Kept as a named
///         interface so the getter has a stable ABI for indexers/frontends.
///
///         Extracted 2026-07-17 from the now-deleted `IArcadeV4Launchpad.sol`
///         when the ArcadeV4Launchpad + ArcadeAntiSniperHook prototype was
///         removed; ArcadeHook is the only remaining implementer.
interface ILaunchpadSnipe {
    function currentSnipeBps(address token) external view returns (uint256);
}
