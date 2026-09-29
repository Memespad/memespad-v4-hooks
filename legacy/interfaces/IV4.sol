// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Inlined V4 interfaces — no npm lock-in.
// Confirmed against Robinhood testnet:
//   PoolManager:      0x8366a39CC670B4001A1121B8F6A443A643e40951
//   PositionManager:  0x58daec3116aae6D93017bAAea7749052E8a04fA7
//   Permit2:          0x000000000022D473030F116dDEE9F6B43aC78BA3

type Currency        is address;
type BalanceDelta    is int256;
type BeforeSwapDelta is int256;

struct PoolKey {
    Currency currency0;  // ETH = address(0), always lower
    Currency currency1;  // the launched token
    uint24   fee;
    int24    tickSpacing;
    address  hooks;
}

struct SwapParams {
    bool    zeroForOne;       // true = ETH→token (buy), false = token→ETH (sell)
    int256  amountSpecified;  // negative = exact input, positive = exact output
    uint160 sqrtPriceLimitX96;
}

// ── BalanceDelta helpers ──────────────────────────────────────────────────────
// amount0 = upper 128 bits, amount1 = lower 128 bits.
// From the SWAPPER's perspective: negative = currency flows OUT (they pay), positive = flows IN.
library BalanceDeltaLib {
    function amount0(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d) >> 128);
    }
    function amount1(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d));
    }
}

// Pack (specifiedDelta, unspecifiedDelta) into BeforeSwapDelta for hook return.
function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
    pure returns (BeforeSwapDelta)
{
    return BeforeSwapDelta.wrap(
        (int256(deltaSpecified) << 128) | int256(uint256(uint128(deltaUnspecified)))
    );
}

// ── Interfaces ────────────────────────────────────────────────────────────────

struct ModifyLiquidityParams {
    int24   tickLower;
    int24   tickUpper;
    int256  liquidityDelta;  // positive = add, negative = remove
    bytes32 salt;
}

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory result);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (BalanceDelta);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);
    function settle() external payable returns (uint256 paid);
    function take(Currency currency, address to, uint256 amount) external;
    function sync(Currency currency) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

// StateView: reads live pool state from PoolManager without requiring an unlock.
// Deploy address varies by network — set to address(0) on testnet if not available.
interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (
        uint160 sqrtPriceX96,
        int24   tick,
        uint24  protocolFee,
        uint24  lpFee
    );
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}
