// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title ArcadeToken
 * @notice The Arcade platform token. Fixed supply, minted once at deployment.
 *
 * @dev What this contract deliberately does NOT have, because each one is a
 *      thing a holder would otherwise have to trust us not to use:
 *
 *      - no owner, and therefore no privileged function over anyone's balance
 *      - no mint after construction, so the supply printed here is final
 *      - no burn-from, pause, blacklist, freeze or fee on transfer
 *      - no upgradeability and no proxy
 *
 *      The whole supply goes to `recipient` at construction. The distribution
 *      that follows happens in the open market, through the pool this token is
 *      seeded into.
 *
 *      LAUNCH GUARD (optional, one-way, ends with the launch bundle, not a timer).
 *      When `pool` is non-zero, tokens may leave that pool ONLY to the launch
 *      recipients whose address hashes are given at construction, until every
 *      one of them has received at least `minReceive`. The moment the last one
 *      does, the guard switches off for good and this is a plain ERC20. Nothing
 *      can switch it back on, and nothing restricts any other transfer at any
 *      time: holders move tokens freely, only BUYS from that one pool are gated,
 *      and only until the launch buys have landed.
 *
 *      Why it exists: the token address is derivable before launch. Without it,
 *      anyone whose transaction lands between the liquidity and the launch buys,
 *      in the same block, buys at the opening price. With it, such a buy
 *      reverts, whatever the ordering.
 *
 *      Recipients are stored as keccak256(address) so the list is not published
 *      in the deployment calldata. `minReceive` stops a dust transfer to a
 *      recipient from counting as its launch buy. If a launch buy can never land,
 *      the deployer, and only while the guard is active, may end it early
 *      (`endLaunchGuard`); that is the single thing it can do, and it can only
 *      REMOVE the restriction.
 *
 *      This is NOT launched through ArcadeHook, and that is a requirement
 *      rather than a preference. `setClankerQuote` reverts on
 *      `registeredLaunches[quote]`, so a token created by the launchpad could
 *      never afterwards be set as the pair asset for other launches, which is
 *      the reason this token exists. See docs/ARCADE_TOKEN_LAUNCH.md.
 */
contract ArcadeToken is ERC20, ERC20Permit {
    /// @notice Supply minted at construction. Final: nothing can add to it.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice The pool the launch guard watches. Zero when the guard is unused.
    address public immutable LAUNCH_POOL;
    /// @notice The account that deployed the token, the only one that may end the guard early.
    address public immutable LAUNCH_DEPLOYER;
    /// @notice Number of distinct launch recipients the guard waits for.
    uint256 public immutable GUARD_RECIPIENTS;
    /// @notice Smallest single receipt from the pool that counts as a recipient's launch buy.
    uint256 public immutable GUARD_MIN_RECEIVE;

    /// @notice True while buys from LAUNCH_POOL are restricted. Only ever goes true -> false.
    bool public launchGuardActive;
    /// @notice Launch recipients that have received their launch buy so far.
    uint256 public guardReceived;

    /// @dev keccak256(recipient) => 0 not listed, 1 listed and waiting, 2 received.
    mapping(bytes32 => uint8) private _guardSlot;

    event LaunchGuardClosed(uint256 recipientsReceived, bool endedByDeployer);

    error ZeroAddress();
    error LaunchGuardRestricted();
    error BadGuardConfig();
    error DuplicateRecipient();
    error NotDeployer();
    error GuardInactive();

    constructor(
        string memory name_,
        string memory symbol_,
        address recipient,
        address pool,
        bytes32[] memory recipientHashes,
        uint256 minReceive
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        // A zero recipient would burn the entire supply at construction and
        // leave a token nobody can ever hold. Unrecoverable, so refuse it.
        if (recipient == address(0)) revert ZeroAddress();

        LAUNCH_DEPLOYER = msg.sender;
        LAUNCH_POOL = pool;
        GUARD_MIN_RECEIVE = minReceive;
        GUARD_RECIPIENTS = pool == address(0) ? 0 : recipientHashes.length;

        if (pool != address(0)) {
            if (recipientHashes.length == 0 || minReceive == 0) revert BadGuardConfig();
            for (uint256 i = 0; i < recipientHashes.length; ++i) {
                if (_guardSlot[recipientHashes[i]] != 0) revert DuplicateRecipient();
                _guardSlot[recipientHashes[i]] = 1;
            }
            launchGuardActive = true;
        } else if (recipientHashes.length != 0 || minReceive != 0) {
            revert BadGuardConfig();
        }

        _mint(recipient, TOTAL_SUPPLY);
    }

    /// @notice End the guard before every launch buy has landed. Deployer only,
    ///         only while active, and it can only lift the restriction.
    function endLaunchGuard() external {
        if (msg.sender != LAUNCH_DEPLOYER) revert NotDeployer();
        if (!launchGuardActive) revert GuardInactive();
        launchGuardActive = false;
        emit LaunchGuardClosed(guardReceived, true);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (launchGuardActive && from == LAUNCH_POOL) {
            bytes32 h = keccak256(abi.encodePacked(to));
            uint8 slot = _guardSlot[h];
            if (slot == 0) revert LaunchGuardRestricted();
            if (slot == 1 && value >= GUARD_MIN_RECEIVE) {
                _guardSlot[h] = 2;
                uint256 received = guardReceived + 1;
                guardReceived = received;
                if (received == GUARD_RECIPIENTS) {
                    launchGuardActive = false;
                    emit LaunchGuardClosed(received, false);
                }
            }
        }
        super._update(from, to, value);
    }
}
