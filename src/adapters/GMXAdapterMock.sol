// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GMXAdapterMock
 * @notice Mock GMX adapter for testing vault integration without real GMX dependency
 * @dev Implements IAdapter interface to match real GMXAdapterSimple behavior
 *
 * Key Behaviors Simulated:
 * - Receives collateral tokens before openMarketLong (matches real flow)
 * - Positions tracked by account+market+collateral+isLong (matches GMX V2)
 * - closeMarketLong doesn't take positionKey (matches real adapter)
 * - Returns collateral on close (simulates GMX keeper returning tokens)
 *
 * What this mock does NOT simulate (handled by real adapter):
 * - multicall(sendWnt + createOrder) pattern — mock skips this since no real ExchangeRouter
 * - V2.2+ struct fields (autoCancel, dataList) — not relevant for mock behavior
 * - Async keeper execution — mock executes instantly
 * - Execution fee wrapping via sendWnt — mock just accepts msg.value
 */
contract GMXAdapterMock is IAdapter {
    // ============================================
    // State
    // ============================================
    uint256 private orderCounter;

    // Position tracking by computed key (account+market+collateral+isLong)
    mapping(bytes32 => MockPosition) public positions;

    // Order to position mapping (for vault tracking)
    mapping(bytes32 => bytes32) public orderToPosition;

    struct MockPosition {
        address user;
        address market;
        address collateralToken;
        uint256 collateralAmount;
        uint256 sizeDeltaUsd;
        uint256 timestamp;
        bool isOpen;
    }

    // ============================================
    // Events (match real GMXAdapterSimple signature)
    // ============================================
    event OrderCreated(bytes32 indexed orderKey, address indexed user, uint256 sizeDeltaUsd, bool isIncrease);
    event PositionOpened(bytes32 indexed positionKey, address indexed user, uint256 size, uint256 collateral);
    event PositionClosed(bytes32 indexed positionKey, address indexed user);

    // ============================================
    // IAdapter Implementation
    // ============================================

    /**
     * @notice Mock opening a market long position
     * @dev Same interface as real GMXAdapterSimple
     * @dev In real adapter, tokens are transferred to OrderVault here
     */
    function openMarketLong(
        address market,
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        // Generate mock order key (simulates GMX's createOrder return value)
        orderKey = keccak256(abi.encode(
            msg.sender,
            market,
            collateralAmount,
            sizeDeltaUsd,
            block.timestamp,
            orderCounter++
        ));

        // Compute position key (matches GMX V2: account+market+collateral+isLong)
        bytes32 positionKey = _computePositionKey(msg.sender, market, collateralToken, true);

        // Record position
        positions[positionKey] = MockPosition({
            user: msg.sender,
            market: market,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            sizeDeltaUsd: sizeDeltaUsd,
            timestamp: block.timestamp,
            isOpen: true
        });

        // Track order to position mapping
        orderToPosition[orderKey] = positionKey;

        // Emit events (simulating GMX keeper execution - instant in mock)
        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd, true);
        emit PositionOpened(positionKey, msg.sender, sizeDeltaUsd, collateralAmount);

        return orderKey;
    }

    /**
     * @notice Mock closing a market long position
     * @dev No positionKey parameter - matches real GMXAdapterSimple interface
     * @dev Position identified by msg.sender + market + collateralToken + isLong
     * @dev Returns collateral to caller (simulates GMX keeper returning tokens)
     */
    function closeMarketLong(
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        // Compute position key (matches GMX V2)
        bytes32 positionKey = _computePositionKey(msg.sender, market, collateralToken, true);

        // Get position details for token return
        MockPosition storage position = positions[positionKey];
        uint256 collateralToReturn = position.collateralAmount;

        // Generate mock order key
        orderKey = keccak256(abi.encode(
            msg.sender,
            positionKey,
            block.timestamp,
            orderCounter++
        ));

        // Mark position as closed
        if (position.isOpen) {
            position.isOpen = false;
        }

        // Return collateral tokens to caller (simulates GMX returning tokens)
        // In real GMX, keeper sends tokens to receiver address
        if (collateralToReturn > 0) {
            IERC20(collateralToken).transfer(msg.sender, collateralToReturn);
        }

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd, false);
        emit PositionClosed(positionKey, msg.sender);

        return orderKey;
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get position by computed key
     */
    function getPosition(bytes32 positionKey) external view returns (MockPosition memory) {
        return positions[positionKey];
    }

    /**
     * @notice Get position by user, market, collateral, direction
     */
    function getPositionByParams(
        address user,
        address market,
        address collateralToken,
        bool isLong
    ) external view returns (MockPosition memory) {
        bytes32 positionKey = _computePositionKey(user, market, collateralToken, isLong);
        return positions[positionKey];
    }

    /**
     * @notice Check if position is open
     */
    function isPositionOpen(bytes32 positionKey) external view returns (bool) {
        return positions[positionKey].isOpen;
    }

    /**
     * @notice Compute position key (matches GMX V2 pattern)
     */
    function computePositionKey(
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) external pure returns (bytes32) {
        return _computePositionKey(account, market, collateralToken, isLong);
    }

    // ============================================
    // Internal Functions
    // ============================================

    function _computePositionKey(
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, market, collateralToken, isLong));
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
