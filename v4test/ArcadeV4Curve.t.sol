// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ArcadeV4Curve} from "../v4src/libraries/ArcadeV4Curve.sol";

/**
 * @title ArcadeV4CurveTest
 * @notice Vector suite pinning the V4 curve library's exact outputs. As of
 *         2026-07-17 the V4 curve DIVERGES from the V2 production launchpad:
 *         it is calibrated (VIRTUAL_USDC 5.8k, VIRTUAL_TOKEN 1.135B > 1B supply,
 *         CURVE_SUPPLY 806M) so a launch graduates opening the AMM at ~$60k FDV
 *         WITH price continuity (the seed price equals the curve's final
 *         marginal price -- see test_graduation_seedPriceEqualsMarginal_noCliff).
 *         Vectors are inline (recomputed on any recalibration), NOT read from
 *         the shared curve-vectors.json fixture, which stays pinned to V2.
 *
 *         Dust sells (`tiny-sell`) that would underflow to a negative grossOut
 *         no-op to zeros here (V2 on-chain reverts); reverting a user's dust
 *         sell is poor UX in V4 where the hook is called from every swap.
 */
contract ArcadeV4CurveTest is Test {
    using ArcadeV4Curve for *;

    // -------------------------------------------------------------------
    // Constants surfaced for read-back assertions
    // -------------------------------------------------------------------

    /// V4 curve constants. The V4 curve DIVERGES from the V2 launchpad. As of
    /// 2026-08-19 it is RE-calibrated (VIRTUAL_USDC 5.5k, VIRTUAL_TOKEN 1.0942B >
    /// 1B supply, CURVE_SUPPLY 777M) so the AMM OPENS at ~$60k FDV with price
    /// continuity AND the migration fee is 1% of the raise (was a fixed 2,500).
    /// VIRTUAL_USDC/TOKEN/K/supply all changed vs the prior build, so every
    /// vector was recomputed. Start FDV ~$5k (a ~12x curve).
    function test_constants_v4Curve() public pure {
        assertEq(ArcadeV4Curve.VIRTUAL_USDC_RESERVE, 5_500e6, "virtual usdc");
        // VIRTUAL_TOKEN_RESERVE is LARGER than TOTAL_SUPPLY (1B) on purpose:
        // the 94.2M excess is a formula-only virtual reserve (never minted) that
        // makes the AMM seed land exactly on the curve's final price (0 cliff).
        assertEq(ArcadeV4Curve.VIRTUAL_TOKEN_RESERVE, 1_094_200_000e18, "virtual tokens");
        assertEq(ArcadeV4Curve.CURVE_SUPPLY, 777_000_000e18, "curve supply (calibrated)");
        assertEq(ArcadeV4Curve.MIGRATION_LP_TOKENS, 223_000_000e18, "lp supply");
        assertEq(ArcadeV4Curve.K_CONSTANT, 6_018_100_000_000_000_000_000_000_000_000_000_000, "K");
        assertEq(ArcadeV4Curve.TRADE_FEE_BPS, 100, "trade fee");
        assertEq(ArcadeV4Curve.MIGRATION_FEE_BPS, 100, "migration fee bps (1%)");
        assertEq(ArcadeV4Curve.GRADUATION_USDC, 13_473e6, "graduation usdc (calibrated)");
    }

    // -------------------------------------------------------------------
    // Buy vectors (5 total in the fixture)
    // -------------------------------------------------------------------

    function test_buy_tinyBuyEmptyCurve() public pure {
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(0, 0, 1_000_000);
        assertEq(r.tokensOut, 196_920_554_300_225_959_327_322, "tokensOut");
        assertEq(r.actualGross, 1_000_000, "actualGross");
        assertEq(r.refund, 0, "refund");
        // state update: realUsdcReserve += actualGross - fee = 1_000_000 - 10_000 = 990_000
        assertEq(r.actualGross - r.fee, 990_000, "net to reserve");
    }

    function test_buy_smallBuyEmptyCurve() public pure {
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(0, 0, 100_000_000);
        assertEq(r.tokensOut, 19_347_347_740_667_976_424_361_494, "tokensOut");
        assertEq(r.actualGross, 100_000_000, "actualGross");
        assertEq(r.refund, 0, "refund");
        assertEq(r.actualGross - r.fee, 99_000_000, "net to reserve");
    }

    function test_buy_largeBuyEmptyCurve() public pure {
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(0, 0, 5_000_000_000);
        assertEq(r.tokensOut, 518_305_263_157_894_736_842_105_264, "tokensOut");
        assertEq(r.actualGross, 5_000_000_000, "actualGross");
        assertEq(r.refund, 0, "refund");
        assertEq(r.actualGross - r.fee, 4_950_000_000, "net to reserve");
    }

    function test_buy_midCurve() public pure {
        // Reserve is the consistent value at 200M sold: K/(V_T-200M) - V_U.
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(
            200_000_000_000_000_000_000_000_000, 1_230_149_854, 100_000_000
        );
        assertEq(r.tokensOut, 12_962_931_161_182_277_374_579_926, "tokensOut");
        assertEq(r.actualGross, 100_000_000, "actualGross");
        assertEq(r.refund, 0, "refund");
        assertEq(r.actualGross - r.fee, 99_000_000, "net to reserve");
    }

    function test_buy_nearGraduation() public pure {
        // 771M sold (6M below the 777M cap). Consistent reserve = K/(V_T-771M)
        // - V_U. A 100 USDC buy gets ~1.71M tokens (< 6M remaining) -> normal
        // path, not a cap.
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(
            771_000_000_000_000_000_000_000_000, 13_120_358_910, 100_000_000
        );
        assertEq(r.tokensOut, 1_709_289_290_612_784_131_932_647, "tokensOut");
        assertEq(r.actualGross, 100_000_000, "actualGross");
        assertEq(r.refund, 0, "refund");
        assertEq(r.actualGross - r.fee, 99_000_000, "net to reserve");
    }

    function test_buy_exactGraduation() public pure {
        // Cap path: this buy exactly fills the curve to 777M, with refund.
        // 776M sold, consistent reserve = K/(V_T-776M) - V_U.
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(
            776_000_000_000_000_000_000_000_000, 13_412_947_831, 5_000_000_000
        );
        assertEq(r.tokensOut, 1_000_000_000_000_000_000_000_000, "tokensOut");
        assertEq(r.actualGross, 60_226_949, "actualGross");
        assertEq(r.refund, 4_939_773_051, "refund");
        // The curve graduates exactly. tokensSoldAfter = CURVE_SUPPLY.
        assertEq(
            r.tokensOut + 776_000_000_000_000_000_000_000_000,
            ArcadeV4Curve.CURVE_SUPPLY,
            "exact graduation"
        );
        assertEq(r.actualGross + r.refund, 5_000_000_000, "gross sums");
    }

    function test_buy_capHitMassive() public pure {
        // Cap path from empty curve: user wants to spend 30k USDC, gets all 777M.
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(0, 0, 30_000_000_000);
        assertEq(r.tokensOut, 777_000_000_000_000_000_000_000_000, "tokensOut == CURVE_SUPPLY");
        assertEq(r.actualGross, 13_608_659_102, "actualGross");
        assertEq(r.refund, 16_391_340_898, "refund");
        // Sanity: actualGross + refund == grossUsdcIn
        assertEq(r.actualGross + r.refund, 30_000_000_000, "gross sums");
    }

    function test_buy_dustRoundingSensitivity() public pure {
        // 1 microUSDC buy from empty curve. Lowest-floor edge case.
        ArcadeV4Curve.BuyResult memory r = ArcadeV4Curve.simulateBuy(0, 0, 1);
        assertEq(r.tokensOut, 198_945_454_509_282_645, "tokensOut");
        assertEq(r.actualGross, 1, "actualGross");
        assertEq(r.refund, 0, "refund");
        // 1% fee on 1 microUSDC floors to 0, so all of it goes to reserve.
        assertEq(r.fee, 0, "fee floors to zero");
    }

    // -------------------------------------------------------------------
    // Sell vectors (4 total; tiny-sell underflow is no-op'd in V4)
    // -------------------------------------------------------------------

    function test_sell_normalEarlyCurve() public pure {
        // 100M sold, consistent reserve = K/(V_T-100M) - V_U; sell 10M tokens.
        ArcadeV4Curve.SellResult memory r = ArcadeV4Curve.simulateSell(
            100_000_000_000_000_000_000_000_000,
            553_208_609,
            10_000_000_000_000_000_000_000_000
        );
        assertEq(r.usdcOut, 59_676_125, "usdcOut");
        assertEq(r.grossOut, 60_278_914, "grossOut");
        assertEq(r.fee, 602_789, "fee");
    }

    function test_sell_nearGraduation() public pure {
        // 771M sold, consistent reserve = K/(V_T-771M) - V_U; sell 50M tokens.
        ArcadeV4Curve.SellResult memory r = ArcadeV4Curve.simulateSell(
            771_000_000_000_000_000_000_000_000,
            13_120_358_910,
            50_000_000_000_000_000_000_000_000
        );
        assertEq(r.usdcOut, 2_469_742_138, "usdcOut");
        assertEq(r.grossOut, 2_494_689_028, "grossOut");
        assertEq(r.fee, 24_946_890, "fee");
    }

    function test_sell_dust_returnsZeros() public pure {
        // Dust sell from a near-empty curve: math floors to a no-op.
        ArcadeV4Curve.SellResult memory r = ArcadeV4Curve.simulateSell(1_000_000_000_000_000_000, 5, 1);
        assertEq(r.usdcOut, 0, "usdcOut");
        assertEq(r.grossOut, 0, "grossOut");
        assertEq(r.fee, 0, "fee");
    }

    function test_sell_tinySellUnderflow_returnsZeros_notRevert() public pure {
        // Fixture documents this as math underflow (grossOut = -4999).
        // V2 would revert. V4 library returns zeros so the hook's swap call
        // does not bomb the user's tx on a dust-sized sell.
        ArcadeV4Curve.SellResult memory r = ArcadeV4Curve.simulateSell(
            1_000_000_000_000_000_000_000_000,
            5_000_000,
            1_000_000_000_000_000_000
        );
        assertEq(r.usdcOut, 0, "usdcOut");
        assertEq(r.grossOut, 0, "grossOut");
        assertEq(r.fee, 0, "fee");
    }

    // -------------------------------------------------------------------
    // Round-trip invariant: buy(X) -> sell(received) must yield strictly less
    // than X USDC. The curve always wins.
    // -------------------------------------------------------------------

    function test_roundTrip_small_curveAlwaysWins() public pure {
        // Buy 100 USDC from empty curve.
        ArcadeV4Curve.BuyResult memory b = ArcadeV4Curve.simulateBuy(0, 0, 100_000_000);
        // Apply state transition.
        uint256 newTokensSold = 0 + b.tokensOut;
        uint256 newRealUsdc = 0 + (b.actualGross - b.fee);
        // Sell the tokens just acquired.
        ArcadeV4Curve.SellResult memory s = ArcadeV4Curve.simulateSell(newTokensSold, newRealUsdc, b.tokensOut);
        // INVARIANT: user paid 100_000_000, gets back strictly less.
        assertLt(s.usdcOut, 100_000_000, "round-trip must lose to curve");
        // The fixture's reference is 98_010_000.
        assertEq(s.usdcOut, 98_010_000, "matches V2 round-trip output");
    }

    function test_roundTrip_medium_curveAlwaysWins() public pure {
        ArcadeV4Curve.BuyResult memory b = ArcadeV4Curve.simulateBuy(0, 0, 1_000_000_000);
        uint256 newTokensSold = b.tokensOut;
        uint256 newRealUsdc = b.actualGross - b.fee;
        ArcadeV4Curve.SellResult memory s = ArcadeV4Curve.simulateSell(newTokensSold, newRealUsdc, b.tokensOut);
        assertLt(s.usdcOut, 1_000_000_000, "round-trip must lose");
        assertEq(s.usdcOut, 980_100_000, "matches V2 round-trip output");
    }

    // -------------------------------------------------------------------
    // Convenience view checks
    // -------------------------------------------------------------------

    function test_spotPrice_emptyCurve() public pure {
        uint256 p = ArcadeV4Curve.spotPrice(0, 0);
        // VIRTUAL_USDC * 1e18 / VIRTUAL_TOKEN = 5_500e6 * 1e18 / 1_094_200_000e18
        // = 5. Start FDV = 5.0265 * 1e9 / 1e6 = ~$5,026 (rounds to 5 at the
        // microUSDC/token unit).
        assertEq(p, 5, "5 microUSDC per token at curve start");
    }

    function test_spotPrice_atGraduation_isHigher() public pure {
        uint256 pStart = ArcadeV4Curve.spotPrice(0, 0);
        uint256 pEnd = ArcadeV4Curve.spotPrice(ArcadeV4Curve.CURVE_SUPPLY, ArcadeV4Curve.GRADUATION_USDC);
        // Price at graduation is much higher than at the start. The retuned
        // curve is ~12x start->graduation (was ~25x), so assert > 10x.
        // pEnd = 59, pStart = 5 -> 59 > 50.
        assertGt(pEnd, pStart * 10, "graduation price > 10x start price");
    }

    function test_isGraduated_atCap() public pure {
        assertFalse(ArcadeV4Curve.isGraduated(ArcadeV4Curve.CURVE_SUPPLY - 1), "not yet");
        assertTrue(ArcadeV4Curve.isGraduated(ArcadeV4Curve.CURVE_SUPPLY), "at cap");
    }

    // Consistent real reserve at a given tokensSold: K/(V_T - sold) - V_U.
    function _reserveAt(uint256 sold) internal pure returns (uint256) {
        return ArcadeV4Curve.K_CONSTANT / (ArcadeV4Curve.VIRTUAL_TOKEN_RESERVE - sold)
            - ArcadeV4Curve.VIRTUAL_USDC_RESERVE;
    }

    /// The whole point of the calibration: the AMM seeds at the curve's FINAL
    /// MARGINAL PRICE (to within ~0.003%, on the safe side -- see the
    /// ArcadeV4Curve constants NatSpec), so the pool opens ~where the curve
    /// ended instead of the naive seeding's cliff. At the spotPrice unit
    /// (microUSDC per 1e18 token) both round to 59, so seed == marginal here;
    /// the sub-unit residual is the migration fee. The RE-calibration made the
    /// migration fee 1% of the raise (not a fixed 2,500), and the reserves were
    /// re-tuned so that 1% over-raise IS exactly the continuity offset. This
    /// works because VIRTUAL_TOKEN_RESERVE > TOTAL_SUPPLY (pump.fun's method).
    /// If someone "rounds" VIRTUAL_TOKEN_RESERVE back to 1B this test fails,
    /// guarding it.
    function test_graduation_seedPriceEqualsMarginal_noCliff() public pure {
        uint256 realAtGrad = _reserveAt(ArcadeV4Curve.CURVE_SUPPLY);
        uint256 marginal = ArcadeV4Curve.spotPrice(ArcadeV4Curve.CURVE_SUPPLY, realAtGrad);
        uint256 lpUsdc = ArcadeV4Curve.graduationLiquidityUsdc(realAtGrad);
        uint256 seedPrice = (lpUsdc * 1e18) / ArcadeV4Curve.MIGRATION_LP_TOKENS;
        assertEq(seedPrice, marginal, "AMM opens at curve marginal price (0 cliff)");
        // Fractional invariant: seed must be on the SAFE side (at-or-below the
        // curve's marginal price), never above (which would be an upward cliff
        // handing the first AMM buyer a free profit). seed 59.8110 <= 59.8127.
        uint256 seedScaled = (lpUsdc * 1e30) / ArcadeV4Curve.MIGRATION_LP_TOKENS;
        uint256 margScaled = ((ArcadeV4Curve.VIRTUAL_USDC_RESERVE + realAtGrad) * 1e30)
            / (ArcadeV4Curve.VIRTUAL_TOKEN_RESERVE - ArcadeV4Curve.CURVE_SUPPLY);
        assertLe(seedScaled, margScaled, "seed price must be <= marginal (safe side)");
        // ...and within ~1% of it (continuity, no cliff). Delta here is ~0.003%.
        assertGt(seedScaled * 100, margScaled * 99, "seed within 1% of marginal");
        // And that price is the ~$60k open FDV target (~60 microUSDC/token * 1B).
        assertEq(marginal, 59, "graduation marginal ~= $60k FDV");
    }

    function test_migrationFee_isOnePercentOfRaise() public pure {
        // The migration fee is exactly 1% of the raise (MIGRATION_FEE_BPS = 100),
        // and far below the OLD fixed 2_500 USDC. At graduation the raise is
        // ~13_472.57 USDC so the fee is ~134.73 USDC.
        uint256 realAtGrad = _reserveAt(ArcadeV4Curve.CURVE_SUPPLY);
        uint256 fee = ArcadeV4Curve.migrationFee(realAtGrad);
        assertEq(fee, realAtGrad / 100, "fee == 1% of raise");
        assertEq(fee, 134_725_725, "~134.73 USDC at graduation");
        assertLt(fee, 2_500e6, "far below the old fixed 2,500 fee");
        // LP receives the other 99%.
        assertEq(ArcadeV4Curve.graduationLiquidityUsdc(realAtGrad), realAtGrad - fee, "LP gets 99%");
    }

    function test_graduationLiquidityUsdc_subtractsFee() public pure {
        uint256 liq = ArcadeV4Curve.graduationLiquidityUsdc(20_000e6);
        // 20_000 USDC raised minus 1% (200 USDC) migration fee = 19_800 for LP.
        assertEq(ArcadeV4Curve.migrationFee(20_000e6), 200e6, "1% fee on 20k raise");
        assertEq(liq, 19_800e6, "19.8k USDC for LP seed");
    }

    // -------------------------------------------------------------------
    // Fuzz: round-trip invariant holds for arbitrary buy sizes
    // -------------------------------------------------------------------

    function testFuzz_roundTrip_curveAlwaysWins(uint64 grossUsdcIn) public pure {
        // Bound to plausible inputs that won't hit the cap path (the retuned
        // curve caps at ~13.6k USDC of gross input).
        uint256 input = uint256(grossUsdcIn) % 13_000_000_000; // < 13_000 USDC
        vm.assume(input > 1_000_000); // > 1 USDC: below that, fee rounds to 0 and the
                                       // invariant is degenerate.

        ArcadeV4Curve.BuyResult memory b = ArcadeV4Curve.simulateBuy(0, 0, input);
        if (b.tokensOut == 0) return; // edge: buy too small to produce output

        uint256 newSold = b.tokensOut;
        uint256 newReserve = b.actualGross - b.fee;

        ArcadeV4Curve.SellResult memory s = ArcadeV4Curve.simulateSell(newSold, newReserve, b.tokensOut);

        // INVARIANT: a buy-then-sell round trip MUST lose USDC to the curve.
        // The curve fee is 2 * 1% = ~2% so user should always lose at least 1%.
        assertLe(s.usdcOut, input, "round trip cannot profit user");
    }
}
