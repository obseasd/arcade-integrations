// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IArcadeRwaRegistry} from "./interfaces/IArcadeRwaRegistry.sol";

/// @title ArcadeRwaRegistry
/// @notice Owner-curated (the Safe) list of the assets an RWA launch may pair
///         against, with the ONE start market cap every launch on that asset
///         opens at, in the asset's own raw units.
///
/// @dev Why a separate contract. The v1 hook validated the start market cap
///      against `internal constant`s written for a 6-decimal quote
///      (1_000e6 / 35_000e6 / 100_000e6). For an 18-decimal asset those numbers
///      are dust, so any sane cap reverted `InvalidStartMcap`. The hook is
///      non-upgradeable and sits 423 bytes under EIP-170, so the policy moved
///      here: the hook v2 holds this registry as an immutable and asks
///      `startMcapOf(quote)` at launch time. Adding the next RWA is
///      `setQuote`, one owner transaction, no redeploy anywhere.
///
///      What an asset must be to qualify (checked by the owner before
///      `setQuote`, the same list as the v1 spec B1/M7): a plain ERC20 with
///      `decimals()`, non-rebasing, no fee on transfer, no transfer callbacks,
///      and not transfer-gated for the PoolManager, the hook and the router
///      (a gated asset such as USYC is registered `permissioned` only once the
///      issuer has allowlisted them, or never).
contract ArcadeRwaRegistry is IArcadeRwaRegistry, Ownable2Step {
    mapping(address => QuoteCfg) private _quotes;
    address[] private _quoteList;
    mapping(address => bool) private _listed;

    event QuoteSet(
        address indexed asset, bool allowed, uint8 decimals, uint128 startMcap, address priceSource, bool permissioned
    );

    error QuoteNotAllowed();
    error ZeroAddress();
    error ZeroStartMcap();
    error NotAContract();
    error NoDecimals();
    error BadDecimals(); // outside the distributor's 2..27 payout range

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Register or update an asset. `decimals` is read from the asset,
    ///         never trusted from the caller. A `priceSource` of zero means the
    ///         asset is worth 1 USD (a stablecoin); otherwise it must have code.
    function setQuote(address asset, bool allowed, uint128 startMcap, address priceSource, bool permissioned)
        external
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();
        if (asset.code.length == 0) revert NotAContract();
        if (allowed && startMcap == 0) revert ZeroStartMcap();
        if (priceSource != address(0) && priceSource.code.length == 0) revert NotAContract();
        uint8 dec;
        try IERC20Metadata(asset).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            revert NoDecimals();
        }
        // The distributor pays dividends in this asset and derives its auto-push
        // threshold from decimals(); it accepts 2..27 and registerLaunch reverts
        // BadQuoteDecimals outside. Mirror the bound here so the Safe cannot list
        // an asset every launch on which reverts (audit 2026-09-18 INFO).
        if (dec < 2 || dec > 27) revert BadDecimals();
        _quotes[asset] = QuoteCfg({
            allowed: allowed,
            decimals: dec,
            startMcap: startMcap,
            priceSource: priceSource,
            permissioned: permissioned
        });
        if (!_listed[asset]) {
            _listed[asset] = true;
            _quoteList.push(asset);
        }
        emit QuoteSet(asset, allowed, dec, startMcap, priceSource, permissioned);
    }

    /// @inheritdoc IArcadeRwaRegistry
    function startMcapOf(address quote) external view returns (uint256) {
        QuoteCfg storage q = _quotes[quote];
        if (!q.allowed) revert QuoteNotAllowed();
        return q.startMcap;
    }

    /// @inheritdoc IArcadeRwaRegistry
    function isAllowed(address quote) external view returns (bool) {
        return _quotes[quote].allowed;
    }

    /// @inheritdoc IArcadeRwaRegistry
    function quotes(address quote)
        external
        view
        returns (bool allowed, uint8 decimals, uint128 startMcap, address priceSource, bool permissioned)
    {
        QuoteCfg storage q = _quotes[quote];
        return (q.allowed, q.decimals, q.startMcap, q.priceSource, q.permissioned);
    }

    /// @inheritdoc IArcadeRwaRegistry
    function quoteList() external view returns (address[] memory) {
        return _quoteList;
    }

    /// @notice Ownership is never renounced: the registry must always be
    ///         reachable to add or pause an asset.
    function renounceOwnership() public view override onlyOwner {
        revert("no");
    }
}
