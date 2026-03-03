// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GTradeAdapterMock
 * @notice Mock gTrade adapter for testing vault integration without real gTrade dependency
 * @dev Implements IAdapter interface to match real GTradeAdapter behavior
 *
 * Key Behaviors Simulated:
 * - Receives collateral tokens before openMarketLong (matches vault flow)
 * - Positions tracked by pairIndex (matches gTrade's per-user trade index model)
 * - closeMarketLong iterates mock trades by pairIndex (matches real on-chain getTrades() pattern)
 * - Returns collateral on close (simulates gTrade returning tokens after oracle execution)
 *
 * What this mock does NOT simulate:
 * - Async oracle execution (Chainlink DON) — mock executes instantly
 * - Real approve+transferFrom pattern — mock just holds tokens sent by vault
 * - Trade index assignment by Diamond — mock uses simple counter
 * - MarketExecuted event — mock emits simplified events
 */
contract GTradeAdapterMock is IAdapter {
    // ============================================
    // State
    // ============================================
    uint32 private tradeCounter;

    // Mock trade storage: mirrors gTrade's mapping(address => mapping(uint32 => Trade))
    struct MockTrade {
        address user;
        uint32 index;
        uint16 pairIndex;
        uint24 leverage;
        bool long;
        bool isOpen;
        uint8 collateralIndex;
        address collateralToken;
        uint256 collateralAmount;
        uint256 sizeDeltaUsd;
        uint256 timestamp;
    }

    // Trades by user => index
    mapping(address => mapping(uint32 => MockTrade)) public trades;
    mapping(address => uint32) public tradeCount; // currentIndex per user

    // Market configuration (mirrors real adapter)
    mapping(address => uint16) public marketToPairIndex;
    mapping(address => uint8) public tokenToCollateralIndex;
    mapping(address => bool) public marketConfigured;

    // ============================================
    // Events (simplified versions of real gTrade events)
    // ============================================
    event OrderCreated(address indexed user, uint16 pairIndex, uint256 collateralAmount, bool isOpen);
    event MarketConfigured(address indexed market, uint16 pairIndex);

    // ============================================
    // Admin
    // ============================================

    function setMarket(address market, uint16 pairIndex) external {
        marketToPairIndex[market] = pairIndex;
        marketConfigured[market] = true;
        emit MarketConfigured(market, pairIndex);
    }

    function setCollateral(address token, uint8 collateralIndex) external {
        tokenToCollateralIndex[token] = collateralIndex;
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
        uint16 pairIndex = marketToPairIndex[market];

        // Derive leverage (same formula as real adapter)
        uint24 leverage = uint24((sizeDeltaUsd * 1000) / (uint256(collateralAmount) * 1e24));

        // Assign trade index (simulates gTrade's per-user counter)
        uint32 index = tradeCount[msg.sender];
        tradeCount[msg.sender]++;

        // Store mock trade
        trades[msg.sender][index] = MockTrade({
            user: msg.sender,
            index: index,
            pairIndex: pairIndex,
            leverage: leverage,
            long: true,
            isOpen: true,
            collateralIndex: tokenToCollateralIndex[collateralToken],
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            sizeDeltaUsd: sizeDeltaUsd,
            timestamp: block.timestamp
        });

        emit OrderCreated(msg.sender, pairIndex, collateralAmount, true);

        // Return pairIndex as orderKey (matches real adapter)
        return bytes32(uint256(pairIndex));
    }

    function closeMarketLong(
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        uint16 targetPairIndex = marketToPairIndex[market];

        // Iterate trades to find matching open trade by pairIndex (mirrors real getTrades() pattern)
        uint32 count = tradeCount[msg.sender];
        for (uint32 i = 0; i < count; i++) {
            MockTrade storage trade = trades[msg.sender][i];
            if (trade.isOpen && trade.pairIndex == targetPairIndex && trade.long) {
                // Mark closed
                trade.isOpen = false;

                // Return collateral to caller (simulates gTrade returning tokens after oracle execution)
                if (trade.collateralAmount > 0) {
                    IERC20(trade.collateralToken).transfer(msg.sender, trade.collateralAmount);
                }

                emit OrderCreated(msg.sender, targetPairIndex, 0, false);
                return bytes32(uint256(trade.index));
            }
        }

        revert("No active trade for market");
    }

    // ============================================
    // View Functions (mirror real gTrade Diamond interface)
    // ============================================

    /**
     * @notice Get all open trades for a user (mirrors IGNSDiamond.getTrades)
     */
    function getTrades(address trader) external view returns (MockTrade[] memory) {
        uint32 count = tradeCount[trader];
        uint32 openCount = 0;

        // Count open trades
        for (uint32 i = 0; i < count; i++) {
            if (trades[trader][i].isOpen) openCount++;
        }

        // Build array
        MockTrade[] memory result = new MockTrade[](openCount);
        uint32 idx = 0;
        for (uint32 i = 0; i < count; i++) {
            if (trades[trader][i].isOpen) {
                result[idx] = trades[trader][i];
                idx++;
            }
        }
        return result;
    }

    /**
     * @notice Get a specific trade by index
     */
    function getTrade(address trader, uint32 index) external view returns (MockTrade memory) {
        return trades[trader][index];
    }

    /**
     * @notice Get trade counter for a user
     */
    function getTradeCount(address trader) external view returns (uint32) {
        return tradeCount[trader];
    }

    /**
     * @notice Check if a trade is open by user + pairIndex
     */
    function hasOpenTrade(address trader, uint16 pairIndex) external view returns (bool) {
        uint32 count = tradeCount[trader];
        for (uint32 i = 0; i < count; i++) {
            if (trades[trader][i].isOpen && trades[trader][i].pairIndex == pairIndex) {
                return true;
            }
        }
        return false;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
