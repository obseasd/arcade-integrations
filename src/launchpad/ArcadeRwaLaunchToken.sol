// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IArcadeDividendDistributor} from "../../v4src/interfaces/IArcadeDividendDistributor.sol";

/// @title ArcadeRwaLaunchToken
/// @notice Fixed-supply ERC20 for the RWA launch mode. Identical to
///         ArcadeLaunchToken (no mint, no owner, full supply to the launchpad at
///         deploy) EXCEPT it notifies the dividend distributor on every balance
///         change via an `_update` override, so per-holder dividend accounting
///         stays correct (settle on transfer). Both pointers are immutable.
///
///         The distributor call passes PRE-move balances (captured before
///         super._update) so settlement is computed on the correct old balances
///         (audit A4). Before the distributor has registered this token (i.e. the
///         constructor mint to the launchpad), the distributor no-ops.
contract ArcadeRwaLaunchToken is ERC20 {
    address public immutable launchpad;
    IArcadeDividendDistributor public immutable distributor;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        address launchpad_,
        address distributor_
    ) ERC20(name_, symbol_) {
        launchpad = launchpad_;
        distributor = IArcadeDividendDistributor(distributor_);
        _mint(launchpad_, supply);
    }

    /// @dev OZ v5 funnels mint/burn/transfer through `_update`. Capture pre-move
    ///      balances, move, then notify the distributor. The distributor swallows
    ///      the call if this token is not yet registered (constructor mint) and
    ///      guards its own reentrancy domain, so this never reverts a transfer.
    function _update(address from, address to, uint256 value) internal override {
        uint256 fromBalBefore = from == address(0) ? 0 : balanceOf(from);
        uint256 toBalBefore = to == address(0) ? 0 : balanceOf(to);
        super._update(from, to, value);
        distributor.onTokenTransfer(from, to, value, fromBalBefore, toBalBefore);
    }
}
