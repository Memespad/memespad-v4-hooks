// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard}       from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast}               from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20}                 from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}              from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Currency,
    BalanceDelta,
    BeforeSwapDelta,
    PoolKey,
    SwapParams,
    ModifyLiquidityParams,
    BalanceDeltaLib,
    toBeforeSwapDelta,
    IPoolManager
} from "./interfaces/IV4.sol";
import {TickMath}      from "./libraries/TickMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";

// ── External interfaces ───────────────────────────────────────────────────────

interface IPoolManagerTake {
    function take(Currency currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256);
    function sync(Currency currency) external;
}

interface IMemespadFactory {
    struct LaunchedTokenInfo {
        address deployer;
        uint256 positionId;
        int24   tickLower;
        int24   tickUpper;
        uint256 graduationThreshold;
        bool    exists;
        bool    graduated;
        address quoteToken;
        bool    tokenIsZero;
    }
    function tokenCreator(address token) external view returns (address);
    function recordSwap(address token, bool isBuy, uint256 quoteAmount) external;
    function launchedTokens(address token) external view returns (LaunchedTokenInfo memory);
}

interface IMemespadTax {
    function distribute(
        address token,
        address creator,
        address quoteToken,
        uint256 creatorFee,
        uint256 platformFee
    ) external payable;
}

interface IDividendPool {
    function creditDividend(address token, uint256 amount) external payable;
    function creditDividendERC20(address token, address quoteToken, uint256 amount) external;
}

// ── MemespadHook ──────────────────────────────────────────────────────────────
//
// Uniswap V4 hook. On every swap it takes a creator-set tax (buy% and sell%)
// and routes it across four buckets:
//
//   creatorAlloc  → MemespadTax.distribute() → creator wallet / platform
//   burnAlloc     → pendingBurn → buy token from pool → burn to 0xdead
//   dividendAlloc → pendingDiv  → flush to MemespadDividendPool when threshold hit
//   liquidityAlloc→ pendingLiq  → swap half + mint new LP position → burn NFT to 0xdead
//
// Platform always receives at least 30% of each swap's tax (enforced at registration).
//
// Address requirement: lower 14 bits == 0x00CC
//   bit 7  beforeSwap             0x0080
//   bit 6  afterSwap              0x0040
//   bit 3  beforeSwapReturnDelta  0x0008
//   bit 2  afterSwapReturnDelta   0x0004

contract MemespadHook is Ownable2Step, ReentrancyGuard {
    using BalanceDeltaLib for BalanceDelta;
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOM              = 10_000;
    uint256 public constant MAX_TAX_BPS            = 1_000;   // 10% max total tax
    uint256 public constant PLATFORM_MIN_BPS       = 3_000;   // 30% platform floor
    uint256 public constant MAX_FAIR_LAUNCH_WINDOW = 3_600;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable poolManager;
    IMemespadFactory public factory;
    address public immutable tax;
    address public dividendPool;

    address public treasury;
    uint256 public fairLaunchWindow = 300;
    uint256 public maxBuyQuote      = 0.5 ether;
    uint256 public burnDustThreshold = 0.01 ether;

    // ── Per-token state ───────────────────────────────────────────────────────

    struct TaxParams {
        uint16  buyTaxBps;
        uint16  sellTaxBps;
        uint16  creatorAllocBps;   // of total tax → creator (via MemespadTax)
        uint16  burnAllocBps;      // of total tax → burn bucket
        uint16  dividendAllocBps;  // of total tax → dividend bucket
        uint16  liquidityAllocBps; // of total tax → auto-liquidity bucket
        // platform gets remainder (≥ PLATFORM_MIN_BPS enforced at registration)
        bool    registered;
        address quoteToken;
        bool    tokenIsZero;
    }
    mapping(address token => TaxParams) public taxParams;

    mapping(address token => uint256) public snipeWindowEnd;
    mapping(address token => uint256) public fairLaunchEnd;

    // Pending buckets
    mapping(address token => mapping(address quote => uint256)) public pendingBurn;
    mapping(address token => mapping(address quote => uint256)) public pendingDiv;
    mapping(address token => mapping(address quote => uint256)) public pendingLiq;

    // Thresholds
    mapping(address token => uint256) public burnThreshold;
    mapping(address token => uint256) public dividendFlushThreshold;
    mapping(address token => uint256) public liquidityThreshold;

    // ── V4 permissions struct ─────────────────────────────────────────────────

    struct Permissions {
        bool beforeInitialize; bool afterInitialize;
        bool beforeAddLiquidity; bool afterAddLiquidity;
        bool beforeRemoveLiquidity; bool afterRemoveLiquidity;
        bool beforeSwap; bool afterSwap;
        bool beforeDonate; bool afterDonate;
        bool beforeSwapReturnDelta; bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta; bool afterRemoveLiquidityReturnDelta;
    }

    // ── Events ────────────────────────────────────────────────────────────────

    event TokenRegistered(address indexed token, uint256 buyTaxBps, uint256 sellTaxBps, uint256 snipeWindowEnd, uint256 burnAllocBps, uint256 dividendAllocBps, uint256 liquidityAllocBps, uint256 creatorAllocBps);
    event Swapped(address indexed token, bool isBuy, uint256 quoteAmount, uint256 totalFee);
    event BurnExecuted(address indexed token, address indexed quoteToken, uint256 quoteIn, uint256 tokensBurned);
    event DividendFlushed(address indexed token, address indexed quoteToken, uint256 amount);
    event LiquidityAdded(address indexed token, address indexed quoteToken, uint256 quoteUsed, uint256 liquidityAmount);
    event FairLaunchWindowUpdated(uint256 duration);
    event MaxBuyQuoteUpdated(uint256 amount);
    event TreasuryUpdated(address indexed treasury);
    event GraduationFeeDropped(address indexed token);
    event TokenTaxUpdated(address indexed token, uint16 buyBps, uint16 sellBps);
    event TokenAllocationsUpdated(address indexed token, uint16 burn, uint16 div, uint16 liq, uint16 creator);
    event DividendPoolUpdated(address indexed dp);
    event DividendFlushThresholdUpdated(address indexed token, uint256 threshold);
    event FactoryCallFailed(address indexed token, bytes4 selector);

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotPoolManager();
    error NotFactory();
    error ZeroAddress();
    error SnipeWindowActive();
    error MaxBuyExceeded();
    error FairLaunchWindowTooLong();
    error TaxTooHigh();
    error AllocationTooHigh();

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address poolManager_,
        address factory_,
        address treasury_,
        address tax_,
        address dividendPool_
    ) Ownable(treasury_) {
        if (poolManager_ == address(0) || factory_ == address(0) || treasury_ == address(0) || tax_ == address(0))
            revert ZeroAddress();
        poolManager  = poolManager_;
        factory      = IMemespadFactory(factory_);
        treasury     = treasury_;
        tax          = tax_;
        dividendPool = dividendPool_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert NotPoolManager();
        _;
    }

    function getHookPermissions() external pure returns (Permissions memory) {
        return Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeAddLiquidity: false, afterAddLiquidity: false,
            beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
            beforeSwap: true, afterSwap: true,
            beforeDonate: false, afterDonate: false,
            beforeSwapReturnDelta: true, afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false, afterRemoveLiquidityReturnDelta: false
        });
    }

    // ── beforeSwap ────────────────────────────────────────────────────────────

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (sender == address(this) || sender == address(factory))
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        (address tokenAddr, bool tokenIsZero_) = _identifyToken(key);
        if (tokenAddr == address(0)) return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        bool isBuy_ = tokenIsZero_ ? !params.zeroForOne : params.zeroForOne;

        if (isBuy_ && sender != address(factory) && block.timestamp < snipeWindowEnd[tokenAddr]) {
            revert SnipeWindowActive();
        }

        if (isBuy_ && params.amountSpecified < 0 && sender != address(factory)) {
            uint256 mbc = maxBuyQuote;
            if (mbc > 0 && block.timestamp < fairLaunchEnd[tokenAddr]) {
                if (SafeCast.toUint256(-params.amountSpecified) > mbc) revert MaxBuyExceeded();
            }
        }

        TaxParams storage p = taxParams[tokenAddr];
        uint256 totalTaxBps = isBuy_ ? uint256(p.buyTaxBps) : uint256(p.sellTaxBps);
        if (totalTaxBps == 0) return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        bool ethIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        bool feeIsSpecified = tokenIsZero_ ? !ethIsSpecified : ethIsSpecified;
        if (!feeIsSpecified) return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        uint256 quoteAmount = SafeCast.toUint256(-params.amountSpecified);
        uint256 totalFee    = (quoteAmount * totalTaxBps) / BPS_DENOM;
        if (totalFee == 0) return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        Currency feeCurrency = tokenIsZero_ ? key.currency1 : key.currency0;
        IPoolManagerTake(poolManager).take(feeCurrency, address(this), totalFee);

        _routeFee(tokenAddr, p.quoteToken, totalFee, p, isBuy_, quoteAmount);

        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(totalFee)), 0), 0);
    }

    // ── afterSwap ─────────────────────────────────────────────────────────────

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (sender == address(this) || sender == address(factory))
            return (this.afterSwap.selector, 0);

        (address tokenAddr, bool tokenIsZero_) = _identifyToken(key);
        if (tokenAddr == address(0)) return (this.afterSwap.selector, 0);

        bool isBuy = tokenIsZero_ ? !params.zeroForOne : params.zeroForOne;
        TaxParams storage p = taxParams[tokenAddr];
        uint256 totalTaxBps = isBuy ? uint256(p.buyTaxBps) : uint256(p.sellTaxBps);
        if (totalTaxBps == 0) return (this.afterSwap.selector, 0);

        bool ethIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        bool feeIsSpecified = tokenIsZero_ ? !ethIsSpecified : ethIsSpecified;

        // Always attempt bucket flushes regardless of which hook leg collected the fee.
        // feeIsSpecified=true means beforeSwap already took the fee — afterSwap must still
        // try to drain any pending burn/liq/dividend that crossed its threshold this swap.
        _tryExecuteBurn(key, tokenAddr, tokenIsZero_);
        _tryAddLiquidity(key, tokenAddr, tokenIsZero_);
        _tryFlushDividend(key, tokenAddr, tokenIsZero_);

        if (feeIsSpecified) return (this.afterSwap.selector, 0);

        int128 quoteDelta = tokenIsZero_ ? delta.amount1() : delta.amount0();
        if (quoteDelta == 0) return (this.afterSwap.selector, 0);
        uint256 quoteAmount = quoteDelta < 0
            ? SafeCast.toUint256(-int256(quoteDelta))
            : SafeCast.toUint256(int256(quoteDelta));

        uint256 totalFee = (quoteAmount * totalTaxBps) / BPS_DENOM;
        if (totalFee == 0) return (this.afterSwap.selector, 0);

        if (isBuy && params.amountSpecified > 0 && sender != address(factory)) {
            uint256 mbc = maxBuyQuote;
            if (mbc > 0 && block.timestamp < fairLaunchEnd[tokenAddr] && quoteAmount > mbc) {
                revert MaxBuyExceeded();
            }
        }

        Currency feeCurrency = tokenIsZero_ ? key.currency1 : key.currency0;
        IPoolManagerTake(poolManager).take(feeCurrency, address(this), totalFee);

        _routeFee(tokenAddr, p.quoteToken, totalFee, p, isBuy, quoteAmount);

        return (this.afterSwap.selector, int128(uint128(totalFee)));
    }

    // ── Token registration ────────────────────────────────────────────────────

    function registerToken(
        address token,
        uint256 snipeWindowEnd_,
        uint16  buyTaxBps_,
        uint16  sellTaxBps_,
        uint16  creatorAllocBps_,
        uint16  burnAllocBps_,
        uint16  dividendAllocBps_,
        uint16  liquidityAllocBps_,
        uint256 burnThreshold_,
        uint256 dividendThreshold_,
        uint256 liquidityThreshold_
    ) external {
        if (msg.sender != address(factory)) revert NotFactory();
        if (buyTaxBps_ > MAX_TAX_BPS || sellTaxBps_ > MAX_TAX_BPS) revert TaxTooHigh();

        uint256 allocTotal = uint256(creatorAllocBps_) + uint256(burnAllocBps_)
            + uint256(dividendAllocBps_) + uint256(liquidityAllocBps_);
        if (allocTotal > BPS_DENOM - PLATFORM_MIN_BPS) revert AllocationTooHigh();

        IMemespadFactory.LaunchedTokenInfo memory lt = factory.launchedTokens(token);
        taxParams[token] = TaxParams({
            buyTaxBps:        buyTaxBps_,
            sellTaxBps:       sellTaxBps_,
            creatorAllocBps:  creatorAllocBps_,
            burnAllocBps:     burnAllocBps_,
            dividendAllocBps: dividendAllocBps_,
            liquidityAllocBps:liquidityAllocBps_,
            registered:       true,
            quoteToken:       lt.quoteToken,
            tokenIsZero:      lt.tokenIsZero
        });

        snipeWindowEnd[token]        = snipeWindowEnd_;
        fairLaunchEnd[token]         = snipeWindowEnd_ + fairLaunchWindow;
        burnThreshold[token]         = burnThreshold_;
        dividendFlushThreshold[token]= dividendThreshold_;
        liquidityThreshold[token]    = liquidityThreshold_;

        emit TokenRegistered(token, buyTaxBps_, sellTaxBps_, snipeWindowEnd_, burnAllocBps_, dividendAllocBps_, liquidityAllocBps_, creatorAllocBps_);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setFairLaunchWindow(uint256 duration) external onlyOwner {
        if (duration > MAX_FAIR_LAUNCH_WINDOW) revert FairLaunchWindowTooLong();
        fairLaunchWindow = duration;
        emit FairLaunchWindowUpdated(duration);
    }

    function setMaxBuyQuote(uint256 amount) external onlyOwner {
        maxBuyQuote = amount;
        emit MaxBuyQuoteUpdated(amount);
    }

    function setTokenTax(address token, uint16 buyBps, uint16 sellBps) external onlyOwner {
        if (buyBps > MAX_TAX_BPS || sellBps > MAX_TAX_BPS) revert TaxTooHigh();
        if (!taxParams[token].registered) return;
        taxParams[token].buyTaxBps  = buyBps;
        taxParams[token].sellTaxBps = sellBps;
        emit TokenTaxUpdated(token, buyBps, sellBps);
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IMemespadFactory(factory_);
    }

    function setDividendPool(address dp_) external onlyOwner {
        dividendPool = dp_;
        emit DividendPoolUpdated(dp_);
    }

    function setDividendFlushThreshold(address token, uint256 threshold) external onlyOwner {
        dividendFlushThreshold[token] = threshold;
        emit DividendFlushThresholdUpdated(token, threshold);
    }

    function setTokenAllocations(
        address token,
        uint16  burn,
        uint16  div,
        uint16  liq,
        uint16  creator
    ) external onlyOwner {
        if (!taxParams[token].registered) return;
        if (uint256(burn) + div + liq + creator > BPS_DENOM - PLATFORM_MIN_BPS) revert AllocationTooHigh();
        TaxParams storage p = taxParams[token];
        p.burnAllocBps      = burn;
        p.dividendAllocBps  = div;
        p.liquidityAllocBps = liq;
        p.creatorAllocBps   = creator;
        emit TokenAllocationsUpdated(token, burn, div, liq, creator);
    }

    function setBurnDustThreshold(uint256 amount) external onlyOwner {
        burnDustThreshold = amount;
    }

    function quoteTokenOf(address token) external view returns (address) {
        return taxParams[token].quoteToken;
    }

    // ── Internal — fee routing ────────────────────────────────────────────────

    function _identifyToken(PoolKey calldata key)
        internal view returns (address tokenAddr, bool tokenIsZero_)
    {
        address c1 = Currency.unwrap(key.currency1);
        if (taxParams[c1].registered) return (c1, false);
        address c0 = Currency.unwrap(key.currency0);
        if (taxParams[c0].registered) return (c0, true);
        return (address(0), false);
    }

    function _routeFee(
        address tokenAddr,
        address quoteToken,
        uint256 totalFee,
        TaxParams storage p,
        bool isBuy,
        uint256 grossQuote
    ) internal {
        uint256 allocTotal = uint256(p.creatorAllocBps) + uint256(p.burnAllocBps)
            + uint256(p.dividendAllocBps) + uint256(p.liquidityAllocBps);

        uint256 creatorFee   = (totalFee * uint256(p.creatorAllocBps))   / BPS_DENOM;
        uint256 burnAmt      = (totalFee * uint256(p.burnAllocBps))       / BPS_DENOM;
        uint256 dividendAmt  = (totalFee * uint256(p.dividendAllocBps))   / BPS_DENOM;
        uint256 liquidityAmt = (totalFee * uint256(p.liquidityAllocBps))  / BPS_DENOM;
        uint256 platformFee  = totalFee - creatorFee - burnAmt - dividendAmt - liquidityAmt;

        // Send creator + platform to MemespadTax (try/catch: swap must never revert due to fee accounting)
        if (creatorFee + platformFee > 0) {
            address creator;
            try factory.tokenCreator(tokenAddr) returns (address c) { creator = c; } catch {
                emit FactoryCallFailed(tokenAddr, IMemespadFactory.tokenCreator.selector);
            }
            address taxAddr = tax;
            if (quoteToken == address(0)) {
                try IMemespadTax(taxAddr).distribute{value: creatorFee + platformFee}(
                    tokenAddr, creator, quoteToken, creatorFee, platformFee
                ) {} catch {
                    // Fallback: keep ETH in hook — treasury can recover via emergencyWithdraw
                }
            } else {
                try IERC20(quoteToken).transfer(taxAddr, creatorFee + platformFee) returns (bool ok) {
                    if (ok) {
                        try IMemespadTax(taxAddr).distribute(
                            tokenAddr, creator, quoteToken, creatorFee, platformFee
                        ) {} catch {}
                    }
                } catch {}
            }
        }

        // Accumulate burn/dividend/liquidity buckets
        if (burnAmt > 0)      pendingBurn[tokenAddr][quoteToken] += burnAmt;
        if (dividendAmt > 0)  pendingDiv[tokenAddr][quoteToken]  += dividendAmt;
        if (liquidityAmt > 0) pendingLiq[tokenAddr][quoteToken]  += liquidityAmt;

        // Record swap volume (net of fee)
        uint256 poolQuote = grossQuote > totalFee ? grossQuote - totalFee : 0;
        if (poolQuote > 0) {
            try factory.recordSwap(tokenAddr, isBuy, poolQuote) {} catch {
                emit FactoryCallFailed(tokenAddr, IMemespadFactory.recordSwap.selector);
            }
        }

        emit Swapped(tokenAddr, isBuy, grossQuote, totalFee);
        allocTotal; // suppress unused warning
    }

    // ── Internal — burn ───────────────────────────────────────────────────────

    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    function _tryExecuteBurn(
        PoolKey calldata key,
        address tokenAddr,
        bool tokenIsZero_
    ) internal {
        address quoteToken_ = taxParams[tokenAddr].quoteToken;
        uint256 pending     = pendingBurn[tokenAddr][quoteToken_];
        uint256 threshold   = burnThreshold[tokenAddr];
        if (threshold == 0) threshold = burnDustThreshold;
        if (pending < threshold) return;

        pendingBurn[tokenAddr][quoteToken_] = 0;

        bool zeroForOne = !tokenIsZero_;

        BalanceDelta delta = IPoolManager(poolManager).swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(pending),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );

        if (quoteToken_ == address(0)) {
            uint256 ethOwed = tokenIsZero_
                ? SafeCast.toUint256(-int256(delta.amount1()))
                : SafeCast.toUint256(-int256(delta.amount0()));
            IPoolManagerTake(poolManager).settle{value: ethOwed}();
        } else {
            Currency quoteCurrency = tokenIsZero_ ? key.currency1 : key.currency0;
            IPoolManagerTake(poolManager).sync(quoteCurrency);
            IERC20(quoteToken_).safeTransfer(poolManager, pending);
            IPoolManagerTake(poolManager).settle();
        }

        uint256 tokensBought;
        if (tokenIsZero_) {
            tokensBought = SafeCast.toUint256(int256(delta.amount0()));
            if (tokensBought > 0)
                IPoolManagerTake(poolManager).take(key.currency0, address(this), tokensBought);
        } else {
            tokensBought = SafeCast.toUint256(int256(delta.amount1()));
            if (tokensBought > 0)
                IPoolManagerTake(poolManager).take(key.currency1, address(this), tokensBought);
        }

        if (tokensBought > 0) {
            IERC20(tokenAddr).safeTransfer(BURN_ADDRESS, tokensBought);
            emit BurnExecuted(tokenAddr, quoteToken_, pending, tokensBought);
        }
    }

    // ── Internal — auto-liquidity ─────────────────────────────────────────────

    function _tryAddLiquidity(
        PoolKey calldata key,
        address tokenAddr,
        bool tokenIsZero_
    ) internal {
        address quoteToken_ = taxParams[tokenAddr].quoteToken;
        uint256 pending     = pendingLiq[tokenAddr][quoteToken_];
        uint256 threshold   = liquidityThreshold[tokenAddr];
        if (threshold == 0 || pending < threshold) return;

        pendingLiq[tokenAddr][quoteToken_] = 0;

        // Step 1: swap ~45% of accumulated quote for tokens (slightly under half to
        // avoid ratio mismatch when providing two-sided liquidity)
        uint256 swapAmt = (pending * 45) / 100;
        uint256 keepAmt = pending - swapAmt;
        bool zeroForOne = !tokenIsZero_;  // sell quote to buy tokens

        BalanceDelta swapDelta = IPoolManager(poolManager).swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(swapAmt),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );

        // Settle the quote we sold
        if (quoteToken_ == address(0)) {
            uint256 ethOwed = tokenIsZero_
                ? SafeCast.toUint256(-int256(swapDelta.amount1()))
                : SafeCast.toUint256(-int256(swapDelta.amount0()));
            IPoolManagerTake(poolManager).settle{value: ethOwed}();
        } else {
            Currency quoteCurrency = tokenIsZero_ ? key.currency1 : key.currency0;
            IPoolManagerTake(poolManager).sync(quoteCurrency);
            IERC20(quoteToken_).safeTransfer(poolManager, swapAmt);
            IPoolManagerTake(poolManager).settle();
        }

        // Take the tokens we received from the swap
        uint256 tokensBought;
        if (tokenIsZero_) {
            tokensBought = SafeCast.toUint256(int256(swapDelta.amount0()));
            if (tokensBought > 0)
                IPoolManagerTake(poolManager).take(key.currency0, address(this), tokensBought);
        } else {
            tokensBought = SafeCast.toUint256(int256(swapDelta.amount1()));
            if (tokensBought > 0)
                IPoolManagerTake(poolManager).take(key.currency1, address(this), tokensBought);
        }

        if (tokensBought == 0) {
            pendingLiq[tokenAddr][quoteToken_] += pending;
            return;
        }

        // Step 2: calculate liquidity using the token side (conservative — leftover quote returned)
        IMemespadFactory.LaunchedTokenInfo memory lt = factory.launchedTokens(tokenAddr);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lt.tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(lt.tickUpper);
        uint128 liq = tokenIsZero_
            ? LiquidityMath.getLiquidityForAmount0(sqrtA, sqrtB, tokensBought)
            : LiquidityMath.getLiquidityForAmount1(sqrtA, sqrtB, tokensBought);

        if (liq == 0) {
            // Dust — burn tokens, return quote to pending
            IERC20(tokenAddr).safeTransfer(BURN_ADDRESS, tokensBought);
            pendingLiq[tokenAddr][quoteToken_] += keepAmt;
            return;
        }

        // Step 3: add liquidity directly to PoolManager — valid inside existing unlock context;
        // calling PositionManager.modifyLiquidities here would trigger a nested unlock() which
        // V4 rejects with AlreadyUnlocked. Position is owned by this hook → effectively permanent.
        try IPoolManager(poolManager).modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      lt.tickLower,
                tickUpper:      lt.tickUpper,
                liquidityDelta: int256(uint256(liq)),
                salt:           bytes32(0)
            }),
            ""
        ) returns (BalanceDelta callerDelta, BalanceDelta) {
            int128 d0 = BalanceDeltaLib.amount0(callerDelta);
            int128 d1 = BalanceDeltaLib.amount1(callerDelta);
            // Negative delta = we owe to pool; settle each currency owed
            uint256 used0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
            uint256 used1 = d1 < 0 ? uint256(uint128(-d1)) : 0;

            // Settle token side
            if (tokenIsZero_ && used0 > 0) {
                IPoolManagerTake(poolManager).sync(key.currency0);
                IERC20(tokenAddr).safeTransfer(poolManager, used0);
                IPoolManagerTake(poolManager).settle();
            } else if (!tokenIsZero_ && used1 > 0) {
                IPoolManagerTake(poolManager).sync(key.currency1);
                IERC20(tokenAddr).safeTransfer(poolManager, used1);
                IPoolManagerTake(poolManager).settle();
            }

            // Settle quote side
            uint256 quoteUsed = tokenIsZero_ ? used1 : used0;
            if (quoteUsed > 0) {
                if (quoteToken_ == address(0)) {
                    IPoolManagerTake(poolManager).settle{value: quoteUsed}();
                } else {
                    Currency quoteCurrency = tokenIsZero_ ? key.currency1 : key.currency0;
                    IPoolManagerTake(poolManager).sync(quoteCurrency);
                    IERC20(quoteToken_).safeTransfer(poolManager, quoteUsed);
                    IPoolManagerTake(poolManager).settle();
                }
            }

            // Positive delta = pool accrued fees to our position; take them back
            if (d0 > 0) IPoolManagerTake(poolManager).take(key.currency0, address(this), uint256(uint128(d0)));
            if (d1 > 0) IPoolManagerTake(poolManager).take(key.currency1, address(this), uint256(uint128(d1)));

            // Return unused token dust to burn and unused quote dust to pending
            uint256 tokenUsed = tokenIsZero_ ? used0 : used1;
            if (tokensBought > tokenUsed)
                IERC20(tokenAddr).safeTransfer(BURN_ADDRESS, tokensBought - tokenUsed);
            uint256 quoteDust = keepAmt > quoteUsed ? keepAmt - quoteUsed : 0;
            if (quoteDust > 0) pendingLiq[tokenAddr][quoteToken_] += quoteDust;

            // If we received fee tokens from d0/d1 positive, return quote to pending, burn token
            if (d0 > 0 && !tokenIsZero_) pendingLiq[tokenAddr][quoteToken_] += uint256(uint128(d0));
            if (d0 > 0 && tokenIsZero_)  IERC20(tokenAddr).safeTransfer(BURN_ADDRESS, uint256(uint128(d0)));
            if (d1 > 0 && tokenIsZero_)  pendingLiq[tokenAddr][quoteToken_] += uint256(uint128(d1));
            if (d1 > 0 && !tokenIsZero_) IERC20(tokenAddr).safeTransfer(BURN_ADDRESS, uint256(uint128(d1)));

            emit LiquidityAdded(tokenAddr, quoteToken_, pending, uint256(liq));
        } catch {
            // LP add failed — burn bought tokens, return keepAmt quote to pending
            IERC20(tokenAddr).safeTransfer(BURN_ADDRESS, tokensBought);
            pendingLiq[tokenAddr][quoteToken_] += keepAmt;
        }
    }

    // ── Internal — dividend flush ─────────────────────────────────────────────

    function _tryFlushDividend(
        PoolKey calldata key,
        address tokenAddr,
        bool tokenIsZero_
    ) internal {
        address dp = dividendPool;
        if (dp == address(0)) return;

        address quoteToken_ = taxParams[tokenAddr].quoteToken;
        uint256 pending     = pendingDiv[tokenAddr][quoteToken_];
        uint256 threshold   = dividendFlushThreshold[tokenAddr];
        if (threshold == 0 || pending < threshold) return;

        pendingDiv[tokenAddr][quoteToken_] = 0;

        if (quoteToken_ == address(0)) {
            try IDividendPool(dp).creditDividend{value: pending}(tokenAddr, pending) {
                emit DividendFlushed(tokenAddr, address(0), pending);
            } catch {
                pendingDiv[tokenAddr][quoteToken_] += pending;
            }
        } else {
            try IERC20(quoteToken_).transfer(dp, pending) returns (bool ok) {
                if (ok) {
                    try IDividendPool(dp).creditDividendERC20(tokenAddr, quoteToken_, pending) {
                        emit DividendFlushed(tokenAddr, quoteToken_, pending);
                    } catch {
                        pendingDiv[tokenAddr][quoteToken_] += pending;
                    }
                } else {
                    pendingDiv[tokenAddr][quoteToken_] += pending;
                }
            } catch {
                pendingDiv[tokenAddr][quoteToken_] += pending;
            }
        }

        key; tokenIsZero_;
    }

    receive() external payable {}
}
