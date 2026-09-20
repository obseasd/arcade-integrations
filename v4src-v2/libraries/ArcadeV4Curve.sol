// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ArcadeV4Curve
 * @notice Pure curve math for the V4 ArcadeHook. Same constant-product shape as
 *         the V2 launchpad bonding curve, but as of 2026-07-17 the V4 curve is
 *         re-CALIBRATED and DIVERGES from V2 (see the constants block): it
 *         graduates opening the AMM at ~$60k FDV with price continuity, where V2
 *         keeps its 800M / ~$125k curve.
 *
 *         All values are integers, USDC has 6 decimals, launch tokens have 18.
 *         The library is stateless: callers pass in `tokensSold` and
 *         `realUsdcReserve`, the library returns the new state contribution and
 *         the caller persists it.
 *
 * @dev    Vectors are pinned INLINE in `v4test/ArcadeV4Curve.t.sol` (recomputed
 *         on any recalibration), NOT read from `curve-vectors.json`, which stays
 *         pinned to the V2 curve. Do not "sync" the two.
 *
 *         Rounding policy (from V4_HOOK_SPEC.md Section 4.3):
 *         - All `K / x` divisions floor by default.
 *         - The cap-path `capUsdcReserve` rounds UP when modulus is non-zero
 *           so the cap is reachable.
 *         - The cap-path `actualGross` rounds UP via ceil division so the
 *           user always covers the cap.
 *         - Round-trip invariant: buy(X) -> sell(received) must yield strictly
 *           less than X USDC. Tested in roundTripVectors.
 */
library ArcadeV4Curve {
    // -------------------------------------------------------------------
    // Constants (mirror src/launchpad/ArcadeLaunchpad.sol)
    // -------------------------------------------------------------------

    /// @notice Curve constants RE-CALIBRATED 2026-08-19 so the graduation
    ///         MIGRATION FEE is 1% of the raise (was a fixed 2,500 USDC = ~17.6%),
    ///         WHILE preserving the pump.fun price-continuity property (the AMM
    ///         opens at the curve's final marginal price, no cliff) and the
    ///         start ~$5k / graduation ~$60k FDV band.
    ///
    ///         The trick: VIRTUAL_TOKEN_RESERVE is set LARGER than TOTAL_SUPPLY,
    ///         so at graduation the virtual tokens remaining
    ///         (V_T - CURVE_SUPPLY = 317.2M) exceed the real tokens seeded into
    ///         the LP (TOTAL - CURVE_SUPPLY = 223M) by ~the amount that offsets
    ///         the virtual USDC reserve. Seeding all 223M migration tokens with
    ///         the raise MINUS the 1% migration fee then lands on the curve's
    ///         final marginal price to within ~0.003% -- and on the SAFE side
    ///         (the AMM opens fractionally BELOW marginal: seed 59.8110 vs
    ///         marginal 59.8127 microUSDC/token, so late curve buyers take a
    ///         negligible markdown rather than the first AMM buyer getting a free
    ///         profit). The migration "over-raise" is now structurally exactly
    ///         the 1% fee: the curve raises ~13,473 USDC, 1% (~134.7) goes to
    ///         treasury and the remaining ~13,338 seeds the LP at the continuous
    ///         price. Open FDV ~$59,813, start FDV ~$5,026. A PURE constant +
    ///         fee-formula calibration: no graduation-logic change, no token burn.
    ///
    ///         The V4 curve DIVERGES from the V2 production launchpad (which keeps
    ///         its own 800M / $125k constants); the V4 hook is the successor.
    ///         Only ~223M + 777M = 1B tokens are ever minted; the 94.2M excess in
    ///         VIRTUAL_TOKEN_RESERVE is a formula-only virtual reserve, never
    ///         minted (exactly like pump.fun's virtual tokens).
    uint256 internal constant VIRTUAL_USDC_RESERVE = 5_500e6;
    uint256 internal constant VIRTUAL_TOKEN_RESERVE = 1_094_200_000e18;
    uint256 internal constant CURVE_SUPPLY = 777_000_000e18;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIGRATION_LP_TOKENS = TOTAL_SUPPLY - CURVE_SUPPLY; // 223M
    uint256 internal constant K_CONSTANT = VIRTUAL_USDC_RESERVE * VIRTUAL_TOKEN_RESERVE;
    uint256 internal constant TRADE_FEE_BPS = 100; // 1%
    uint256 internal constant FEE_DENOMINATOR = 10_000;
    /// @notice Graduation migration fee, now 1% of the actual raise (was a fixed
    ///         2,500 USDC). Taken off the top of realUsdcReserve at graduation
    ///         before the LP is seeded, via `migrationFee()`. Structurally this
    ///         1% IS the curve's "over-raise" beyond what the LP needs to open at
    ///         the continuous price -- lowering it below 1% would open the AMM
    ///         ABOVE the curve's final price (an upward cliff), so it is coupled
    ///         to the reserve calibration above.
    uint256 internal constant MIGRATION_FEE_BPS = 100; // 1%
    /// @notice The realUsdcReserve value (approx) at graduation. Informational:
    ///         graduation is triggered by tokensSold >= CURVE_SUPPLY, not by
    ///         this. At CURVE_SUPPLY = 777M the curve raises ~13,473 USDC.
    uint256 internal constant GRADUATION_USDC = 13_473e6;

    // -------------------------------------------------------------------
    // Return structs
    // -------------------------------------------------------------------

    struct BuyResult {
        /// @notice Launch tokens delivered to the buyer (18 dp).
        uint256 tokensOut;
        /// @notice USDC the curve actually consumes for this buy. May be less
        ///         than `grossUsdcIn` when the buy hits the graduation cap and
        ///         the residual is refunded.
        uint256 actualGross;
        /// @notice Curve fee taken from `actualGross` (1% of actualGross).
        uint256 fee;
        /// @notice Refund to the buyer when `actualGross < grossUsdcIn`.
        uint256 refund;
    }

    struct SellResult {
        /// @notice USDC withdrawn from `realUsdcReserve` (before fee).
        uint256 grossOut;
        /// @notice USDC paid to the seller after curve fee.
        uint256 usdcOut;
        /// @notice Curve fee taken from `grossOut` (1% of grossOut).
        uint256 fee;
    }

    // -------------------------------------------------------------------
    // Buy
    // -------------------------------------------------------------------

    /**
     * @notice Simulate a curve buy. Returns the math result without mutating
     *         anything. Mirrors the V2 launchpad's `_computeBuy` exactly.
     *
     * @param tokensSold       Current `state.tokensSold` (18 dp).
     * @param realUsdcReserve  Current `state.realUsdcReserve` (6 dp).
     * @param grossUsdcIn      USDC the buyer is willing to spend (6 dp).
     *
     *         Caller MUST then apply:
     *           state.tokensSold       += result.tokensOut
     *           state.realUsdcReserve  += result.actualGross - result.fee
     *         and refund `result.refund` USDC to the buyer if non-zero.
     *
     *         When `tokensSold + result.tokensOut == CURVE_SUPPLY` the curve
     *         is graduated and the caller MUST trigger the graduation routine
     *         on the SAME tx.
     */
    function simulateBuy(uint256 tokensSold, uint256 realUsdcReserve, uint256 grossUsdcIn)
        internal
        pure
        returns (BuyResult memory r)
    {
        if (grossUsdcIn == 0) return r;
        if (tokensSold >= CURVE_SUPPLY) return r; // curve already at cap

        uint256 fee = (grossUsdcIn * TRADE_FEE_BPS) / FEE_DENOMINATOR;
        uint256 netIn = grossUsdcIn - fee;

        uint256 currentUsdc = VIRTUAL_USDC_RESERVE + realUsdcReserve;
        uint256 currentTokens = VIRTUAL_TOKEN_RESERVE - tokensSold;

        uint256 newUsdcReserve = currentUsdc + netIn;
        uint256 newTokenReserve = K_CONSTANT / newUsdcReserve; // floor
        uint256 desiredOut = currentTokens - newTokenReserve;

        uint256 maxOut = CURVE_SUPPLY - tokensSold;

        if (desiredOut <= maxOut) {
            r.tokensOut = desiredOut;
            r.actualGross = grossUsdcIn;
            r.fee = fee;
            r.refund = 0;
            return r;
        }

        // Cap path: this buy crosses CURVE_SUPPLY. Tighten to the exact tokens
        // remaining and compute the precise USDC the curve will accept; the
        // rest is refunded.
        uint256 capTokenReserve = currentTokens - maxOut;
        uint256 capUsdcReserve = K_CONSTANT / capTokenReserve; // floor
        if (K_CONSTANT % capTokenReserve != 0) {
            // Bump by 1 wei to ensure the cap is REACHABLE (the floor on its
            // own would leave the curve a hair short of capacity).
            capUsdcReserve += 1;
        }
        uint256 actualNet = capUsdcReserve - currentUsdc;
        // ceil(actualNet * 10_000 / (10_000 - 100)) ensures the user pays a
        // tax that covers the cap rather than rounding down to a fee that
        // would let the curve be undercharged by 1 wei.
        uint256 numerator = actualNet * FEE_DENOMINATOR;
        uint256 denominator = FEE_DENOMINATOR - TRADE_FEE_BPS;
        uint256 actualGross = (numerator + denominator - 1) / denominator;
        if (actualGross > grossUsdcIn) {
            // Pathological: rounding pushed cost above the user's input. Clip
            // to the input. The cap will be ALMOST-reached; final dust drops
            // on the floor and the next buy clears it.
            actualGross = grossUsdcIn;
        }
        uint256 actualFee = (actualGross * TRADE_FEE_BPS) / FEE_DENOMINATOR;

        r.tokensOut = maxOut;
        r.actualGross = actualGross;
        r.fee = actualFee;
        r.refund = grossUsdcIn - actualGross;
    }

    // -------------------------------------------------------------------
    // Sell
    // -------------------------------------------------------------------

    /**
     * @notice Simulate a curve sell. Returns the math result without mutating
     *         anything. Mirrors the V2 launchpad's `_computeSell` exactly.
     *
     * @param tokensSold       Current `state.tokensSold` (18 dp).
     * @param realUsdcReserve  Current `state.realUsdcReserve` (6 dp).
     * @param tokensIn         Launch tokens the seller is sending in (18 dp).
     *
     *         Caller MUST then apply:
     *           state.tokensSold       -= tokensIn
     *           state.realUsdcReserve  -= result.grossOut
     *         and pay `result.usdcOut` USDC to the seller.
     */
    function simulateSell(uint256 tokensSold, uint256 realUsdcReserve, uint256 tokensIn)
        internal
        pure
        returns (SellResult memory r)
    {
        if (tokensIn == 0) return r;
        if (tokensIn > tokensSold) {
            // Defensive: cannot sell more than the curve has issued.
            tokensIn = tokensSold;
        }

        uint256 currentUsdc = VIRTUAL_USDC_RESERVE + realUsdcReserve;
        uint256 currentTokens = VIRTUAL_TOKEN_RESERVE - tokensSold;

        uint256 newTokenReserve = currentTokens + tokensIn;
        uint256 newUsdcReserve = K_CONSTANT / newTokenReserve; // floor
        // V2 production behavior: this subtraction is unchecked and would
        // revert on underflow when floor rounding produces newUsdcReserve >
        // currentUsdc (degenerate dust sells deep in the curve). V4 must NOT
        // revert from a hook callback because it would brick the user's swap
        // through no fault of their own. No-op instead.
        if (newUsdcReserve >= currentUsdc) return r;
        uint256 grossOut = currentUsdc - newUsdcReserve;
        if (grossOut > realUsdcReserve) {
            // Dust safeguard: floor rounding on K/newTokenReserve can produce a
            // grossOut that exceeds the actually-collected USDC by a few wei.
            // Clip to the real reserve so we never overpay.
            grossOut = realUsdcReserve;
        }

        uint256 fee = (grossOut * TRADE_FEE_BPS) / FEE_DENOMINATOR;
        r.grossOut = grossOut;
        r.usdcOut = grossOut - fee;
        r.fee = fee;
    }

    // -------------------------------------------------------------------
    // Convenience views
    // -------------------------------------------------------------------

    /**
     * @notice Spot price = quote / base, expressed as USDC (6 dp) per 10**18
     *         of launch token. Useful for UI display and quotes; NOT used by
     *         the curve math itself, which always derives from K.
     */
    function spotPrice(uint256 tokensSold, uint256 realUsdcReserve) internal pure returns (uint256) {
        uint256 currentUsdc = VIRTUAL_USDC_RESERVE + realUsdcReserve;
        uint256 currentTokens = VIRTUAL_TOKEN_RESERVE - tokensSold;
        if (currentTokens == 0) return 0;
        return (currentUsdc * 1e18) / currentTokens;
    }

    /**
     * @notice True when the curve has graduated (sold all of CURVE_SUPPLY).
     *         Callers MUST use this rather than checking `realUsdcReserve >=
     *         GRADUATION_USDC` directly, because the cap path leaves a few
     *         wei of headroom in `realUsdcReserve` on graduation.
     */
    function isGraduated(uint256 tokensSold) internal pure returns (bool) {
        return tokensSold >= CURVE_SUPPLY;
    }

    /**
     * @notice The migration fee taken at graduation: 1% (MIGRATION_FEE_BPS) of
     *         the raise. Single source of truth for both `graduationLiquidityUsdc`
     *         and `ArcadeHookLib.graduate()`.
     */
    function migrationFee(uint256 realUsdcReserveAtGrad) internal pure returns (uint256) {
        return (realUsdcReserveAtGrad * MIGRATION_FEE_BPS) / FEE_DENOMINATOR;
    }

    /**
     * @notice USDC available to seed the V2/V4 graduation pool. Equals
     *         realUsdcReserve - migrationFee(realUsdcReserve) at graduation; the
     *         1% fee is taken off the top before the LP is funded. Seeding the
     *         223M migration tokens with this amount opens the AMM at the curve's
     *         final marginal price (continuity: the 1% over-raise IS the fee).
     */
    function graduationLiquidityUsdc(uint256 realUsdcReserveAtGrad) internal pure returns (uint256) {
        return realUsdcReserveAtGrad - migrationFee(realUsdcReserveAtGrad);
    }
}
