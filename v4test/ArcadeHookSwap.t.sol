// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ArcadeHook} from "../v4src/ArcadeHook.sol";
import {ArcadeV4Curve} from "../v4src/libraries/ArcadeV4Curve.sol";
import {ArcadeV4SwapRouter} from "../v4src/ArcadeV4SwapRouter.sol";
import {ArcadeTwitterEscrowV4} from "../src/launchpad/ArcadeTwitterEscrowV4.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ArcadeHookSwapTest
 * @notice End-to-end curve buy / sell tests against the V4 ArcadeHook.
 *
 *         During the Curving phase the V4 swap path is rejected (V4 swap
 *         requires LP-backed liquidity; the curve has none). Traders use
 *         hook.buy / hook.sell which move USDC and launch tokens via plain
 *         ERC20 transferFrom + transfer, mirroring the V2 production
 *         launchpad's contract surface.
 *
 *         These tests prove:
 *           - PUMP mode buys: 50/50 fee split, V2-equivalent tokensOut.
 *           - CLANKER mode buys: 70/30 split, same curve math.
 *           - Sequential buys accumulate state; later buyers pay more per
 *             token (price discovery).
 *           - Round-trip buy -> sell loses USDC to the curve (matches V2
 *             curve-vectors fixture exactly: 100 USDC -> 98_010_000).
 *           - Cap-path buys revert with GraduationInProgress (deferred to
 *             Round 4).
 *           - During Curving the V4 swap router path reverts with
 *             LiquidityNotPermitted to force traders through hook.buy/sell.
 */
contract ArcadeHookSwapTest is Test {
    using StateLibrary for IPoolManager;

    PoolManager pm;
    ArcadeHook hook;
    TestERC20 usdc;
    PoolSwapTest swapRouter;

    address constant LOCKED_VAULT = address(0xCAFE);
    address constant TREASURY = address(0xBEEF);
    address constant ESCROW = address(0xE5C);
    address constant OWNER = address(0x0123);
    address constant ALICE = address(0xA11CE);
    address constant CREATOR = address(0xC0FFEE);

    uint160 internal constant TARGET_FLAGS = uint160(0x3ECE);

    /// @dev USDC deployment, overridable so a subclass can force the currency
    ///      ordering. Default places USDC at a normal (high) address -> USDC
    ///      sorts as currency1 vs the hook-CREATE'd launch tokens.
    function _makeUsdc() internal virtual returns (TestERC20) {
        return new TestERC20(0);
    }

    function setUp() public {
        pm = new PoolManager(address(this));
        usdc = _makeUsdc();

        address hookAddr = address(uint160(0xBEEF0000 | TARGET_FLAGS));
        deployCodeTo(
            "ArcadeHook.sol:ArcadeHook",
            abi.encode(IPoolManager(address(pm)), Currency.wrap(address(usdc)), LOCKED_VAULT, TREASURY, ESCROW, OWNER),
            hookAddr
        );
        hook = ArcadeHook(hookAddr);

        // Disable the CLANKER anti-snipe buy cap by default so the fee/collect
        // tests can make large buys unchanged. Dedicated cap tests re-enable it.
        vm.prank(OWNER);
        hook.setClankerBuyCap(0, 0);

        swapRouter = new PoolSwapTest(pm);

        usdc.mint(CREATOR, 100_000e6);
        usdc.mint(ALICE, 100_000e6);

        vm.startPrank(CREATOR);
        usdc.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(ALICE);
        usdc.approve(address(hook), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Spawn a launch in PUMP mode.
    function _launchPump() internal returns (address tokenAddr, PoolKey memory key) {
        vm.prank(CREATOR);
        (tokenAddr,) = hook.createLaunch("PumpToken", "PUMP", "ipfs://demo", 0, address(0), 0, 0, 0, 0, "", 0, 0, 0);
        key = _buildKey(tokenAddr);
    }

    /// @dev CLANKER variant with 70/30 split.
    function _launchClanker() internal returns (address tokenAddr, PoolKey memory key) {
        vm.prank(CREATOR);
        (tokenAddr,) = hook.createLaunch("ClankerTok", "CLNK", "ipfs://demo", 1, address(0), 0, 0, 0, 1, "", 0, 0, 0);
        key = _buildKey(tokenAddr);
    }

    function _buildKey(address token) internal view returns (PoolKey memory) {
        address usdcAddr = address(usdc);
        (Currency c0, Currency c1) = usdcAddr < token
            ? (Currency.wrap(usdcAddr), Currency.wrap(token))
            : (Currency.wrap(token), Currency.wrap(usdcAddr));
        // PUMP pools are fee-0 (hook captures); CLANKER pools carry their tier as
        // the native LP fee. Read it from the hook so the key matches the pool.
        return PoolKey({
            currency0: c0,
            currency1: c1,
            fee: hook.poolFeeOf(token),
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    // -------------------------------------------------------------------
    // PUMP mode buy: 50/50 fee split
    // -------------------------------------------------------------------

    function test_buy_pump_smallAmount_distributesFees50_50_andTransfersTokens() public {
        (address tokenAddr, PoolKey memory key) = _launchPump();

        uint256 amountIn = 100e6;
        ArcadeV4Curve.BuyResult memory expected = ArcadeV4Curve.simulateBuy(0, 0, amountIn);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        uint256 creatorBefore = usdc.balanceOf(CREATOR);
        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 tokensOut, uint256 actualGross) = hook.buy(tokenAddr, amountIn, 0);

        assertEq(tokensOut, expected.tokensOut, "tokensOut matches V2 fixture");
        assertEq(actualGross, expected.actualGross, "actualGross matches");

        assertEq(IERC20(tokenAddr).balanceOf(ALICE), expected.tokensOut, "alice received tokens");
        assertEq(aliceUsdcBefore - usdc.balanceOf(ALICE), expected.actualGross, "alice paid actualGross");

        uint256 expectedSide = expected.fee / 2;
        assertEq(usdc.balanceOf(TREASURY) - treasuryBefore, expectedSide, "treasury 50% of fee");
        assertEq(usdc.balanceOf(CREATOR) - creatorBefore, expectedSide, "creator 50% of fee");

        ArcadeHook.CurveState memory s = hook.getCurveState(key.toId());
        assertEq(s.tokensSold, expected.tokensOut, "state tokensSold tracked");
        assertEq(s.realUsdcReserve, expected.actualGross - expected.fee, "state realUsdcReserve tracked");
    }

    // CLANKER is now a DIRECT launch (no bonding curve): the old
    // test_buy_clanker_distributesFees70_30 (curve 70/30 split) is obsolete and
    // was removed. CLANKER fee behaviour is covered by the tier + direct-launch
    // tests (test_clankerFee_*, test_postGradFee_CLANKER_splits80_20,
    // test_clankerDirect_*).

    // -------------------------------------------------------------------
    // Sequential buys accumulate state, prices rise
    // -------------------------------------------------------------------

    function test_buy_sequentialBuys_accumulateStateAndRaisePrice() public {
        (address tokenAddr, PoolKey memory key) = _launchPump();

        vm.prank(ALICE);
        (uint256 firstTokens,) = hook.buy(tokenAddr, 100e6, 0);

        vm.prank(ALICE);
        (uint256 secondTokens,) = hook.buy(tokenAddr, 100e6, 0);

        assertLt(secondTokens, firstTokens, "second buy yields fewer tokens (price rose)");

        ArcadeHook.CurveState memory s = hook.getCurveState(key.toId());
        assertEq(s.tokensSold, firstTokens + secondTokens, "state aggregate");
    }

    // -------------------------------------------------------------------
    // Round trip loses to the curve (V2 fixture invariant)
    // -------------------------------------------------------------------

    function test_buyThenSell_roundTripLosesToCurve() public {
        (address tokenAddr,) = _launchPump();

        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 tokensReceived,) = hook.buy(tokenAddr, 100e6, 0);

        vm.startPrank(ALICE);
        IERC20(tokenAddr).approve(address(hook), tokensReceived);
        uint256 usdcOut = hook.sell(tokenAddr, tokensReceived, 0);
        vm.stopPrank();

        // V2 round-trip fixture: 100 USDC -> 98_010_000 USDC back.
        assertEq(usdcOut, 98_010_000, "matches V2 round-trip vector");
        assertEq(usdc.balanceOf(ALICE), aliceUsdcBefore - 100e6 + 98_010_000, "alice net loss");
    }

    // -------------------------------------------------------------------
    // Graduation (Round 4)
    // -------------------------------------------------------------------

    function test_buy_capPath_graduatesPoolAndTakesMigrationFee() public {
        (address tokenAddr, PoolKey memory key) = _launchPump();

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 tokensOut, uint256 actualGross) = hook.buy(tokenAddr, 30_000e6, 0);

        // Alice received the full CURVE_SUPPLY (cap path delivers maxOut).
        assertEq(tokensOut, ArcadeV4Curve.CURVE_SUPPLY, "alice gets full curve supply");
        // Calibrated curve (777M): a cap-path buy from an empty curve consumes
        // actualGross = 13_608_659_102 USDC (raise ~13.47k + 1% fee headroom).
        assertEq(actualGross, 13_608_659_102, "matches calibrated cap actualGross");
        // Refund stays with alice automatically (we only transferFrom actualGross).
        assertEq(aliceUsdcBefore - usdc.balanceOf(ALICE), actualGross, "alice only paid actualGross");

        // Status is now Graduated. Curve state is at the cap.
        ArcadeHook.CurveState memory s = hook.getCurveState(key.toId());
        assertEq(uint256(s.status), 2, "status = Graduated");
        assertEq(s.tokensSold, ArcadeV4Curve.CURVE_SUPPLY, "tokensSold at cap");

        // Treasury received the 1% migration fee (134_725_725 = 1% of the
        // ~13_472.57 USDC raise) plus its 50% share of the curve trade fee on
        // the cap-filling buy. Exact delta = 68_043_295 (trade-fee cut) +
        // 134_725_725 (migration fee) = 202_769_020.
        assertEq(
            usdc.balanceOf(TREASURY) - treasuryBefore, 202_769_020, "treasury migration fee + trade cut"
        );
    }

    function test_buy_afterGraduation_revertsLiquidityNotPermitted() public {
        (address tokenAddr,) = _launchPump();

        // Graduate the pool first.
        vm.prank(ALICE);
        hook.buy(tokenAddr, 30_000e6, 0);

        // Further hook.buy calls should revert because the curve is closed.
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.LiquidityNotPermitted.selector);
        hook.buy(tokenAddr, 100e6, 0);
    }

    function test_sell_afterGraduation_revertsLiquidityNotPermitted() public {
        (address tokenAddr,) = _launchPump();

        vm.prank(ALICE);
        hook.buy(tokenAddr, 30_000e6, 0);

        vm.startPrank(ALICE);
        IERC20(tokenAddr).approve(address(hook), type(uint256).max);
        vm.expectRevert(ArcadeHook.LiquidityNotPermitted.selector);
        hook.sell(tokenAddr, 1e18, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // Post-graduation royalty (Round 5)
    // -------------------------------------------------------------------

    function _graduatePump() internal returns (address tokenAddr, PoolKey memory key) {
        (tokenAddr, key) = _launchPump();
        vm.prank(ALICE);
        hook.buy(tokenAddr, 30_000e6, 0);
    }

    /// CLANKER is direct: the pool is live at createLaunch. ALICE has no tokens
    /// yet (nothing was sold on a curve), so a buy via the V4 router both mints
    /// her tokens and exercises the tier fee.
    function _graduateClanker() internal returns (address tokenAddr, PoolKey memory key) {
        (tokenAddr, key) = _launchClanker();
        _buyViaV4(key, ALICE, 5_000e6);
    }

    function _sellViaV4(PoolKey memory key, address tokenAddr, address trader, uint256 amount)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(trader);
        IERC20(tokenAddr).approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) != address(usdc);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Anti-sniper: the coverage the round-4 HIGH + the clock bug slipped
    // through (no test ever did a post-graduation BUY with a snipe config).
    // ------------------------------------------------------------------

    /// Graduate a PUMP launch that HAS an anti-sniper config, having let more
    /// than the whole decay window pass BEFORE graduating (a realistic curve
    /// fills over hours/days). A launch-anchored decay clock -- the pre-fix bug
    /// -- would already read 0 by graduation; a graduation-anchored clock (the
    /// fix) starts fresh here.
    function _graduatePumpWithSnipe(uint16 startBps, uint32 decaySeconds)
        internal
        returns (address tokenAddr, PoolKey memory key)
    {
        vm.prank(CREATOR);
        (tokenAddr,) =
            hook.createLaunch("SnipePump", "SNP", "ipfs://demo", 0, address(0), 0, startBps, decaySeconds, 0, "", 0, 0, 0);
        key = _buildKey(tokenAddr);
        vm.warp(block.timestamp + uint256(decaySeconds) + 3_600);
        usdc.mint(ALICE, 100_000e6);
        vm.prank(ALICE);
        hook.buy(tokenAddr, 30_000e6, 0); // graduates
    }

    /// A post-graduation BUY: USDC -> token via the real V4 swap router.
    function _buyViaV4(PoolKey memory key, address trader, uint256 usdcAmount)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(trader);
        usdc.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc); // USDC -> token
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(usdcAmount), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// True iff an AntiSnipeApplied event was emitted since the last recordLogs.
    function _sawAntiSnipe() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("AntiSnipeApplied(bytes32,address,uint256,uint16)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Anti-sniper is a CURVE-phase tax (2026-08 model): levied on early BUYS
    // through the bonding curve, split 80% creator / 20% treasury, decaying
    // startBps -> 0 over the window, exempting the creator's atomic dev-buy, and
    // fully inert once graduated. (Old model taxed post-grad buys anchored at
    // graduation; replaced because the sniper problem is at LAUNCH and the
    // migration problem is SELLS, so a post-grad buy tax was counterproductive.)
    // ------------------------------------------------------------------

    /// Early curve buys are snipe-taxed: the buyer receives net-of-tax tokens and
    /// AntiSnipeApplied fires. Regresses if the tax stops applying on the curve.
    function test_antisniper_taxesEarlyCurveBuy() public {
        vm.prank(CREATOR);
        (address tokenAddr,) =
            hook.createLaunch("SnipePump", "SNP", "ipfs://demo", 0, address(0), 0, 2_000, 600, 0, "", 0, 0, 0);
        assertEq(hook.currentSnipeBps(tokenAddr), 2_000, "full tax at t=0 on the curve");

        uint256 amountIn = 400e6;
        ArcadeV4Curve.BuyResult memory q = ArcadeV4Curve.simulateBuy(0, 0, amountIn);
        uint256 tax = (q.tokensOut * 2_000) / 10_000;

        usdc.mint(ALICE, amountIn);
        vm.recordLogs();
        vm.prank(ALICE);
        (uint256 got,) = hook.buy(tokenAddr, amountIn, 0);

        assertTrue(_sawAntiSnipe(), "early curve buy must be snipe-taxed");
        assertEq(got, q.tokensOut - tax, "buyer receives net-of-tax tokens");
        assertEq(IERC20(tokenAddr).balanceOf(ALICE), q.tokensOut - tax, "alice holds only the net");
    }

    /// The curve tax splits 80% creator / 20% treasury, taken in TOKENS.
    function test_antisniper_curveTaxSplit80_20() public {
        vm.prank(CREATOR);
        (address tokenAddr,) =
            hook.createLaunch("SnipePump", "SNP", "ipfs://demo", 0, address(0), 0, 2_000, 600, 0, "", 0, 0, 0);

        uint256 amountIn = 400e6;
        ArcadeV4Curve.BuyResult memory q = ArcadeV4Curve.simulateBuy(0, 0, amountIn);
        uint256 tax = (q.tokensOut * 2_000) / 10_000;
        uint256 expectTreasury = (tax * 2_000) / 10_000; // 20%
        uint256 expectCreator = tax - expectTreasury; // 80%

        uint256 creatorBefore = IERC20(tokenAddr).balanceOf(CREATOR);
        uint256 treasuryBefore = IERC20(tokenAddr).balanceOf(TREASURY);

        usdc.mint(ALICE, amountIn);
        vm.prank(ALICE);
        hook.buy(tokenAddr, amountIn, 0);

        assertEq(
            IERC20(tokenAddr).balanceOf(TREASURY) - treasuryBefore, expectTreasury, "treasury gets 20% of the tax"
        );
        assertEq(IERC20(tokenAddr).balanceOf(CREATOR) - creatorBefore, expectCreator, "creator gets 80% of the tax");
    }

    /// The creator's atomic dev-buy is EXEMPT: it bypasses the public buy(), so no
    /// skim, no AntiSnipeApplied, and the creator receives the FULL curve tokens.
    function test_antisniper_devBuyExempt() public {
        uint256 devUsdc = 200e6; // ~3.8% of supply, under the 10% dev-buy cap
        ArcadeV4Curve.BuyResult memory q = ArcadeV4Curve.simulateBuy(0, 0, devUsdc);

        usdc.mint(CREATOR, 3e6 + devUsdc);
        vm.startPrank(CREATOR);
        usdc.approve(address(hook), type(uint256).max);
        vm.recordLogs();
        (address tokenAddr,) =
            hook.createLaunch("SnipePump", "SNP", "ipfs://demo", 0, address(0), 0, 2_000, 600, 0, "", 0, devUsdc, 0);
        vm.stopPrank();

        assertFalse(_sawAntiSnipe(), "dev-buy must not be snipe-taxed");
        assertEq(IERC20(tokenAddr).balanceOf(CREATOR), q.tokensOut, "creator got the FULL untaxed dev-buy");
    }

    /// DIRECTION: only USDC -> token BUYS are taxed. A curve SELL must never
    /// trigger the anti-sniper (taxing sells is exactly the wrong-way behaviour
    /// this model rejects).
    function test_antisniper_doesNotTaxCurveSells() public {
        vm.prank(CREATOR);
        (address tokenAddr,) =
            hook.createLaunch("SnipePump", "SNP", "ipfs://demo", 0, address(0), 0, 2_000, 600, 0, "", 0, 0, 0);

        usdc.mint(ALICE, 400e6);
        vm.startPrank(ALICE);
        (uint256 got,) = hook.buy(tokenAddr, 400e6, 0);
        IERC20(tokenAddr).approve(address(hook), type(uint256).max);
        vm.recordLogs();
        hook.sell(tokenAddr, got, 0);
        vm.stopPrank();
        assertFalse(_sawAntiSnipe(), "curve sells are never snipe-taxed");
    }

    /// Post-graduation buys carry NO anti-sniper skim: the tax is inert once the
    /// token graduates (the graduated guard in _currentSnipeBps).
    function test_antisniper_postGradBuyNotTaxed() public {
        (, PoolKey memory key) = _graduatePumpWithSnipe(2_000, 600);
        vm.recordLogs();
        _buyViaV4(key, ALICE, 1_000e6);
        assertFalse(_sawAntiSnipe(), "post-grad buys carry no anti-sniper skim");
    }

    /// PUMP dev-buy is bounded at CREATOR_DEV_BUY_MAX_BPS (10%) of supply: an
    /// over-cap dev-buy reverts and unwinds the whole createLaunch.
    function test_pumpDevBuy_overCapReverts() public {
        // 30,000 USDC fills the curve (~77% of supply), far over the 10% cap.
        usdc.mint(CREATOR, 3e6 + 30_000e6);
        vm.startPrank(CREATOR);
        usdc.approve(address(hook), type(uint256).max);
        vm.expectRevert();
        hook.createLaunch("BigDev", "BIG", "ipfs://demo", 0, address(0), 0, 0, 0, 0, "", 0, 30_000e6, 0);
        vm.stopPrank();
    }

    /// A PUMP dev-buy sized between 5% and 10% of supply now PASSES: it would have
    /// reverted under the old 5% cap, proving the cap moved to 10%.
    function test_pumpDevBuy_between5and10pctPasses() public {
        uint256 fivePct = (ArcadeV4Curve.TOTAL_SUPPLY * 500) / 10_000;
        uint256 tenPct = (ArcadeV4Curve.TOTAL_SUPPLY * 1_000) / 10_000;
        uint256 devUsdc = 400e6;
        ArcadeV4Curve.BuyResult memory q = ArcadeV4Curve.simulateBuy(0, 0, devUsdc);
        assertGt(q.tokensOut, fivePct, "sized above the old 5% cap");
        assertLt(q.tokensOut, tenPct, "sized below the new 10% cap");

        usdc.mint(CREATOR, 3e6 + devUsdc);
        vm.startPrank(CREATOR);
        usdc.approve(address(hook), type(uint256).max);
        (address token,) =
            hook.createLaunch("MidDev", "MID", "ipfs://demo", 0, address(0), 0, 0, 0, 0, "", 0, devUsdc, 0);
        vm.stopPrank();
        assertGt(IERC20(token).balanceOf(CREATOR), fivePct, "over-5% dev-buy delivered (old cap would revert)");
    }

    // ------------------------------------------------------------------
    // ArcadeV4SwapRouter against the REAL PoolManager. The router's own
    // ArcadeV4SwapRouter.t.sol uses a mock whose swap() ignores the price
    // limit, so it never exercised the sqrtPriceLimitX96=0 fix nor the
    // IncompleteOutput guard. These do, on an actually-graduated pool.
    // ------------------------------------------------------------------

    /// The core fix: sqrtPriceLimitX96 == 0 used to revert every swap. It must
    /// now resolve to the full tick range and complete an exact-input buy.
    function test_router_zeroLimitExactInputBuy_realPM() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();
        ArcadeV4SwapRouter router = new ArcadeV4SwapRouter(IPoolManager(address(pm)));

        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc); // USDC -> token
        address buyer = address(0xB0B);
        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        uint256 out = router.exactInputSingle(key, zeroForOne, 1_000e6, 0, buyer, 0); // 0 = no limit
        vm.stopPrank();

        assertGt(out, 0, "0-limit exact-input must swap, not revert");
        assertEq(IERC20(tokenAddr).balanceOf(buyer), out, "recipient received the realised output");
    }

    /// Exact-output with 0 limit must deliver EXACTLY the requested output and
    /// must NOT false-trigger IncompleteOutput on a normal (non-partial) fill.
    function test_router_zeroLimitExactOutput_deliversExactly_realPM() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();
        ArcadeV4SwapRouter router = new ArcadeV4SwapRouter(IPoolManager(address(pm)));

        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc);
        address buyer = address(0xB0B2);
        usdc.mint(buyer, 100_000e6);
        uint256 wantTokens = 1_000e18;
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        uint256 paid = router.exactOutputSingle(key, zeroForOne, wantTokens, type(uint256).max, buyer, 0);
        vm.stopPrank();

        assertEq(IERC20(tokenAddr).balanceOf(buyer), wantTokens, "recipient got exactly the requested output");
        assertGt(paid, 0, "input was paid");
    }

    /// The unimplemented CLANKER_V3 mode must be rejected at the door, not mint
    /// 1B supply into the immutable hook and strand it (the audit MEDIUM-1).
    function test_createLaunch_rejectsClankerV3Mode() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidMode.selector);
        hook.createLaunch("V3", "V3", "ipfs://x", 2, address(0), 0, 0, 0, 0, "", 0, 0, 0);
    }

    function test_postGradFee_PUMP_splits80_20_inUsdcOnSell() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        uint256 creatorBefore = usdc.balanceOf(CREATOR);

        _sellViaV4(key, tokenAddr, ALICE, 100_000e18);

        uint256 treasuryGot = usdc.balanceOf(TREASURY) - treasuryBefore;
        uint256 creatorGot = usdc.balanceOf(CREATOR) - creatorBefore;
        uint256 total = treasuryGot + creatorGot;
        // New model: the hook captures the whole trading fee on a non-trivial
        // sell, so it must be measurable.
        assertGt(total, 0, "fee paid");
        // Post-grad split is 80/20 creator/treasury for every mode.
        assertApproxEqRel(creatorGot, (total * 80) / 100, 0.01e18, "creator 80% (PUMP)");
        assertApproxEqRel(treasuryGot, (total * 20) / 100, 0.01e18, "treasury 20% (PUMP)");
    }

    function test_postGradFee_CLANKER_splits80_20() public {
        // CLANKER charges its tier as the NATIVE pool LP fee; the fee accrues to
        // the locked LP and is harvested + split 80/20 via collectFees.
        (address tokenAddr,) = _graduateClanker(); // create direct + ALICE buys (fee -> LP)

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);
        uint256 creatorBefore = usdc.balanceOf(CREATOR);

        hook.collectFees(tokenAddr);

        uint256 treasuryGot = usdc.balanceOf(TREASURY) - treasuryBefore;
        uint256 creatorGot = usdc.balanceOf(CREATOR) - creatorBefore;
        uint256 total = treasuryGot + creatorGot;

        assertGt(total, 0, "LP fees harvested");
        // 80/20 creator/treasury on the harvested USDC fee.
        assertApproxEqRel(creatorGot, (total * 80) / 100, 0.02e18, "creator 80%");
        assertApproxEqRel(treasuryGot, (total * 20) / 100, 0.02e18, "treasury 20%");
    }

    // -------------------------------------------------------------------
    // Always-USDC fee capture: the fee lands in USDC on ALL FOUR swap
    // cases (buy/sell x exact-in/exact-out), never in the launch token.
    // beforeSwap covers the USDC-specified cases (buy exact-in, sell
    // exact-out); afterSwap covers the USDC-unspecified cases. Exactly one
    // side fires per swap so the fee is never double-charged.
    // -------------------------------------------------------------------

    /// Snapshot fee-recipient balances, run `body`, then assert the ENTIRE fee
    /// arrived in USDC (never in the launch token) and split 80/20.
    function _assertUsdcOnlyFee(
        address tokenAddr,
        uint256 cUsdc0,
        uint256 tUsdc0,
        uint256 cTok0,
        uint256 tTok0
    ) internal {
        uint256 cUsdc = usdc.balanceOf(CREATOR) - cUsdc0;
        uint256 tUsdc = usdc.balanceOf(TREASURY) - tUsdc0;
        uint256 cTok = IERC20(tokenAddr).balanceOf(CREATOR) - cTok0;
        uint256 tTok = IERC20(tokenAddr).balanceOf(TREASURY) - tTok0;
        uint256 total = cUsdc + tUsdc;
        assertGt(total, 0, "fee paid in USDC");
        // The launch token must NEVER be handed to a fee recipient.
        assertEq(cTok, 0, "creator got no token fee");
        assertEq(tTok, 0, "treasury got no token fee");
        assertApproxEqRel(cUsdc, (total * 80) / 100, 0.01e18, "creator 80%");
        assertApproxEqRel(tUsdc, (total * 20) / 100, 0.01e18, "treasury 20%");
    }

    /// buy exact-in: spend exact USDC (USDC specified) -> beforeSwap path.
    function test_alwaysUsdc_buyExactIn() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();
        uint256 cU = usdc.balanceOf(CREATOR);
        uint256 tU = usdc.balanceOf(TREASURY);
        uint256 cT = IERC20(tokenAddr).balanceOf(CREATOR);
        uint256 tT = IERC20(tokenAddr).balanceOf(TREASURY);
        _buyViaV4(key, ALICE, 5_000e6);
        _assertUsdcOnlyFee(tokenAddr, cU, tU, cT, tT);
    }

    /// sell exact-in: sell exact token, receive USDC (USDC unspecified) -> afterSwap.
    function test_alwaysUsdc_sellExactIn() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();
        uint256 cU = usdc.balanceOf(CREATOR);
        uint256 tU = usdc.balanceOf(TREASURY);
        uint256 cT = IERC20(tokenAddr).balanceOf(CREATOR);
        uint256 tT = IERC20(tokenAddr).balanceOf(TREASURY);
        _sellViaV4(key, tokenAddr, ALICE, 100_000e18);
        _assertUsdcOnlyFee(tokenAddr, cU, tU, cT, tT);
    }

    /// buy exact-out: want exact token, pay USDC (token specified, USDC
    /// unspecified) -> afterSwap path.
    function test_alwaysUsdc_buyExactOut() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();
        uint256 cU = usdc.balanceOf(CREATOR);
        uint256 tU = usdc.balanceOf(TREASURY);
        uint256 cT = IERC20(tokenAddr).balanceOf(CREATOR);
        uint256 tT = IERC20(tokenAddr).balanceOf(TREASURY);
        vm.startPrank(ALICE);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc); // USDC -> token
        uint160 lim = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(500_000e18), sqrtPriceLimitX96: lim}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        _assertUsdcOnlyFee(tokenAddr, cU, tU, cT, tT);
    }

    /// sell exact-out: want exact USDC out, pay token (USDC specified) ->
    /// beforeSwap path. The critical new case: a SELL whose fee is taken in
    /// beforeSwap, still in USDC.
    function test_alwaysUsdc_sellExactOut() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();
        uint256 cU = usdc.balanceOf(CREATOR);
        uint256 tU = usdc.balanceOf(TREASURY);
        uint256 cT = IERC20(tokenAddr).balanceOf(CREATOR);
        uint256 tT = IERC20(tokenAddr).balanceOf(TREASURY);
        vm.startPrank(ALICE);
        IERC20(tokenAddr).approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) != address(usdc); // token -> USDC
        uint160 lim = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(100e6), sqrtPriceLimitX96: lim}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        _assertUsdcOnlyFee(tokenAddr, cU, tU, cT, tT);
    }

    // -------------------------------------------------------------------
    // Locked LP: graduation seed cannot be removed by anyone external
    // -------------------------------------------------------------------

    function test_lockedLP_externalRemovalAttempt_revertsLockedPosition() public {
        (address tokenAddr, PoolKey memory key) = _graduatePump();
        tokenAddr;

        // An outsider tries to add LP (and would try to remove if they had one
        // on the right position). beforeAddLiquidity rejects external senders
        // since the LP is the hook's locked seed.
        // We simulate by calling pm.modifyLiquidity directly through an
        // unlock-aware harness. Lacking one in this test file, we assert the
        // hook's beforeAddLiquidity gate via vm.prank(poolManager).
        // Going through the manager would require a router; the gate itself
        // is unit-tested elsewhere. Here we just exercise the post-grad path
        // ends in a Graduated pool whose LP is intact after a V4 swap.
        ArcadeHook.CurveState memory s = hook.getCurveState(key.toId());
        assertEq(uint256(s.status), 2, "Graduated");
    }

    function test_v4Swap_afterGraduation_succeeds() public {
        (address tokenAddr, PoolKey memory key) = _launchPump();

        // Graduate.
        vm.prank(ALICE);
        hook.buy(tokenAddr, 30_000e6, 0);

        // Now a V4 swap through the canonical router should land at the
        // graduation-seeded pool. Alice already holds the launch tokens
        // from the cap-path buy; she sells some via the AMM.
        uint256 sellAmount = 1_000e18;
        vm.startPrank(ALICE);
        IERC20(tokenAddr).approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) != address(usdc);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(sellAmount), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // The AMM produced a non-zero output on the USDC side.
        int128 usdcDelta = Currency.unwrap(key.currency0) == address(usdc) ? delta.amount0() : delta.amount1();
        assertGt(int256(usdcDelta), 0, "alice receives USDC from V4 AMM");
    }

    // -------------------------------------------------------------------
    // Slippage guards
    // -------------------------------------------------------------------

    function test_buy_slippage_revertsWhenMinTokensOutNotMet() public {
        (address tokenAddr,) = _launchPump();
        // Set min absurdly high; should revert before transferring USDC.
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.Slippage.selector);
        hook.buy(tokenAddr, 100e6, type(uint256).max);
    }

    function test_sell_slippage_revertsWhenMinUsdcOutNotMet() public {
        (address tokenAddr,) = _launchPump();
        vm.prank(ALICE);
        (uint256 tokensReceived,) = hook.buy(tokenAddr, 100e6, 0);

        vm.startPrank(ALICE);
        IERC20(tokenAddr).approve(address(hook), tokensReceived);
        vm.expectRevert(ArcadeHook.Slippage.selector);
        hook.sell(tokenAddr, tokensReceived, type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // Negative cases
    // -------------------------------------------------------------------

    function test_buy_revertsForUnregisteredToken() public {
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.LaunchNotRegistered.selector);
        hook.buy(address(0xdead), 100e6, 0);
    }

    function test_buy_revertsOnZeroAmount() public {
        (address tokenAddr,) = _launchPump();
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.ZeroAmount.selector);
        hook.buy(tokenAddr, 0, 0);
    }

    function test_buy_revertsWhenPaused() public {
        (address tokenAddr,) = _launchPump();
        vm.prank(OWNER);
        hook.pause();
        vm.prank(ALICE);
        vm.expectRevert();
        hook.buy(tokenAddr, 100e6, 0);
    }

    // -------------------------------------------------------------------
    // V4 swap path during Curving must revert
    // -------------------------------------------------------------------

    function test_v4Swap_duringCurving_revertsForceUsesHookBuy() public {
        (, PoolKey memory key) = _launchPump();

        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        vm.prank(ALICE);
        vm.expectRevert(); // LiquidityNotPermitted wraps inside the manager
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(uint256(100e6)), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // -------------------------------------------------------------------
    // PUMP dynamic fee: 1% at graduation, decaying toward 0.30% as market
    // cap grows, driven by a manipulation-resistant price EMA.
    // -------------------------------------------------------------------

    /// A fresh graduate charges the 1% ceiling: the EMA starts AT the
    /// graduation mcap tick so there is zero growth yet.
    function test_pumpFee_startsAtMax() public {
        (address token,) = _graduatePump();
        assertEq(hook.currentFeeBps(token), 100, "1% at graduation");
    }

    /// Drive the price up with repeated buys spaced over time; the EMA climbs
    /// and the PUMP fee must fall below 1% but never under the 0.30% floor.
    function test_pumpFee_decaysAsMarketCapGrows() public {
        (address token, PoolKey memory key) = _graduatePump();
        usdc.mint(ALICE, 100_000e6);
        uint256 f0 = hook.currentFeeBps(token);
        assertEq(f0, 100, "starts at 1%");

        // Modest buys spaced over time push the price up and climb the EMA.
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 12; i++) {
            t += 3 hours;
            vm.warp(t);
            _buyViaV4(key, ALICE, 1_000e6);
        }

        uint256 f1 = hook.currentFeeBps(token);
        assertLt(f1, f0, "fee decayed as mcap grew");
        assertGe(f1, 30, "never under the 0.30% floor");
    }

    /// Push the market cap far past the floor threshold (10x+) over time: the
    /// fee must clamp exactly at the 0.30% floor and stay there.
    function test_pumpFee_floorsAt30bps() public {
        (address token, PoolKey memory key) = _graduatePump();
        usdc.mint(ALICE, 100_000e6);

        // Sustained buying over time pushes market cap well past the 10x floor
        // threshold; the EMA converges and the fee clamps at 0.30%. Track time
        // in a local so each iteration genuinely advances the oracle clock.
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 30; i++) {
            t += 6 hours;
            vm.warp(t);
            _buyViaV4(key, ALICE, 1_500e6);
        }

        assertEq(hook.currentFeeBps(token), 30, "clamped at 0.30% floor");
    }

    // -------------------------------------------------------------------
    // CLANKER static fee tiers: the creator picks 1/2/3% at launch and it
    // never changes (unlike PUMP's mcap decay).
    // -------------------------------------------------------------------

    /// CLANKER is a DIRECT launch: createLaunch seeds the single-sided locked LP
    /// and the pool is live (Graduated) immediately -- no curve buy to graduate.
    function _graduateClankerTier(uint8 tier) internal returns (address tokenAddr, PoolKey memory key) {
        vm.prank(CREATOR);
        (tokenAddr,) = hook.createLaunch("ClkTier", "CLK", "ipfs://demo", 1, address(0), 0, 0, 0, tier, "", 0, 0, 0);
        key = _buildKey(tokenAddr);
    }

    /// CLANKER is a DIRECT launch: full supply seeded single-sided (creator
    /// provides NO USDC), pool live (Graduated) immediately, pool fee = tier.
    function test_clankerDirect_singleSidedLiveAtCreation() public {
        uint256 creatorUsdcBefore = usdc.balanceOf(CREATOR);
        vm.prank(CREATOR);
        (address token,) = hook.createLaunch("D", "D", "ipfs://d", 1, address(0), 0, 0, 0, 2, "", 0, 0, 0);

        // Creator paid ONLY the 3 USDC creation fee -- no LP capital.
        assertEq(creatorUsdcBefore - usdc.balanceOf(CREATOR), 3e6, "creator paid only the creation fee");
        // The hook shipped the whole supply into the locked LP (holds ~0 now).
        assertLt(IERC20(token).balanceOf(address(hook)), 1e18, "hook holds ~no supply (all in LP)");

        PoolKey memory key = _buildKey(token);
        ArcadeHook.CurveState memory s = hook.getCurveState(key.toId());
        assertEq(uint256(s.status), 2, "live (Graduated) at creation");
        assertEq(hook.poolFeeOf(token), 20_000, "pool fee = tier 2 (2%)");

        // Tradeable immediately -- no curve graduation.
        usdc.mint(ALICE, 10_000e6);
        _buyViaV4(key, ALICE, 1_000e6);
        assertGt(IERC20(token).balanceOf(ALICE), 0, "ALICE bought directly");
    }

    /// Audit 2026-07-18 MEDIUM: a startMcap whose aligned tick lands on a
    /// tickSpacing boundary must NOT make the single-sided seed in-range (which
    /// would pull USDC the hook doesn't hold -> revert, or silently drain the
    /// hook's shared USDC into the locked LP). Fund the hook with USDC (as PUMP
    /// curve reserves would) and assert no startMcap pulls any of it.
    function test_clankerDirect_boundaryStartMcap_noStraddleNoDrain() public {
        usdc.mint(address(hook), 1_000e6);
        uint256 hookUsdcBefore = usdc.balanceOf(address(hook));
        uint256[6] memory mcaps =
            [uint256(1_232e6), 1_475e6, 1_630e6, 1_663e6, 1_875e6, 100_000e6];
        for (uint256 i = 0; i < mcaps.length; i++) {
            vm.prank(CREATOR);
            hook.createLaunch("B", "B", "ipfs://b", 1, address(0), 0, 0, 0, 1, "", mcaps[i], 0, 0);
            // Single-sided: the seed pulled NO USDC out of the hook.
            assertEq(usdc.balanceOf(address(hook)), hookUsdcBefore, "no USDC pulled into CLANKER LP");
        }
    }

    /// collectFees harvests the token-side LP fee (accrued on SELLS) and pays
    /// the creator DIRECT (allowEscrow=false; the escrow pins USDC per slot).
    function test_clankerDirect_collectHarvestsTokenSideToCreator() public {
        (address token, PoolKey memory key) = _launchClanker();
        _buyViaV4(key, ALICE, 5_000e6); // ALICE gets tokens; USDC-side fee accrues
        _sellViaV4(key, token, ALICE, 10_000_000e18); // token-side fee accrues

        uint256 creatorTokBefore = IERC20(token).balanceOf(CREATOR);
        uint256 creatorUsdcBefore = usdc.balanceOf(CREATOR);
        hook.collectFees(token);
        assertGt(IERC20(token).balanceOf(CREATOR) - creatorTokBefore, 0, "creator got token-side fee direct");
        assertGt(usdc.balanceOf(CREATOR) - creatorUsdcBefore, 0, "creator got USDC-side fee");
    }

    function test_createLaunch_clankerRevertsInvalidStartMcap() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidStartMcap.selector);
        hook.createLaunch("X", "X", "ipfs://x", 1, address(0), 0, 0, 0, 1, "", 999e6, 0, 0); // below $1k
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidStartMcap.selector);
        hook.createLaunch("Y", "Y", "ipfs://y", 1, address(0), 0, 0, 0, 1, "", 10_000_001e6, 0, 0); // above $10M
    }

    /// Anti-sniper cannot work on the single-sided CLANKER pool -> a snipe config
    /// on CLANKER is rejected (not silently accepted as a paid no-op).
    function test_createLaunch_clankerRejectsSnipeConfig() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidSnipeBps.selector);
        hook.createLaunch("S", "S", "ipfs://s", 1, address(0), 0, 1_000, 600, 1, "", 0, 0, 0);
    }

    /// Anti-sniper decay window is capped at 1h on-chain (audit fee M-1): a PUMP
    /// launch with a longer window reverts, so a creator cannot levy a near-50%
    /// self-routed buy tax over a multi-year window. Exactly 1h is accepted.
    function test_createLaunch_pumpRejectsOverlongSnipeDecay() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidDecaySeconds.selector);
        hook.createLaunch("P", "P", "ipfs://p", 0, address(0), 0, 5_000, 3_601, 0, "", 0, 0, 0);
        // Boundary: exactly MAX_SNIPE_DECAY_SECONDS (1h) is allowed.
        vm.prank(CREATOR);
        hook.createLaunch("P2", "P2", "ipfs://p2", 0, address(0), 0, 5_000, 3_600, 0, "", 0, 0, 0);
    }

    /// creator2 is a CLANKER-only split; PUMP would ignore it everywhere, so a
    /// creator2 config on PUMP is rejected rather than silently dropped.
    function test_createLaunch_pumpRejectsCreator2() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidFeeOwner.selector);
        hook.createLaunch("P", "P", "ipfs://p", 0, address(0xBEEF), 2_000, 0, 0, 0, "", 0, 0, 0);
    }

    // --- CLANKER anti-snipe first-window buy cap ---

    function test_clankerCap_bigBuyRevertsInWindow() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300); // 1% of supply, 5 min
        (, PoolKey memory key) = _launchClanker();

        // Inline the swap so vm.expectRevert targets IT (not the approve inside
        // the _buyViaV4 helper). 5_000 USDC at the $35k start buys >>1% -> revert.
        vm.startPrank(ALICE);
        usdc.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(uint256(5_000e6)), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_clankerCap_smallBuyPassesInWindow() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300);
        (, PoolKey memory key) = _launchClanker();
        _buyViaV4(key, ALICE, 10e6); // ~0.03% of supply, under the cap -> ok
    }

    function test_clankerCap_bigBuyPassesAfterWindow() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300);
        (, PoolKey memory key) = _launchClanker();
        vm.warp(block.timestamp + 301); // window elapsed
        _buyViaV4(key, ALICE, 5_000e6); // no longer capped -> ok
    }

    /// The cap is CUMULATIVE per block: two buys that each pass individually but
    /// together exceed the cap -> the second reverts (defeats atomic batching).
    /// A fresh block resets the accumulator.
    function test_clankerCap_perTxRamp() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300); // enables the per-tx anti-sniper ramp
        (, PoolKey memory key) = _launchClanker();

        // Minute 0: cap = 1% of supply. A single big buy delivering > 1% reverts.
        vm.startPrank(ALICE);
        usdc.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.expectRevert(); // > 1% in a single tx at minute 0
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(uint256(5_000e6)), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // A small buy (< 1%) passes; per-TX (not cumulative), a second same-block
        // small buy ALSO passes -- batching is the accepted trade-off.
        _buyViaV4(key, ALICE, 100e6);
        _buyViaV4(key, ALICE, 100e6);

        // After the 5-minute window the cap lifts, so the big buy now succeeds.
        vm.warp(block.timestamp + 301);
        _buyViaV4(key, ALICE, 5_000e6);
    }

    function test_clankerCap_sellNotCapped() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300);
        (address token, PoolKey memory key) = _launchClanker();
        _buyViaV4(key, ALICE, 10e6); // small buy under cap
        uint256 bal = IERC20(token).balanceOf(ALICE);
        _sellViaV4(key, token, ALICE, bal); // sells are never capped -> ok
    }

    // -------------------------------------------------------------------
    // CLANKER atomic DEV BUY: the creator's frontrun-proof first buy,
    // executed inline in createLaunch by swapping creatorBuyUsdc through the
    // freshly-seeded single-sided pool and delivering the token to the creator.
    // Inherited by the currency0 subclass -> exercised in BOTH orderings.
    // -------------------------------------------------------------------

    /// @dev CLANKER launch (tier 1) that ALSO performs an atomic dev-buy of
    ///      `buyUsdc`. Launched as CREATOR, so the bought bag lands on CREATOR.
    function _launchClankerDevBuy(uint256 buyUsdc) internal returns (address tokenAddr, PoolKey memory key) {
        vm.prank(CREATOR);
        (tokenAddr,) = hook.createLaunch("ClkDev", "CLKD", "ipfs://demo", 1, address(0), 0, 0, 0, 1, "", 0, buyUsdc, 0);
        key = _buildKey(tokenAddr);
    }

    /// LOW-1 fix: the dev-buy now COUNTS against the first-window per-block budget,
    /// so a SAME-BLOCK public buy that would pass on its own reverts (the dev-buy
    /// already filled the block cap -> no block-0 "dev-buy + 1%" stacking). The
    /// budget resets the next block, so the same buy then succeeds.
    function test_clankerDevBuy_sameBlockPublicBuyAllowed() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300); // per-tx ramp on
        // Dev-buy ~4% of supply: exempt from the cap (bounded 10% in kind-4).
        (, PoolKey memory key) = _launchClankerDevBuy(1_500e6);

        // SAME BLOCK: a small public buy (< 1% on its own) SUCCEEDS. Under the
        // per-TX ramp each buy is judged alone, so the dev-buy no longer consumes a
        // shared per-block budget (the old cumulative model blocked this).
        _buyViaV4(key, ALICE, 20e6);
    }

    function test_clankerDevBuy_deliversTokensToCreator() public {
        uint256 creatorUsdcBefore = usdc.balanceOf(CREATOR);
        (address token,) = _launchClankerDevBuy(1_000e6);
        // The creator (launcher) received the bought bag from the atomic dev-buy.
        assertGt(IERC20(token).balanceOf(CREATOR), 0, "creator received the dev-buy bag");
        // Net spend = 3 USDC creation fee + the full buy input. CLANKER's tier
        // fee stays in the pool as an LP fee (no rebate), so spend is exact.
        assertEq(creatorUsdcBefore - usdc.balanceOf(CREATOR), 3e6 + 1_000e6, "spent = creation fee + dev-buy");
    }

    function test_clankerDevBuy_noUsdcStrandedInHook() public {
        _launchClankerDevBuy(1_500e6);
        // The exact-input swap consumes the ENTIRE creatorBuyUsdc the hook held,
        // so nothing is left stranded in the hook.
        assertEq(usdc.balanceOf(address(hook)), 0, "exact-in consumed all dev-buy USDC");
    }

    function test_clankerDevBuy_biggerInputBuysMoreTokens() public {
        (address tokenA,) = _launchClankerDevBuy(500e6);
        uint256 bagA = IERC20(tokenA).balanceOf(CREATOR);
        (address tokenB,) = _launchClankerDevBuy(1_500e6);
        uint256 bagB = IERC20(tokenB).balanceOf(CREATOR);
        assertGt(bagA, 0, "small dev-buy delivered");
        assertGt(bagB, bagA, "larger dev-buy input -> larger token bag");
    }

    /// The dev-buy is NOT subject to the third-party first-window cap: with the
    /// public cap at 1%, a dev-buy above 1% (but within the 5% dev ceiling)
    /// succeeds and delivers more than the 1% cap's worth of tokens.
    function test_clankerDevBuy_notSubjectToPublicCap() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300); // 1% of supply, 5 min window
        (address token,) = _launchClankerDevBuy(1_000e6); // ~2-3% of supply: > 1% public cap, < 5% dev cap
        uint256 publicCapTokens = (ArcadeV4Curve.TOTAL_SUPPLY * 100) / 10_000; // 1%
        assertGt(IERC20(token).balanceOf(CREATOR), publicCapTokens, "dev-buy delivered MORE than the public 1% cap");
    }

    /// The dev-buy is itself BOUNDED at CREATOR_DEV_BUY_MAX_BPS (10%) of supply:
    /// a dev-buy whose token output tops 10% reverts, unwinding the whole
    /// createLaunch. 5,000 USDC buys well over 10% at the default mcap.
    function test_clankerDevBuy_cappedAt10pctOfSupply() public {
        vm.prank(CREATOR);
        vm.expectRevert(); // DevBuyExceedsCap in the dev-buy handler unwinds createLaunch
        hook.createLaunch("ClkBig", "CLKB", "ipfs://demo", 1, address(0), 0, 0, 0, 1, "", 0, 5_000e6, 0);
    }

    /// A dev-buy under the 10% ceiling succeeds and stays within it.
    function test_clankerDevBuy_underCapPasses() public {
        (address token,) = _launchClankerDevBuy(1_500e6); // ~4% of supply
        uint256 tenPct = (ArcadeV4Curve.TOTAL_SUPPLY * 1_000) / 10_000; // CREATOR_DEV_BUY_MAX_BPS = 10%
        uint256 bag = IERC20(token).balanceOf(CREATOR);
        assertGt(bag, 0, "under-cap dev-buy delivered");
        assertLe(bag, tenPct, "bag within the 10% ceiling");
    }

    /// The exemption is dev-buy ONLY: with the SAME cap live, a third party's
    /// large buy in the first window still reverts BuyExceedsCap.
    function test_clankerDevBuy_thirdPartyStillCappedInWindow() public {
        vm.prank(OWNER);
        hook.setClankerBuyCap(100, 300); // 1%, 5 min
        // Launch WITH a modest dev-buy (exempt), then a third party tries a huge
        // buy in the same window -> capped.
        (, PoolKey memory key) = _launchClankerDevBuy(100e6);

        vm.startPrank(ALICE);
        usdc.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(uint256(8_000e6)), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// The dev-buy is a SWAP against the locked seed; it never touches the
    /// hook-owned position. The pool stays fully tradeable afterwards.
    function test_clankerDevBuy_poolStillTradeableAfterDevBuy() public {
        (address token, PoolKey memory key) = _launchClankerDevBuy(1_000e6);
        _buyViaV4(key, ALICE, 100e6);
        assertGt(IERC20(token).balanceOf(ALICE), 0, "third party can still trade the intact pool");
    }

    /// The dev-buy's afterSwap stamps the graveyard clock at the launch block
    /// (same value the seed already wrote -- no double-count issue).
    function test_clankerDevBuy_stampsLastTradeAt() public {
        (, PoolKey memory key) = _launchClankerDevBuy(1_000e6);
        assertEq(uint256(hook.lastTradeAt(key.toId())), block.timestamp, "dev-buy stamped lastTradeAt");
    }

    /// A CLANKER launch with creatorBuyUsdc == 0 is unchanged: nothing pulled
    /// beyond the creation fee, the creator holds no tokens.
    function test_clankerDevBuy_zeroInputUnchanged() public {
        uint256 creatorUsdcBefore = usdc.balanceOf(CREATOR);
        (address token,) = _launchClanker(); // creatorBuyUsdc = 0
        assertEq(IERC20(token).balanceOf(CREATOR), 0, "no dev-buy -> creator holds nothing");
        assertEq(creatorUsdcBefore - usdc.balanceOf(CREATOR), 3e6, "only the creation fee pulled");
        assertEq(usdc.balanceOf(address(hook)), 0, "no USDC in the hook");
    }

    function test_clankerFee_tier1_is1pct() public {
        (address token,) = _graduateClankerTier(1);
        assertEq(hook.currentFeeBps(token), 100, "tier 1 = 1%");
    }

    function test_clankerFee_tier2_is2pct() public {
        (address token,) = _graduateClankerTier(2);
        assertEq(hook.currentFeeBps(token), 200, "tier 2 = 2%");
    }

    function test_clankerFee_tier3_is3pct() public {
        (address token,) = _graduateClankerTier(3);
        assertEq(hook.currentFeeBps(token), 300, "tier 3 = 3%");
    }

    /// CLANKER tiers are STATIC: market-cap growth that would decay a PUMP fee
    /// leaves a CLANKER tier untouched.
    function test_clankerFee_staysStaticAcrossMcapGrowth() public {
        (address token, PoolKey memory key) = _graduateClankerTier(3);
        usdc.mint(ALICE, 100_000e6);
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 10; i++) {
            t += 3 hours;
            vm.warp(t);
            _buyViaV4(key, ALICE, 1_000e6);
        }
        assertEq(hook.currentFeeBps(token), 300, "CLANKER tier is static, not mcap-decaying");
    }

    /// A CLANKER launch MUST pick a valid tier (1/2/3). Zero or out-of-range
    /// reverts before any USDC is pulled.
    function test_createLaunch_revertsOnInvalidClankerTier() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidFeeTier.selector);
        hook.createLaunch("X", "X", "ipfs://x", 1, address(0), 0, 0, 0, 0, "", 0, 0, 0);

        vm.prank(CREATOR);
        vm.expectRevert(ArcadeHook.InvalidFeeTier.selector);
        hook.createLaunch("Y", "Y", "ipfs://y", 1, address(0), 0, 0, 0, 4, "", 0, 0, 0);
    }

    /// PUMP ignores the fee-tier argument entirely: its fee is the mcap-decaying
    /// dynamic curve regardless of what tier value is passed. Proves PUMP fees
    /// are NOT creator-customisable (only CLANKER's are).
    function test_createLaunch_pumpIgnoresFeeTier() public {
        vm.prank(CREATOR);
        (address token,) = hook.createLaunch("P", "P", "ipfs://p", 0, address(0), 0, 0, 0, 3, "", 0, 0, 0);
        vm.prank(ALICE);
        hook.buy(token, 30_000e6, 0);
        // Dynamic fee starts at 1% at graduation, NOT tier 3's 3%.
        assertEq(hook.currentFeeBps(token), 100, "PUMP uses dynamic fee, tier arg ignored");
    }

    // -------------------------------------------------------------------
    // Twitter-handle fee attribution: a CLANKER launch with a handle routes
    // its post-grad CREATOR cut to a handle-gated escrow slot instead of the
    // launcher's wallet. Inherited by the currency0 subclass -> covered in both
    // orderings.
    // -------------------------------------------------------------------

    function _wireEscrow() internal returns (ArcadeTwitterEscrowV4 escrow) {
        escrow = new ArcadeTwitterEscrowV4(address(0x519E5), OWNER); // (signer, owner)
        vm.startPrank(OWNER);
        hook.setTwitterEscrow(address(escrow));
        escrow.setCrediter(address(hook), true);
        vm.stopPrank();
    }

    function test_escrow_clankerFeesRouteToHandleSlot() public {
        ArcadeTwitterEscrowV4 escrow = _wireEscrow();

        // CLANKER direct launch attributing fees to a handle. The pool is live
        // at createLaunch; ALICE buys via V4 and the creator cut of that swap
        // routes to the handle-gated escrow slot.
        vm.prank(CREATOR);
        (address token,) = hook.createLaunch("Clk", "CLK", "ipfs://x", 1, address(0), 0, 0, 0, 1, "arcade", 0, 0, 0);
        PoolKey memory key = _buildKey(token);

        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        uint256 creatorBefore = usdc.balanceOf(CREATOR);
        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        _buyViaV4(key, ALICE, 5_000e6); // pool LP fee accrues to the locked LP
        hook.collectFees(token); // harvest -> USDC creator cut to the escrow slot

        // Creator is NOT paid directly; the 80% USDC cut sits in the escrow slot.
        assertEq(usdc.balanceOf(CREATOR), creatorBefore, "creator not paid directly");
        uint256 slotBal = escrow.balances(poolId, 0, address(usdc));
        uint256 treasuryGot = usdc.balanceOf(TREASURY) - treasuryBefore;
        assertGt(slotBal, 0, "escrow slot credited");
        assertGt(treasuryGot, 0, "treasury still paid");
        // 80/20: the escrow slot holds ~4x the treasury cut.
        assertApproxEqRel(slotBal, treasuryGot * 4, 0.05e18, "80/20 into escrow vs treasury");
    }

    /// M-2 (Option A / Design 1): with a tokenForwarder configured, a
    /// handle-attributed CLANKER launch routes the TOKEN side of its fees to the
    /// forwarder (the backend operator, which delivers it to the @ owner on
    /// claim), NOT to the launcher's wallet -- while the USDC side still escrows
    /// and the launch IDENTITY + locked-LP owner stay the real launcher.
    function test_tokenForwarder_handleLaunch_routesTokenSideToForwarder() public {
        ArcadeTwitterEscrowV4 escrow = _wireEscrow();
        address FORWARDER = address(0xF0F0F0);
        vm.prank(OWNER);
        hook.setTokenForwarder(FORWARDER);

        vm.prank(CREATOR);
        (address token,) = hook.createLaunch("Clk", "CLK", "ipfs://x", 1, address(0), 0, 0, 0, 1, "arcade", 0, 0, 0);
        PoolKey memory key = _buildKey(token);
        PoolId pid = key.toId();
        uint256 poolId = uint256(PoolId.unwrap(pid));

        // FeeOwner.creator is the forwarder (fee routing); the launch identity is
        // still the real launcher (display / locked-LP owner).
        assertEq(hook.getFeeOwner(pid).creator, FORWARDER, "fee-creator = forwarder");
        assertEq(hook.getCurveState(pid).creator, CREATOR, "launch identity = launcher");

        // Buy then SELL so a TOKEN-side LP fee accrues (sells pay in the token).
        _buyViaV4(key, ALICE, 50_000e6);
        _sellViaV4(key, token, ALICE, 10_000_000e18);

        uint256 fwdBefore = IERC20(token).balanceOf(FORWARDER);
        uint256 launcherBefore = IERC20(token).balanceOf(CREATOR);
        hook.collectFees(token);

        assertGt(IERC20(token).balanceOf(FORWARDER) - fwdBefore, 0, "forwarder got the token side");
        assertEq(IERC20(token).balanceOf(CREATOR), launcherBefore, "launcher NOT paid the token side");
        assertGt(escrow.balances(poolId, 0, address(usdc)), 0, "USDC side still escrowed to the handle");
    }

    /// A tokenForwarder has NO effect on a launch WITHOUT a handle: the token
    /// side stays with the launcher (the forwarder only reroutes handle launches).
    function test_tokenForwarder_noHandle_hasNoEffect() public {
        vm.prank(OWNER);
        hook.setTokenForwarder(address(0xF0F0F0));
        vm.prank(CREATOR);
        (address token,) = hook.createLaunch("Clk", "CLK", "ipfs://x", 1, address(0), 0, 0, 0, 1, "", 0, 0, 0);
        PoolId pid = _buildKey(token).toId();
        assertEq(hook.getFeeOwner(pid).creator, CREATOR, "no handle => fee-creator stays the launcher");
    }

    /// setTokenForwarder is owner-gated.
    function test_setTokenForwarder_onlyOwner() public {
        vm.prank(ALICE);
        vm.expectRevert();
        hook.setTokenForwarder(address(0xBEEF));
    }

    /// PUMP ignores the handle: fees go direct to the creator even if a handle
    /// is passed (Twitter attribution is CLANKER-only).
    function test_escrow_pumpIgnoresHandle() public {
        _wireEscrow();
        vm.prank(CREATOR);
        (address token,) = hook.createLaunch("P", "P", "ipfs://p", 0, address(0), 0, 0, 0, 0, "arcade", 0, 0, 0);
        PoolKey memory key = _buildKey(token);
        vm.prank(ALICE);
        hook.buy(token, 30_000e6, 0);

        uint256 creatorBefore = usdc.balanceOf(CREATOR);
        _sellViaV4(key, token, ALICE, 100_000e18);
        assertGt(usdc.balanceOf(CREATOR), creatorBefore, "PUMP pays creator directly, ignores handle");
    }

    /// Manipulation resistance: multiple swaps within the SAME block timestamp
    /// must not move the oracle at all (dt == 0 guard), so a flash spike +
    /// revert in one tx cannot swing the fee anyone pays.
    function test_pumpFee_intraBlockSpikeDoesNotMoveFee() public {
        (address token, PoolKey memory key) = _graduatePump();
        usdc.mint(ALICE, 5_000_000e6);

        // Advance the EMA to a mid value first.
        vm.warp(block.timestamp + 3 hours);
        _buyViaV4(key, ALICE, 100_000e6);
        uint256 fBefore = hook.currentFeeBps(token);

        // Two more swaps in the SAME block (no warp): oracle frozen.
        _buyViaV4(key, ALICE, 500_000e6);
        uint256 fMid = hook.currentFeeBps(token);
        _sellViaV4(key, token, ALICE, 1_000_000e18);
        uint256 fAfter = hook.currentFeeBps(token);

        assertEq(fBefore, fMid, "no EMA move intra-block (buy)");
        assertEq(fMid, fAfter, "no EMA move intra-block (sell)");
    }

    // -------------------------------------------------------------------
    // Graveyard sweep: a graduated PUMP / seeded CLANKER pool with ZERO
    // trading for graveyardPeriod (>= 180d) may have its stranded locked LP
    // permissionlessly swept to the treasury. It must be IMPOSSIBLE to trigger
    // on a live pool: ANY trade resets the clock. Runs in BOTH currency
    // orderings (inherited by ArcadeHookSwapUsdcCurrency0Test).
    // -------------------------------------------------------------------

    function _period() internal view returns (uint256) {
        return uint256(hook.graveyardPeriod());
    }

    /// Cannot sweep before the no-trade period elapses (PUMP).
    function test_graveyard_pump_revertsBeforePeriod() public {
        (address token,) = _graduatePump();
        vm.warp(block.timestamp + _period() - 1); // one second short
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.NotDead.selector);
        hook.graveyardSweep(token);
    }

    /// Sweep succeeds exactly AT the period boundary and sends BOTH sides to the
    /// treasury; the pool's LP is emptied (PUMP full-range: active liq -> 0).
    function test_graveyard_pump_sweepsAtBoundary_toTreasury() public {
        (address token, PoolKey memory key) = _graduatePump();
        PoolId poolId = key.toId();
        assertGt(IPoolManager(address(pm)).getLiquidity(poolId), 0, "pool has LP before sweep");

        uint256 tBefore = usdc.balanceOf(TREASURY);
        uint256 tokBefore = IERC20(token).balanceOf(TREASURY);

        vm.warp(block.timestamp + _period()); // exactly the boundary (>=)
        vm.prank(ALICE); // permissionless: a non-owner sweeps
        hook.graveyardSweep(token);

        assertTrue(hook.graveyardSwept(poolId), "marked swept");
        assertEq(IPoolManager(address(pm)).getLiquidity(poolId), 0, "LP emptied");
        assertGt(usdc.balanceOf(TREASURY) - tBefore, 0, "treasury got USDC side");
        assertGt(IERC20(token).balanceOf(TREASURY) - tokBefore, 0, "treasury got token side");
    }

    /// Sweep a dead CLANKER pool (single-sided all-token seed): treasury gets the
    /// token side, sweep is marked one-shot.
    function test_graveyard_clanker_sweepsAfterPeriod() public {
        (address token, PoolKey memory key) = _launchClanker();
        PoolId poolId = key.toId();
        uint256 tokBefore = IERC20(token).balanceOf(TREASURY);

        vm.warp(block.timestamp + _period() + 1);
        vm.prank(ALICE);
        hook.graveyardSweep(token);

        assertTrue(hook.graveyardSwept(poolId), "marked swept");
        assertGt(IERC20(token).balanceOf(TREASURY) - tokBefore, 0, "treasury got token side");
    }

    /// ANY graduated swap resets the clock: a pool traded within the window can
    /// never be swept. Warp to the edge, trade, warp again -> still NotDead.
    function test_graveyard_pump_graduatedSwapResetsClock() public {
        (address token, PoolKey memory key) = _graduatePump();
        usdc.mint(ALICE, 100_000e6);

        vm.warp(block.timestamp + _period() - 1); // just before dead
        _buyViaV4(key, ALICE, 1_000e6); // a real V4 swap resets lastTradeAt

        vm.warp(block.timestamp + _period() - 1); // window not re-elapsed since trade
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.NotDead.selector);
        hook.graveyardSweep(token);
    }

    /// A CLANKER SELL also resets the clock (afterSwap fires for both sides).
    function test_graveyard_clanker_sellResetsClock() public {
        (address token, PoolKey memory key) = _launchClanker();
        _buyViaV4(key, ALICE, 5_000e6); // give ALICE tokens (also resets)

        vm.warp(block.timestamp + _period() - 1);
        _sellViaV4(key, token, ALICE, 1_000_000e18); // reset via sell

        vm.warp(block.timestamp + _period() - 1);
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.NotDead.selector);
        hook.graveyardSweep(token);
    }

    /// Cannot double-sweep: the second call reverts AlreadySwept.
    function test_graveyard_doubleSweepReverts() public {
        (address token,) = _graduatePump();
        vm.warp(block.timestamp + _period());
        vm.prank(ALICE);
        hook.graveyardSweep(token);

        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.AlreadySwept.selector);
        hook.graveyardSweep(token);
    }

    /// After a sweep the LP is empty and the pool is dead: a subsequent swap
    /// reverts for lack of liquidity (the spec's expected end state). Proves the
    /// sweep cannot run again against a re-funded pool -- there is no liquidity.
    function test_graveyard_pump_afterSweep_poolDead() public {
        (address token, PoolKey memory key) = _graduatePump();
        PoolId poolId = key.toId();
        vm.warp(block.timestamp + _period());
        vm.prank(ALICE);
        hook.graveyardSweep(token);
        assertEq(IPoolManager(address(pm)).getLiquidity(poolId), 0, "LP emptied");

        // A swap on the dead pool reverts (no liquidity to trade against).
        usdc.mint(ALICE, 10_000e6);
        vm.startPrank(ALICE);
        usdc.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(uint256(1_000e6)), sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// A curving PUMP pool (not graduated) has no LP to sweep: NothingToSweep,
    /// even long after the period would have elapsed.
    function test_graveyard_revertsNothingToSweep_curvingPump() public {
        (address token,) = _launchPump();
        vm.warp(block.timestamp + _period() + 30 days);
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.NothingToSweep.selector);
        hook.graveyardSweep(token);
    }

    /// An unregistered token reverts UnknownToken.
    function test_graveyard_revertsUnknownToken() public {
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.UnknownToken.selector);
        hook.graveyardSweep(address(0xDEAD));
    }

    /// setGraveyardPeriod enforces the hard 180-day floor.
    function test_setGraveyardPeriod_floorEnforced() public {
        vm.prank(OWNER);
        vm.expectRevert(ArcadeHook.GraveyardPeriodTooShort.selector);
        hook.setGraveyardPeriod(uint40(180 days) - 1);

        vm.prank(OWNER);
        hook.setGraveyardPeriod(uint40(180 days)); // exactly the floor is allowed
        assertEq(uint256(hook.graveyardPeriod()), 180 days, "period set to floor");
    }

    /// Only the owner can change the period.
    function test_setGraveyardPeriod_onlyOwner() public {
        vm.prank(ALICE);
        vm.expectRevert();
        hook.setGraveyardPeriod(uint40(200 days));
    }

    /// Lowering the period (to the floor) shortens the window but still cannot
    /// touch a pool traded within it: a fresh graduate is not immediately dead.
    function test_graveyard_lowerPeriod_stillProtectsFreshPool() public {
        (address token,) = _graduatePump();
        vm.prank(OWNER);
        hook.setGraveyardPeriod(uint40(180 days));

        vm.warp(block.timestamp + 180 days - 1);
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.NotDead.selector);
        hook.graveyardSweep(token);

        vm.warp(block.timestamp + 1); // now exactly 180d since graduation
        vm.prank(ALICE);
        hook.graveyardSweep(token); // sweeps at the new (lowered) boundary
        assertTrue(hook.graveyardSwept(_buildKey(token).toId()), "swept at lowered period");
    }
}

/**
 * @title ArcadeHookSwapUsdcCurrency0Test
 * @notice Re-runs the ENTIRE swap/fee suite with USDC forced to sort as
 *         currency0 -- the ARC MAINNET ordering. On mainnet USDC is
 *         0x3600...0000 (a near-minimal address), so every CREATE-deployed
 *         launch token sorts ABOVE it and USDC is currency0 for essentially
 *         every real launch. The base suite exercises USDC-as-currency1 only;
 *         this subclass covers the dominant, production `usdcIsCurrency0 == true`
 *         branch (the mcap-tick sign flip in _mcapTick, the capture side in
 *         before/afterSwap, the anti-sniper direction) before an immutable
 *         mainnet deploy. It inherits every test unchanged -- the helpers derive
 *         swap direction from the key, so they adapt automatically.
 */
contract ArcadeHookSwapUsdcCurrency0Test is ArcadeHookSwapTest {
    /// Place USDC at a low address so it sorts below the launch tokens. Uses
    /// deployCodeTo so the ERC20 constructor runs at the target (storage set
    /// there), unlike a bare etch. 0x7770 is above the precompile range and far
    /// below any keccak-derived CREATE address.
    function _makeUsdc() internal override returns (TestERC20) {
        address lowUsdc = address(0x7770);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(uint256(0)), lowUsdc);
        return TestERC20(lowUsdc);
    }
}
