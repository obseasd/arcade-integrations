// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply ERC20 minted entirely to the launchpad at deploy time.
/// No further minting is possible. Name and symbol are stored by OZ's ERC20
/// base; this contract only adds the immutable `launchpad` pointer.
contract ArcadeLaunchToken is ERC20 {
    address public immutable launchpad;

    constructor(string memory name_, string memory symbol_, uint256 supply, address launchpad_)
        ERC20(name_, symbol_)
    {
        launchpad = launchpad_;
        _mint(launchpad_, supply);
    }
}
