// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CreatorSplitter, SplitterLaunchFactory, IArcadeHookLaunch} from "../v4src/CreatorSplitter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// Reverts on transfer to a designated blocked address (blocklist simulation).
contract MockBlocklistToken is ERC20 {
    address public blocked;
    constructor() ERC20("Block", "BLK") {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
    function setBlocked(address a) external {
        blocked = a;
    }
    function transfer(address to, uint256 amt) public override returns (bool) {
        require(to != blocked, "blocked");
        return super.transfer(to, amt);
    }
}

/// Minimal hook: pulls the creation fee from the caller (the splitter) and
/// records it as `lastCreator`, proving the splitter is `createLaunch`'s sender.
contract MockHook is IArcadeHookLaunch {
    IERC20 public immutable USDC;
    address public immutable TREASURY;
    uint256 public constant CREATION_FEE = 3e6;
    address public lastCreator;
    uint256 public launchCount;

    constructor(address usdc, address treasury) {
        USDC = IERC20(usdc);
        TREASURY = treasury;
    }

    function createLaunch(
        string calldata,
        string calldata,
        string calldata,
        uint8,
        address,
        uint16,
        uint16,
        uint32,
        uint8,
        string calldata,
        uint256,
        uint256,
        uint8
    ) external returns (address tokenAddr, bytes32 poolId) {
        USDC.transferFrom(msg.sender, TREASURY, CREATION_FEE);
        lastCreator = msg.sender;
        launchCount++;
        tokenAddr = address(uint160(uint256(keccak256(abi.encode(msg.sender, launchCount)))));
        poolId = keccak256(abi.encode(tokenAddr));
    }
}

contract CreatorSplitterTest is Test {
    MockUSDC usdc;
    MockHook hook;
    SplitterLaunchFactory factory;

    address constant HUMAN = address(0xA11CE);
    address constant TREASURY = address(0x7EA5);
    address constant A = address(0xAAA1);
    address constant B = address(0xBBB2);

    function setUp() public {
        usdc = new MockUSDC();
        hook = new MockHook(address(usdc), TREASURY);
        factory = new SplitterLaunchFactory(address(hook), address(usdc));

        usdc.mint(HUMAN, 1_000e6);
        vm.prank(HUMAN);
        usdc.approve(address(factory), type(uint256).max);
    }

    function _launch(address[] memory recips, uint16[] memory weights)
        internal
        returns (CreatorSplitter s, address token)
    {
        SplitterLaunchFactory.LaunchParams memory p = SplitterLaunchFactory.LaunchParams({
            name: "Demo",
            symbol: "DEMO",
            metadataURI: "ipfs://x",
            mode: 1, // CLANKER
            snipeStartBps: 0,
            snipeDecaySeconds: 0,
            feeTier: 1,
            startMcapUsdc: 35_000e6
        });
        vm.prank(HUMAN);
        (address splitter, address tk,) = factory.launch(p, recips, weights);
        s = CreatorSplitter(splitter);
        token = tk;
    }

    function _two() internal pure returns (address[] memory r, uint16[] memory w) {
        r = new address[](2);
        w = new uint16[](2);
        r[0] = A;
        w[0] = 7_000;
        r[1] = B;
        w[1] = 3_000;
    }

    function test_factory_launch_splitterIsCreator() public {
        (address[] memory r, uint16[] memory w) = _two();
        (CreatorSplitter s,) = _launch(r, w);

        assertEq(hook.lastCreator(), address(s), "splitter is createLaunch sender (creator)");
        assertTrue(hook.lastCreator() != address(factory), "creator is NOT the factory");
        assertEq(usdc.balanceOf(TREASURY), 3e6, "treasury got the creation fee");
        assertEq(s.owner(), HUMAN, "human owns the splitter");
        assertTrue(s.launched(), "launched flagged");
    }

    function test_distribute_proRata() public {
        (address[] memory r, uint16[] memory w) = _two();
        (CreatorSplitter s,) = _launch(r, w);

        usdc.mint(address(s), 100e6); // simulate accrued creator fees
        s.distribute(address(usdc));

        assertEq(usdc.balanceOf(A), 70e6, "A got 70%");
        assertEq(usdc.balanceOf(B), 30e6, "B got 30%");
        assertEq(usdc.balanceOf(address(s)), 0, "splitter emptied");
    }

    function test_distribute_dustToLastRecipient() public {
        (address[] memory r, uint16[] memory w) = _two();
        (CreatorSplitter s,) = _launch(r, w);

        // 101 wei: A = 101*7000/10000 = 70 (floor), B = remainder = 31.
        usdc.mint(address(s), 101);
        s.distribute(address(usdc));
        assertEq(usdc.balanceOf(A), 70, "A floored share");
        assertEq(usdc.balanceOf(B), 31, "B got the dust remainder");
    }

    function test_distribute_blocklistCreditsPending() public {
        (address[] memory r, uint16[] memory w) = _two();
        MockBlocklistToken blk = new MockBlocklistToken();
        (CreatorSplitter s,) = _launch(r, w);

        blk.setBlocked(B); // B rejects receipt
        blk.mint(address(s), 100e18);
        s.distribute(address(blk));

        assertEq(blk.balanceOf(A), 70e18, "A paid directly");
        assertEq(blk.balanceOf(B), 0, "B push failed");
        assertEq(s.pending(address(blk), B), 30e18, "B credited pending");

        // B unblocks and pulls.
        blk.setBlocked(address(0));
        vm.prank(B);
        s.claimPending(address(blk));
        assertEq(blk.balanceOf(B), 30e18, "B pulled pending");
        assertEq(s.pending(address(blk), B), 0, "pending cleared");
    }

    /// HIGH regression: repeated permissionless distribute() must NOT re-hand-out
    /// a blocked recipient's pending funds. The pending ledger stays fully backed.
    function test_distribute_repeatDoesNotDrainPending() public {
        (address[] memory r, uint16[] memory w) = _two();
        MockBlocklistToken blk = new MockBlocklistToken();
        (CreatorSplitter s,) = _launch(r, w);

        blk.setBlocked(B);
        blk.mint(address(s), 100e18);
        s.distribute(address(blk)); // A=70, pending[B]=30, 30 stays in the splitter
        assertEq(blk.balanceOf(A), 70e18);
        assertEq(s.pending(address(blk), B), 30e18);
        assertEq(s.totalPending(address(blk)), 30e18);

        // Three more permissionless calls with no new fees: all no-ops now.
        s.distribute(address(blk));
        s.distribute(address(blk));
        s.distribute(address(blk));
        assertEq(blk.balanceOf(A), 70e18, "A not over-paid");
        assertEq(s.pending(address(blk), B), 30e18, "B's owed unchanged");
        assertEq(blk.balanceOf(address(s)), 30e18, "backing intact");

        // B unblocks and pulls its full 30 (solvent).
        blk.setBlocked(address(0));
        vm.prank(B);
        s.claimPending(address(blk));
        assertEq(blk.balanceOf(B), 30e18, "B fully paid");
        assertEq(s.totalPending(address(blk)), 0);
    }

    function test_setRecipients_onlyOwnerAndValid() public {
        (address[] memory r, uint16[] memory w) = _two();
        (CreatorSplitter s,) = _launch(r, w);

        // non-owner
        vm.prank(B);
        vm.expectRevert(CreatorSplitter.NotOwner.selector);
        s.setRecipients(r, w);

        // weights must sum to 10_000
        uint16[] memory bad = new uint16[](2);
        bad[0] = 5_000;
        bad[1] = 4_000;
        vm.prank(HUMAN);
        vm.expectRevert(CreatorSplitter.BadWeights.selector);
        s.setRecipients(r, bad);

        // valid reweight then distribute reflects it
        uint16[] memory w2 = new uint16[](2);
        w2[0] = 5_000;
        w2[1] = 5_000;
        vm.prank(HUMAN);
        s.setRecipients(r, w2);
        usdc.mint(address(s), 100e6);
        s.distribute(address(usdc));
        assertEq(usdc.balanceOf(A), 50e6, "A 50%");
        assertEq(usdc.balanceOf(B), 50e6, "B 50%");
    }

    function test_ownership_twoStepTransfer() public {
        (address[] memory r, uint16[] memory w) = _two();
        (CreatorSplitter s,) = _launch(r, w);

        vm.prank(HUMAN);
        s.transferOwnership(B);
        assertEq(s.owner(), HUMAN, "owner unchanged until accepted");

        // wrong acceptor
        vm.prank(A);
        vm.expectRevert(CreatorSplitter.NotOwner.selector);
        s.acceptOwnership();

        vm.prank(B);
        s.acceptOwnership();
        assertEq(s.owner(), B, "ownership handed over");
    }

    function test_launch_onlyFactoryAndOnce() public {
        (address[] memory r, uint16[] memory w) = _two();
        (CreatorSplitter s,) = _launch(r, w);

        // A random caller cannot re-launch (and it's already launched anyway).
        vm.expectRevert(CreatorSplitter.NotFactory.selector);
        s.launch("X", "X", "", 1, 0, 0, 1, 35_000e6);
    }
}
