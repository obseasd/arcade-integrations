// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

/// @title ArcadeV4Math
/// @notice EXTERNAL library holding the pure V4 pricing/liquidity math for
///         ArcadeHook. Deployed once and delegatecalled: it carries the bulky
///         inlined TickMath / LiquidityAmounts / FullMath code so the immutable
///         ArcadeHook stays under the EIP-170 24576-byte deploy limit (Arc
///         enforces it). Pure math only, so the delegatecall context is
///         irrelevant to behaviour -- every function is a faithful move of what
///         used to be inline in the hook (verified by the unchanged 145-test
///         suite).
library ArcadeV4Math {
    error ZeroAmount();
    error InvariantBroken();

    /// @notice sqrtPriceX96 from raw token amounts. price = amount1 / amount0.
    ///         FullMath 512-bit multiply, then Babylonian sqrt.
    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) public pure returns (uint160) {
        if (amount0 == 0) revert ZeroAmount();
        uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);
        uint256 root = _sqrt(ratioX192);
        if (root > type(uint160).max) revert InvariantBroken();
        return uint160(root);
    }

    /// @notice Full usable tick range for a spacing (graduation two-sided seed).
    function fullRange(int24 spacing) public pure returns (int24 lower, int24 upper) {
        return (TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing));
    }

    /// @notice The single-sided CLANKER seed edge tick: align the start tick to
    ///         `spacing` so the full-supply position sits ENTIRELY on the launch
    ///         token's side of the current price (never straddling, which would
    ///         need USDC the hook does not hold).
    ///         token=currency1 (usdcIsCurrency0) -> upper edge, FLOOR;
    ///         token=currency0                    -> lower edge, strict CEIL.
    function seedEdgeTick(uint160 startSqrt, int24 spacing, bool usdcIsCurrency0)
        public
        pure
        returns (int24 aligned)
    {
        int24 startTick = TickMath.getTickAtSqrtPrice(startSqrt);
        aligned = (startTick / spacing) * spacing; // trunc toward zero
        if (usdcIsCurrency0) {
            // token = currency1: tickUpper must be <= currentTick (all currency1).
            // aligned == currentTick is already single-sided; only step DOWN a
            // truncated-up (negative) tick.
            if (startTick < 0 && startTick % spacing != 0) aligned -= spacing;
        } else {
            // token = currency0: tickLower must be STRICTLY above currentTick, else
            // the position is in-range and needs USDC. Step up whenever aligned <=
            // currentTick (positive boundary + positive/negative non-boundary).
            if (aligned <= startTick) aligned += spacing;
        }
    }

    /// @notice Two-sided liquidity for the graduation full-range seed.
    function liquidityForAmounts(uint160 sqrtPriceX96, int24 lower, int24 upper, uint256 amount0, uint256 amount1)
        public
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
    }

    /// @notice Single-sided liquidity for an all-currency0 position (token=c0).
    function liquidityForAmount0(int24 lower, int24 upper, uint256 amount) public pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
        );
    }

    /// @notice Single-sided liquidity for an all-currency1 position (token=c1).
    function liquidityForAmount1(int24 lower, int24 upper, uint256 amount) public pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
        );
    }

    /// @dev Integer square root via Babylonian iteration (one-shot seed calls).
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) >> 1;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
    }
}
