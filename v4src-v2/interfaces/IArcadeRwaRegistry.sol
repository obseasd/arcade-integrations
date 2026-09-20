// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IArcadeRwaRegistry
/// @notice The RWA quote policy the hook consults at launch time. Lives outside
///         the hook so that adding an asset is one owner transaction and never a
///         hook redeploy, and so that the policy can be expressed in each asset's
///         own units and decimals (the v1 hook compiled 6-decimal constants and
///         could not launch on an 18-decimal quote such as XAUM).
interface IArcadeRwaRegistry {
    struct QuoteCfg {
        /// @notice Launches may pair against this asset.
        bool allowed;
        /// @notice ERC20 decimals, read from the asset at registration and kept
        ///         for off-chain consumers (UI, indexer).
        uint8 decimals;
        /// @notice THE start market cap of every launch on this quote, in the
        ///         quote's raw units. The creator does not choose it (operator
        ///         decision 2026-09-18: 35,000 USD equivalent for every asset).
        uint128 startMcap;
        /// @notice A canonical Uniswap V3 pool QUOTE/USDC that prices the asset
        ///         for off-chain consumers, or zero for "1 USD" (stables).
        address priceSource;
        /// @notice Transfer-gated asset (issuer allowlist). Informational: the
        ///         UI warns, the hook cannot do anything about it.
        bool permissioned;
    }

    /// @notice The fixed start market cap for `quote`, in raw quote units.
    /// @dev Reverts `QuoteNotAllowed` when the asset is not allowed, so the hook
    ///      needs no second check.
    function startMcapOf(address quote) external view returns (uint256);

    /// @notice Whether launches may pair against `quote`.
    function isAllowed(address quote) external view returns (bool);

    /// @notice The full policy for `quote`.
    function quotes(address quote)
        external
        view
        returns (bool allowed, uint8 decimals, uint128 startMcap, address priceSource, bool permissioned);

    /// @notice Every asset ever registered, allowed or not (the UI filters).
    function quoteList() external view returns (address[] memory);
}
