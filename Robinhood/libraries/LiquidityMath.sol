// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Concentrated liquidity math for V4.
// getAmountsForLiquidity:  principal amounts from a position (used in graduationStatus).
// getLiquidityForAmount0:  liquidity for a one-sided token0-only position (price <= tickLower).
// getLiquidityForAmount1:  liquidity for a one-sided token1-only position (price >= tickUpper).
// getLiquidityForAmounts:  correct L given current price + both available amounts (use this for auto-liq).
library LiquidityMath {
    uint256 private constant Q96 = 0x1000000000000000000000000;

    // How much token0 and token1 a liquidity position currently represents.
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = _amount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = _amount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = _amount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = _amount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    // Liquidity for a one-sided token0-only position (price <= tickLower at launch).
    // L = amount0 * sqrtA * sqrtB / ((sqrtB - sqrtA) * Q96)
    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint128) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        uint256 intermediate = Math.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        uint256 liq = Math.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96);
        require(liq <= type(uint128).max, "LiquidityMath: overflow");
        return uint128(liq);
    }

    // Liquidity for a one-sided token1-only position (price >= tickUpper at launch).
    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        uint256 liq = Math.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96);
        require(liq <= type(uint128).max, "LiquidityMath: overflow");
        return uint128(liq);
    }

    // Three-case formula: picks the correct single or two-sided calculation based on where
    // the current price sits relative to [sqrtRatioAX96, sqrtRatioBX96].
    // Use this instead of getLiquidityForAmount0/1 when adding liquidity to an active pool.
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            return getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liq0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liq1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            return liq0 < liq1 ? liq0 : liq1;
        } else {
            return getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    function _amount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        private pure returns (uint256)
    {
        return Math.mulDiv(uint256(liquidity) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    function _amount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        private pure returns (uint256)
    {
        return Math.mulDiv(liquidity, sqrtB - sqrtA, Q96);
    }
}
