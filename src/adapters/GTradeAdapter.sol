// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GTradeAdapter
 * @notice gTrade v10 adapter for Arbitrum Mainnet
 * @dev Implements IAdapter interface for UMIP vault integration
 *
 * Execution Pattern:
 *   1. Approve Diamond to pull collateral via transferFrom
 *   2. Call openTrade() with v10 Trade struct
 *   No multicall, no OrderVault, no ETH execution fee.
 *
 * Trade Index Resolution:
 *   gTrade assigns trade indices asynchronously (at oracle fulfillment, not at openTrade time).
 *   To close, we query getTrades(address(this)) on-chain and find the trade by pairIndex.
 *   No off-chain relay needed.
 *
 * Selector Verification (Feb 2026):
 *   openTrade:       0x5bfcc4f8 (confirmed on Arb Sepolia)
 *   closeTradeMarket: 0x36ce736b (confirmed on Arb Sepolia)
 *   getTrades:        0x4bfad7c0 (confirmed on Arb Sepolia)
 *
 * v10 Trade Struct Corrections (from selector decode):
 *   positionSizeToken is uint160 (not uint120)
 *   __placeholder is uint24 (not uint48)
 */
contract GTradeAdapter is IAdapter {
    // ============================================
    // gTrade Contract Addresses (Arbitrum Mainnet)
    // ============================================
    address public constant DIAMOND = 0xFF162c694eAA571f685030649814282eA457f169;

    // ============================================
    // Configuration
    // ============================================

    // Map IAdapter "market address" to gTrade pairIndex
    mapping(address => uint16) public marketToPairIndex;

    // Map collateral token to gTrade collateralIndex
    mapping(address => uint8) public tokenToCollateralIndex;

    // Track which markets have been configured
    mapping(address => bool) public marketConfigured;

    // ============================================
    // Errors
    // ============================================
    error MarketNotConfigured(address market);
    error CollateralNotConfigured(address token);
    error NoActiveTradeForMarket(address market);

    // ============================================
    // Events
    // ============================================
    event OrderCreated(address indexed user, uint16 pairIndex, uint256 collateralAmount, bool isOpen);
    event MarketConfigured(address indexed market, uint16 pairIndex);
    event CollateralConfigured(address indexed token, uint8 collateralIndex);

    // ============================================
    // Admin (no access control for now — matches GMX adapter pattern)
    // ============================================

    function setMarket(address market, uint16 pairIndex) external {
        marketToPairIndex[market] = pairIndex;
        marketConfigured[market] = true;
        emit MarketConfigured(market, pairIndex);
    }

    function setCollateral(address token, uint8 collateralIndex) external {
        tokenToCollateralIndex[token] = collateralIndex;
        emit CollateralConfigured(token, collateralIndex);
    }

    // ============================================
    // IAdapter Implementation
    // ============================================

    function openMarketLong(
        address market,
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        if (!marketConfigured[market]) revert MarketNotConfigured(market);

        // Step 1: Approve Diamond to pull collateral
        IERC20(collateralToken).approve(DIAMOND, collateralAmount);

        // Step 2: Derive leverage from sizeDeltaUsd / collateralUsd
        // sizeDeltaUsd is 30 decimals, USDC collateral is 6 decimals
        // leverage (3 decimals): sizeDeltaUsd * 1000 / (collateralAmount * 1e24)
        uint24 leverage = uint24((sizeDeltaUsd * 1000) / (uint256(collateralAmount) * 1e24));

        // Step 3: Build v10 Trade struct
        IGNSDiamond.Trade memory trade = IGNSDiamond.Trade({
            user: address(this),
            index: 0,                                         // auto-assigned at execution
            pairIndex: marketToPairIndex[market],
            leverage: leverage,
            long: true,
            isOpen: true,                                     // must be true for new trades
            collateralIndex: tokenToCollateralIndex[collateralToken],
            tradeType: 0,                                     // MARKET
            collateralAmount: uint120(collateralAmount),
            openPrice: 0,                                     // ignored for market orders
            tp: 0,
            sl: 0,
            isCounterTrade: false,
            positionSizeToken: 0,                             // uint160, set to 0 for new trades
            __placeholder: 0                                  // uint24
        });

        // Step 4: Call openTrade (no msg.value needed — gTrade has no ETH execution fee)
        IGNSDiamond(DIAMOND).openTrade(trade, 1000, address(0)); // 10% max slippage, no referrer

        emit OrderCreated(address(this), marketToPairIndex[market], collateralAmount, true);

        // Return pairIndex as orderKey placeholder (real index assigned async)
        return bytes32(uint256(marketToPairIndex[market]));
    }

    function closeMarketLong(
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        if (!marketConfigured[market]) revert MarketNotConfigured(market);

        uint16 targetPairIndex = marketToPairIndex[market];

        // Convert 30-decimal acceptable price to 10-decimal expected price
        // If acceptablePrice is 0, use 0 (accept any price)
        uint64 expectedPrice = acceptablePrice > 0 ? uint64(acceptablePrice / 1e20) : 0;

        // On-chain trade index resolution via getTrades()
        IGNSDiamond.Trade[] memory trades = IGNSDiamond(DIAMOND).getTrades(address(this));
        for (uint256 i = 0; i < trades.length; i++) {
            if (trades[i].pairIndex == targetPairIndex && trades[i].long) {
                uint32 tradeIndex = trades[i].index;
                IGNSDiamond(DIAMOND).closeTradeMarket(tradeIndex, expectedPrice);
                emit OrderCreated(address(this), targetPairIndex, 0, false);
                return bytes32(uint256(tradeIndex));
            }
        }

        revert NoActiveTradeForMarket(market);
    }

    // Allow contract to receive ETH (not needed for gTrade, but matches IAdapter pattern)
    receive() external payable {}
}

// ============================================
// gTrade v10 Diamond Interface
// Validated against Arbitrum Sepolia (Feb 2026)
// openTrade selector:       0x5bfcc4f8
// closeTradeMarket selector: 0x36ce736b
// getTrades selector:        0x4bfad7c0
// ============================================

interface IGNSDiamond {
    // v10 Trade struct — field types confirmed from selector decode
    struct Trade {
        address user;              // address(this) for contract integration
        uint32 index;              // 0 for new trades (auto-assigned at execution)
        uint16 pairIndex;          // 0=BTC/USD, 1=ETH/USD, 2=LINK/USD...
        uint24 leverage;           // 3 decimals: 10000=10x, 50000=50x
        bool long;
        bool isOpen;               // true for new trades
        uint8 collateralIndex;     // 1=gDAI, 2=gETH, 3=USDC
        uint8 tradeType;           // 0=MARKET, 1=LIMIT, 2=STOP
        uint120 collateralAmount;  // Native decimals (6 for USDC)
        uint64 openPrice;          // 10 decimals (0 for market orders)
        uint64 tp;                 // Take profit (10 decimals, 0=none)
        uint64 sl;                 // Stop loss (10 decimals, 0=none)
        bool isCounterTrade;       // false for normal trades
        uint160 positionSizeToken; // 0 for new trades (CORRECTED: uint160 not uint120)
        uint24 __placeholder;      // Must be 0 (CORRECTED: uint24 not uint48)
    }

    struct Counter {
        uint32 currentIndex;
        uint32 openCount;
        uint192 __placeholder;
    }

    enum CounterType { TRADE, PENDING_ORDER }

    function openTrade(Trade memory _trade, uint16 _maxSlippageP, address _referrer) external;
    function closeTradeMarket(uint32 _index, uint64 _expectedPrice) external;
    function getTrades(address _trader) external view returns (Trade[] memory);
    function getTrade(address _trader, uint32 _index) external view returns (Trade memory);
    function getCounters(address _trader, CounterType _type) external view returns (Counter memory);
}
