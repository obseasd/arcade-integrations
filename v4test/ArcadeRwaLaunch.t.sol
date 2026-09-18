// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArcadeHook} from "../v4src/ArcadeHook.sol";
import {ArcadeDividendDistributor} from "../v4src/ArcadeDividendDistributor.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A 6-decimal quote asset mock (USYC-like) for the RWA launch tests. Plain
///      ERC20: no permission gate, so the distributor/treasury can hold it freely
///      (the MED-1/MED-2 permissioned-quote cases are separate tests).
contract MockQuote6 is ERC20 {
    constructor() ERC20("USYC Mock", "mUSYC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal Twitter-escrow mock: records the credited amount per position.
contract MockEscrow {
    mapping(uint256 => uint256) public credited;

    function creditSlot(uint256 positionId, uint256, address, uint256 amount) external {
        credited[positionId] += amount;
    }
}

/**
 * @title ArcadeRwaLaunchTest
 * @notice End-to-end coverage for the RWA launch mode (mode 3): a direct
 *         single-sided launch paired against an allowlisted 6-dp quote, charging a
 *         creator-set tax split platform/creator/holders, with the holders bucket
 *         funding the dividend distributor. Exercises createRwaLaunch + the seed +
 *         the always-quote swap accrual + a holder claim, which no other test hits.
 */
contract ArcadeRwaLaunchTest is Test {
    PoolManager pm;
    ArcadeHook hook;
    ArcadeDividendDistributor dist;
    TestERC20 usdc;
    MockQuote6 quote;
    PoolSwapTest swapRouter;

    address constant LOCKED_VAULT = address(0xCAFE);
    address constant TREASURY = address(0xBEEF);
    address constant ESCROW = address(0xE5C);
    address constant OWNER = address(0x0123);
    address constant CREATOR = address(0xC0FFEE);
    address constant BUYER1 = address(0xB1);
    address constant BUYER2 = address(0xB2);
    address constant SINK = address(0x51);

    uint160 internal constant TARGET_FLAGS = uint160(0x3ECE);

    function setUp() public {
        pm = new PoolManager(address(this));
        usdc = new TestERC20(0);
        quote = new MockQuote6();

        address hookAddr = address(uint160(0xBEEF0000 | TARGET_FLAGS));
        deployCodeTo(
            "ArcadeHook.sol:ArcadeHook",
            abi.encode(IPoolManager(address(pm)), Currency.wrap(address(usdc)), LOCKED_VAULT, TREASURY, ESCROW, OWNER),
            hookAddr
        );
        hook = ArcadeHook(hookAddr);

        // Distributor: owner = OWNER, hook = the hook, treasury = TREASURY (== the
        // hook's treasury, per go-live invariant LOW-1).
        dist = new ArcadeDividendDistributor(OWNER, hookAddr, TREASURY);

        vm.startPrank(OWNER);
        hook.setClankerBuyCap(0, 0);
        hook.setDividendDistributor(address(dist));
        hook.setRwaQuoteAllowed(address(quote), true);
        hook.setRwaGraveyardSink(SINK);
        vm.stopPrank();

        swapRouter = new PoolSwapTest(pm);

        // Creator funds the 3-USDC creation fee.
        usdc.mint(CREATOR, 1_000e6);
        vm.prank(CREATOR);
        usdc.approve(address(hook), type(uint256).max);
    }

    // taxBps=200 (2%): platform=min(100,100)=100 (1%), remainder=100, holders=60
    // (0.6%), creator=40 (0.4%). Start mcap default (35k).
    function _launchRwa() internal returns (address tokenAddr, PoolKey memory key) {
        vm.prank(CREATOR);
        (tokenAddr,) = hook.createRwaLaunch("RwaTok", "RWA", "ipfs://rwa", address(quote), 200, 60, 0, 0, "", address(0), 0);
        key = _buildKey(tokenAddr);
    }

    function _buildKey(address token) internal view returns (PoolKey memory) {
        address q = address(quote);
        (Currency c0, Currency c1) =
            q < token ? (Currency.wrap(q), Currency.wrap(token)) : (Currency.wrap(token), Currency.wrap(q));
        // The RWA pool carries the tax as its native LP fee (not 0) -- read it from
        // the hook so the key matches the real pool.
        return PoolKey({currency0: c0, currency1: c1, fee: hook.poolFeeOf(token), tickSpacing: 200, hooks: IHooks(address(hook))});
    }

    /// A buy: quote -> token exact-in via the V4 router.
    function _buyRwa(PoolKey memory key, address trader, uint256 quoteIn) internal returns (BalanceDelta delta) {
        quote.mint(trader, quoteIn);
        vm.startPrank(trader);
        quote.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote); // quote -> token
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(quoteIn), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// A sell: token -> quote exact-in via the V4 router (generates token-side fees).
    function _sellRwa(PoolKey memory key, address token, address trader, uint256 tokenIn) internal {
        vm.startPrank(trader);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == token; // token -> quote
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Launch + seed
    // ------------------------------------------------------------------

    function test_createRwaLaunch_registersSeedsAndStoresConfig() public {
        (address tokenAddr, PoolKey memory key) = _launchRwa();

        assertTrue(hook.registeredLaunches(tokenAddr), "token registered");
        assertEq(usdc.balanceOf(TREASURY), 3e6, "3 USDC creation fee pulled");

        ArcadeHook.CurveState memory s = hook.getCurveState(key.toId());
        assertEq(uint256(s.mode), 3, "mode = RWA");
        assertEq(uint256(s.status), 2, "status = Graduated");
        assertEq(s.creator, CREATOR, "creator recorded");

        // The full supply was seeded into the pool (held by the PoolManager),
        // minus a tiny single-sided-seed rounding dust left in the hook.
        assertApproxEqAbs(
            IERC20(tokenAddr).balanceOf(address(pm)), 1_000_000_000e18, 1e18, "~full supply seeded to pool"
        );
        assertEq(IERC20(tokenAddr).balanceOf(CREATOR), 0, "creator holds nothing (no dev-buy)");

        // Distributor registered this launch against the quote.
        (address lt, address qa,,,,) = dist.config(tokenAddr);
        assertEq(lt, tokenAddr, "distributor knows the token");
        assertEq(qa, address(quote), "distributor quote = the RWA quote");
    }

    function test_createRwaLaunch_revertsOnBadTax() public {
        vm.startPrank(CREATOR);
        vm.expectRevert(); // InvalidTax: below 1%
        hook.createRwaLaunch("T", "T", "u", address(quote), 50, 25, 0, 0, "", address(0), 0);
        vm.expectRevert(); // InvalidTax: above 3%
        hook.createRwaLaunch("T", "T", "u", address(quote), 400, 200, 0, 0, "", address(0), 0);
        vm.expectRevert(); // InvalidTax: holders exceeds the creator-controlled remainder
        hook.createRwaLaunch("T", "T", "u", address(quote), 200, 150, 0, 0, "", address(0), 0);
        vm.stopPrank();
    }

    function test_createRwaLaunch_allowsZeroHolders() public {
        // 0% to holders is valid (dividends off / plain creator-fee launch).
        vm.prank(CREATOR);
        (address tokenAddr,) = hook.createRwaLaunch("T", "T", "u", address(quote), 200, 0, 0, 0, "", address(0), 0);
        assertTrue(hook.registeredLaunches(tokenAddr), "launch with 0% holders succeeds");
    }

    function test_createRwaLaunch_revertsOnUnallowedQuote() public {
        MockQuote6 other = new MockQuote6();
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.QuoteNotAllowed.selector);
        hook.createRwaLaunch("T", "T", "u", address(other), 200, 60, 0, 0, "", address(0), 0);
    }

    function test_rwaDevBuy_deliversToCreatorBoundedTenPct() public {
        quote.mint(CREATOR, 100_000e6);
        vm.startPrank(CREATOR);
        quote.approve(address(hook), type(uint256).max);
        // Atomic dev-buy of 1,000 USYC (quote) in the same tx as the launch.
        (address tokenAddr,) = hook.createRwaLaunch("Rwa", "RWA", "u", address(quote), 200, 60, 0, 1_000e6, "", address(0), 0);
        vm.stopPrank();
        uint256 bag = IERC20(tokenAddr).balanceOf(CREATOR);
        assertGt(bag, 0, "creator received the dev-buy tokens");
        assertLe(bag, 1_000_000_000e18 / 10, "dev-buy <= 10% of supply");
    }

    function test_rwaDevBuy_revertsOverTenPct() public {
        quote.mint(CREATOR, 1_000_000e6);
        vm.startPrank(CREATOR);
        quote.approve(address(hook), type(uint256).max);
        // A dev-buy delivering > 10% of supply reverts the whole launch.
        vm.expectRevert();
        hook.createRwaLaunch("Rwa", "RWA", "u", address(quote), 200, 60, 0, 5_000e6, "", address(0), 0);
        vm.stopPrank();
    }

    function test_rwaBuy_perTxAntiSniperRampCapsEarlyBuy() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300); // enable the per-tx ramp (RWA setUp disabled it)
        (address tokenAddr, PoolKey memory key) = _launchRwa();
        tokenAddr; // silence unused

        // Minute 0: cap = 1% of supply. A buy delivering > 1% reverts.
        quote.mint(BUYER1, 10_000e6);
        vm.startPrank(BUYER1);
        quote.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(uint256(10_000e6)), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // After the 5-minute window: uncapped, the big buy succeeds.
        vm.warp(block.timestamp + 301);
        _buyRwa(key, BUYER1, 10_000e6);
    }

    // ------------------------------------------------------------------
    // Swap accrual + holder claim
    // ------------------------------------------------------------------

    function test_rwaHarvest_accruesDividendsToHoldersAndClaims() public {
        (address tokenAddr, PoolKey memory key) = _launchRwa();

        // Trades accrue the tax into the locked position (quote from buys). A sell
        // adds token-side fees, exercising the harvest's token->quote conversion.
        _buyRwa(key, BUYER1, 2_000e6);
        _buyRwa(key, BUYER2, 1_000e6);
        _sellRwa(key, tokenAddr, BUYER1, IERC20(tokenAddr).balanceOf(BUYER1) / 4); // buyer1 still holds most

        uint256 treasuryBefore = quote.balanceOf(TREASURY);
        uint256 creatorBefore = quote.balanceOf(CREATOR);
        uint256 distBefore = quote.balanceOf(address(dist));

        // Permissionless harvest: collect the position fees, convert token->quote,
        // split 3-way, accrue the holders bucket to the distributor.
        hook.harvestRwaFees(tokenAddr);

        assertGt(quote.balanceOf(TREASURY) - treasuryBefore, 0, "treasury got the platform cut (quote)");
        assertGt(quote.balanceOf(CREATOR) - creatorBefore, 0, "creator got the creator cut (quote)");
        assertGt(quote.balanceOf(address(dist)) - distBefore, 0, "distributor got the holders bucket (quote)");
        assertEq(IERC20(tokenAddr).balanceOf(address(dist)), 0, "distributor holds no launch token (always-quote)");

        // buyer1 (a holder at harvest time) has claimable dividends in QUOTE.
        uint256 claimable = dist.claimable(tokenAddr, BUYER1);
        assertGt(claimable, 0, "buyer1 has claimable dividends");

        uint256 b1QuoteBefore = quote.balanceOf(BUYER1);
        vm.prank(BUYER1);
        dist.claim(tokenAddr);
        assertEq(quote.balanceOf(BUYER1) - b1QuoteBefore, claimable, "buyer1 claimed exactly the accrued quote");
        assertEq(dist.claimable(tokenAddr, BUYER1), 0, "nothing left to claim");
    }

    function test_rwaBuy_swapsSucceedWithNativeFee() public {
        (address tokenAddr, PoolKey memory key) = _launchRwa();
        // V2 pivot: the tax is the pool's NATIVE LP fee (no hook take), so buys and
        // sells succeed on the single-sided pool (V1's per-swap pm.take reverted
        // here). The fee accrues into the locked position, collected later by
        // harvestRwaFees; the distributor is not funded until a harvest runs.
        _buyRwa(key, BUYER1, 1_000e6);
        assertGt(IERC20(tokenAddr).balanceOf(BUYER1), 0, "buyer1 received tokens");
        _buyRwa(key, BUYER2, 1_000e6);
        assertGt(IERC20(tokenAddr).balanceOf(BUYER2), 0, "buyer2 received tokens");
        assertEq(quote.balanceOf(address(dist)), 0, "no dividends until a harvest runs");
    }

    /// A dumped pool (thin quote depth) can make the harvest's token->quote
    /// conversion PARTIAL-FILL. The M-1 fix settles the token residual pull-safe so
    /// the harvest never bricks (before the fix this reverted CurrencyNotSettled);
    /// RWA system audit MEDIUM-1 routes that residual to the dividend-EXCLUDED SINK,
    /// never the rotatable treasury (a treasury rotation would else desync S).
    function test_rwaHarvest_survivesDumpedPool() public {
        (address tokenAddr, PoolKey memory key) = _launchRwa();
        _buyRwa(key, BUYER1, 5_000e6);
        uint256 sinkTokenBefore = IERC20(tokenAddr).balanceOf(SINK);
        // Dump ~99% back -> drains quote depth and accrues token-side fees.
        _sellRwa(key, tokenAddr, BUYER1, (IERC20(tokenAddr).balanceOf(BUYER1) * 99) / 100);
        // Must not revert even if the conversion swap partial-fills.
        hook.harvestRwaFees(tokenAddr);
        assertGt(quote.balanceOf(TREASURY), 3e6, "treasury received fees beyond the creation fee");
        // The launch token NEVER lands at the treasury; any partial-fill residual
        // goes to the excluded sink (or nothing, on a full fill).
        assertEq(IERC20(tokenAddr).balanceOf(TREASURY), 0, "treasury holds no launch token");
        assertGe(IERC20(tokenAddr).balanceOf(SINK), sinkTokenBefore, "residual (if any) -> sink");
    }

    function test_rwaTwitterEscrow_routesCreatorCutToEscrow() public {
        MockEscrow escrow = new MockEscrow();
        vm.prank(OWNER);
        hook.setTwitterEscrow(address(escrow));
        // Launch with a @handle -> the creator's quote cut routes to the escrow slot.
        vm.prank(CREATOR);
        (address tokenAddr, PoolId poolId) =
            hook.createRwaLaunch("Rwa", "RWA", "u", address(quote), 200, 60, 0, 0, "myhandle", address(0), 0);
        PoolKey memory key = _buildKey(tokenAddr);
        _buyRwa(key, BUYER1, 2_000e6);
        _buyRwa(key, BUYER2, 1_000e6);
        hook.harvestRwaFees(tokenAddr);
        assertGt(escrow.credited(uint256(PoolId.unwrap(poolId))), 0, "escrow slot credited the creator cut");
        assertGt(quote.balanceOf(address(escrow)), 0, "escrow holds the creator's quote (USYC)");
    }

    function test_rwaCreator2_routesCreatorCutToAltWallet() public {
        address alt = address(0xA17);
        // "Another wallet": route 100% of the creator cut to `alt`, no @handle.
        vm.prank(CREATOR);
        (address tokenAddr,) =
            hook.createRwaLaunch("Rwa", "RWA", "u", address(quote), 200, 60, 0, 0, "", alt, 10_000);
        PoolKey memory key = _buildKey(tokenAddr);
        _buyRwa(key, BUYER1, 2_000e6);
        _buyRwa(key, BUYER2, 1_000e6);
        uint256 altBefore = quote.balanceOf(alt);
        uint256 creatorBefore = quote.balanceOf(CREATOR);
        hook.harvestRwaFees(tokenAddr);
        // 100% of the creator cut went to the alternate wallet; the creator got none.
        assertGt(quote.balanceOf(alt) - altBefore, 0, "alt wallet received the creator cut (USYC)");
        assertEq(quote.balanceOf(CREATOR) - creatorBefore, 0, "creator received nothing (100% to alt)");
    }

    function test_rwaLaunch_collectFeesReverts() public {
        (address tokenAddr,) = _launchRwa();
        // collectFees must REJECT RWA (its fees go through harvestRwaFees's 3-way
        // split, not the CLANKER 80/20 collect) -- else the holders' dividend share
        // would be diverted to the creator (audit HIGH-1).
        vm.expectRevert(ArcadeHook.InvalidMode.selector);
        hook.collectFees(tokenAddr);
    }

    // ------------------------------------------------------------------
    // Graveyard: a dead RWA pool's LP is swept, launch token -> the sink
    // ------------------------------------------------------------------

    function test_rwaGraveyard_sweepsTokenToSink() public {
        (address tokenAddr,) = _launchRwa();
        // No trades; warp past the graveyard period (365d default) -> the pool is dead.
        vm.warp(block.timestamp + 366 days);
        uint256 sinkBefore = IERC20(tokenAddr).balanceOf(SINK);
        hook.graveyardSweep(tokenAddr);
        // The swept single-sided launch tokens go to the permanent sink, not the
        // treasury (so they never pollute the dividend share base).
        assertGt(IERC20(tokenAddr).balanceOf(SINK) - sinkBefore, 0, "swept launch token -> sink");
    }

    function test_rwaGraveyard_revertsBeforeDead() public {
        (address tokenAddr,) = _launchRwa();
        vm.expectRevert(ArcadeHook.NotDead.selector);
        hook.graveyardSweep(tokenAddr);
    }
}
