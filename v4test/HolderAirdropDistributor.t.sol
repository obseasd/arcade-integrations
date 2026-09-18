// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {HolderAirdropDistributor} from "../v4src/HolderAirdropDistributor.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract HolderAirdropDistributorTest is Test {
    MockUSDC usdc;
    HolderAirdropDistributor dist;

    address constant OWNER = address(0x0ADE);
    address constant KEEPER = address(0x11EE);
    address constant TREASURY = address(0x7EA5);
    address constant FUNDER = address(0xF00D);
    address constant A = address(0xAAA1);
    address constant B = address(0xBBB2);
    address constant LAUNCH = address(0x704E); // a launch token address (key only)

    bytes32 leafA;
    bytes32 leafB;
    bytes32 root;

    function setUp() public {
        usdc = new MockUSDC();
        dist = new HolderAirdropDistributor(OWNER, KEEPER, TREASURY);

        usdc.mint(FUNDER, 1_000e6);
        vm.prank(FUNDER);
        usdc.approve(address(dist), type(uint256).max);

        // Distribution: index0 A=70, index1 B=30. OZ double-hashed leaves,
        // domain-separated by (launchToken, epoch=0).
        leafA = keccak256(bytes.concat(keccak256(abi.encode(LAUNCH, uint256(0), uint256(0), A, uint256(70e6)))));
        leafB = keccak256(bytes.concat(keccak256(abi.encode(LAUNCH, uint256(0), uint256(1), B, uint256(30e6)))));
        root = _hashPair(leafA, leafB);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _proofFor(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _fundAndPost(uint256 fundAmt, uint256 total, uint64 window) internal returns (uint256 epoch) {
        vm.prank(FUNDER);
        dist.fund(LAUNCH, address(usdc), fundAmt);
        vm.prank(KEEPER);
        epoch = dist.postDistribution(LAUNCH, address(usdc), root, total, window);
    }

    function test_fund_creditsAvailable() public {
        vm.prank(FUNDER);
        dist.fund(LAUNCH, address(usdc), 100e6);
        assertEq(dist.available(LAUNCH, address(usdc)), 100e6, "funded");
    }

    function test_post_deductsAndStores() public {
        uint256 epoch = _fundAndPost(100e6, 100e6, 30 days);
        assertEq(epoch, 0);
        assertEq(dist.available(LAUNCH, address(usdc)), 0, "allocated out of available");
        (, bytes32 r, uint256 tot,, , bool swept) = dist.distributions(LAUNCH, 0);
        assertEq(r, root);
        assertEq(tot, 100e6);
        assertFalse(swept);
    }

    function test_post_insufficientFundingReverts() public {
        vm.prank(FUNDER);
        dist.fund(LAUNCH, address(usdc), 50e6);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(HolderAirdropDistributor.InsufficientFunding.selector, 50e6, 100e6));
        dist.postDistribution(LAUNCH, address(usdc), root, 100e6, 30 days);
    }

    function test_post_onlyOperator() public {
        vm.prank(FUNDER);
        dist.fund(LAUNCH, address(usdc), 100e6);
        vm.prank(A);
        vm.expectRevert(HolderAirdropDistributor.NotOperator.selector);
        dist.postDistribution(LAUNCH, address(usdc), root, 100e6, 30 days);
    }

    function test_claim_bothRecipients_thenNoDouble() public {
        _fundAndPost(100e6, 100e6, 30 days);

        dist.claim(LAUNCH, 0, 0, A, 70e6, _proofFor(leafB));
        assertEq(usdc.balanceOf(A), 70e6, "A claimed 70");
        assertTrue(dist.isClaimed(LAUNCH, 0, 0));

        dist.claim(LAUNCH, 0, 1, B, 30e6, _proofFor(leafA));
        assertEq(usdc.balanceOf(B), 30e6, "B claimed 30");

        // double-claim A reverts
        vm.expectRevert(HolderAirdropDistributor.AlreadyClaimed.selector);
        dist.claim(LAUNCH, 0, 0, A, 70e6, _proofFor(leafB));
    }

    function test_claim_wrongAmountReverts() public {
        _fundAndPost(100e6, 100e6, 30 days);
        vm.expectRevert(HolderAirdropDistributor.InvalidProof.selector);
        dist.claim(LAUNCH, 0, 0, A, 99e6, _proofFor(leafB));
    }

    function test_claim_afterDeadlineReverts() public {
        _fundAndPost(100e6, 100e6, 30 days);
        vm.warp(block.timestamp + 30 days + 1);
        vm.expectRevert(HolderAirdropDistributor.ClaimWindowClosed.selector);
        dist.claim(LAUNCH, 0, 0, A, 70e6, _proofFor(leafB));
    }

    function test_claim_afterSweepReverts() public {
        _fundAndPost(100e6, 100e6, 30 days);
        dist.claim(LAUNCH, 0, 0, A, 70e6, _proofFor(leafB)); // A claims in-window
        vm.warp(block.timestamp + 30 days + 1);
        dist.sweep(LAUNCH, 0); // B's 30 forfeited to treasury
        // B can no longer claim the already-forfeited amount (CRITICAL-1).
        vm.expectRevert(HolderAirdropDistributor.AlreadySwept.selector);
        dist.claim(LAUNCH, 0, 1, B, 30e6, _proofFor(leafA));
    }

    function test_claim_oversubscribedRootCappedAtTotal() public {
        // Root pays A=70 + B=50 = 120 but only 100 is posted/collateralized.
        bytes32 la = keccak256(bytes.concat(keccak256(abi.encode(LAUNCH, uint256(0), uint256(0), A, uint256(70e6)))));
        bytes32 lb = keccak256(bytes.concat(keccak256(abi.encode(LAUNCH, uint256(0), uint256(1), B, uint256(50e6)))));
        bytes32 over = _hashPair(la, lb);
        vm.prank(FUNDER);
        dist.fund(LAUNCH, address(usdc), 100e6);
        vm.prank(KEEPER);
        dist.postDistribution(LAUNCH, address(usdc), over, 100e6, 30 days);

        dist.claim(LAUNCH, 0, 0, A, 70e6, _proofFor(lb)); // ok, claimed = 70
        // B's 50 would push claimed to 120 > total 100 -> capped revert.
        vm.expectRevert(abi.encodeWithSelector(HolderAirdropDistributor.InsufficientFunding.selector, 30e6, 50e6));
        dist.claim(LAUNCH, 0, 1, B, 50e6, _proofFor(la));
    }

    function test_sweep_afterDeadlineForfeitsRemainder() public {
        _fundAndPost(100e6, 100e6, 30 days);
        // only A claims; B's 30 is abandoned.
        dist.claim(LAUNCH, 0, 0, A, 70e6, _proofFor(leafB));

        vm.expectRevert(HolderAirdropDistributor.NotEnded.selector);
        dist.sweep(LAUNCH, 0);

        vm.warp(block.timestamp + 30 days + 1);
        uint256 remainder = dist.sweep(LAUNCH, 0);
        assertEq(remainder, 30e6, "unclaimed forfeited");
        assertEq(usdc.balanceOf(TREASURY), 30e6, "treasury got remainder");

        // cannot sweep twice
        vm.expectRevert(HolderAirdropDistributor.AlreadySwept.selector);
        dist.sweep(LAUNCH, 0);
    }

    function test_withdrawUnallocated_ownerOnly() public {
        vm.prank(FUNDER);
        dist.fund(LAUNCH, address(usdc), 100e6);
        // post 60, leaving 40 unallocated
        vm.prank(KEEPER);
        dist.postDistribution(LAUNCH, address(usdc), root, 60e6, 30 days);

        // non-owner cannot withdraw
        vm.prank(A);
        vm.expectRevert(HolderAirdropDistributor.NotOwner.selector);
        dist.withdrawUnallocated(LAUNCH, address(usdc), A, 40e6);

        // owner reclaims the unallocated 40; cannot exceed it (posted funds safe)
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(HolderAirdropDistributor.InsufficientFunding.selector, 40e6, 50e6));
        dist.withdrawUnallocated(LAUNCH, address(usdc), OWNER, 50e6);

        vm.prank(OWNER);
        dist.withdrawUnallocated(LAUNCH, address(usdc), OWNER, 40e6);
        assertEq(usdc.balanceOf(OWNER), 40e6, "owner got unallocated only");
    }
}
