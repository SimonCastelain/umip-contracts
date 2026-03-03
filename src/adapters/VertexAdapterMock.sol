// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VertexAdapterMock
 * @notice Mock Vertex adapter for testing vault integration without real Vertex dependency
 * @dev Implements IAdapter interface to match GMXAdapterMock behavior
 *
 * Purpose:
 * - Test UMIP vault collateral accounting alongside GMX
 * - Validate unified adapter interface design
 * - Enable vault development without Vertex SDK dependency
 *
 * Architecture Note:
 * Real Vertex Protocol uses a hybrid off-chain/on-chain model:
 * - Primary path: Off-chain sequencer (5-15ms, requires SDK)
 * - Fallback path: On-chain slow mode (expensive, limited)
 *
 * This mock simulates the on-chain interface for testing purposes.
 * Production integration would require a hybrid approach with backend.
 *
 * Vertex-specific concepts modeled:
 * - productId: uint32 (e.g., 4=ETH-PERP, 2=BTC-PERP, 6=ARB-PERP)
 * - subaccount: bytes32 identifier for cross-margin accounts
 * - USDC as primary collateral (6 decimals)
 *
 * Week 4 Updates:
 * - Implements IAdapter interface for vault compatibility
 * - closeMarketLong uses market+collateral pattern (no positionKey)
 * - Positions tracked by account+productId+collateral+isLong
 */
contract VertexAdapterMock is IAdapter {
    // ============================================
    // State
    // ============================================
    uint256 private orderCounter;

    // Position tracking by computed key (account+productId+collateral+isLong)
    mapping(bytes32 => MockPosition) public positions;
    mapping(address => bytes32) public subaccounts;

    struct MockPosition {
        address user;
        uint32 productId;
        bytes32 subaccount;
        address collateralToken;
        uint256 collateralAmount;  // USDC, 6 decimals
        int256 sizeDelta;          // Positive = long, negative = short
        uint256 timestamp;
        bool isOpen;
    }

    // Common Vertex product IDs (for reference)
    uint32 public constant PRODUCT_ETH_PERP = 4;   // ETH-PERP on mainnet
    uint32 public constant PRODUCT_BTC_PERP = 2;   // BTC-PERP on mainnet
    uint32 public constant PRODUCT_ARB_PERP = 6;   // ARB-PERP on mainnet

    // ============================================
    // Events (consistent with GMXAdapterMock)
    // ============================================
    event OrderCreated(bytes32 indexed orderKey, address indexed user, uint256 sizeDeltaUsd);
    event PositionOpened(bytes32 indexed positionKey, address indexed user, uint256 size, uint256 collateral);
    event PositionClosed(bytes32 indexed positionKey, address indexed user);

    // Vertex-specific events
    event SubaccountCreated(address indexed user, bytes32 indexed subaccount);

    // ============================================
    // Subaccount Management
    // ============================================

    /**
     * @notice Get or create a subaccount for the user
     * @dev In real Vertex, subaccounts enable cross-margin across products
     */
    function getOrCreateSubaccount(address user) public returns (bytes32) {
        if (subaccounts[user] == bytes32(0)) {
            bytes32 subaccount = keccak256(abi.encode("vertex", user, block.timestamp));
            subaccounts[user] = subaccount;
            emit SubaccountCreated(user, subaccount);
        }
        return subaccounts[user];
    }

    // ============================================
    // IAdapter Implementation
    // ============================================

    /**
     * @notice Mock opening a market long position on Vertex
     * @dev Implements IAdapter interface. market parameter treated as productId
     */
    function openMarketLong(
        address market,           // Cast to productId for Vertex
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        bytes32 subaccount = getOrCreateSubaccount(msg.sender);
        uint32 productId = uint32(uint160(market));

        // Generate mock order key
        orderKey = keccak256(abi.encode(
            msg.sender,
            productId,
            collateralAmount,
            sizeDeltaUsd,
            block.timestamp,
            orderCounter++
        ));

        // Compute position key (account+productId+collateral+isLong)
        bytes32 positionKey = _computePositionKey(msg.sender, productId, collateralToken, true);

        // Record position
        positions[positionKey] = MockPosition({
            user: msg.sender,
            productId: productId,
            subaccount: subaccount,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            sizeDelta: int256(sizeDeltaUsd),  // Positive for long
            timestamp: block.timestamp,
            isOpen: true
        });

        // Emit events
        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd);
        emit PositionOpened(positionKey, msg.sender, sizeDeltaUsd, collateralAmount);

        return orderKey;
    }

    /**
     * @notice Mock closing a market long position
     * @dev Implements IAdapter interface. Position identified by market+collateral+direction
     * @dev Returns collateral to caller (simulates position close returning tokens)
     */
    function closeMarketLong(
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        uint32 productId = uint32(uint160(market));

        // Compute position key
        bytes32 positionKey = _computePositionKey(msg.sender, productId, collateralToken, true);

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

        // Return collateral tokens to caller (simulates position close returning tokens)
        if (collateralToReturn > 0) {
            IERC20(collateralToken).transfer(msg.sender, collateralToReturn);
        }

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd);
        emit PositionClosed(positionKey, msg.sender);

        return orderKey;
    }

    // ============================================
    // Vertex-Specific Functions
    // ============================================

    /**
     * @notice Mock opening a market long with native Vertex productId
     * @dev Alternative function using uint32 productId directly
     */
    function openMarketLongByProductId(
        uint32 productId,
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice
    ) external payable returns (bytes32 orderKey) {
        bytes32 subaccount = getOrCreateSubaccount(msg.sender);

        orderKey = keccak256(abi.encode(
            msg.sender,
            productId,
            collateralAmount,
            sizeDeltaUsd,
            block.timestamp,
            orderCounter++
        ));

        bytes32 positionKey = _computePositionKey(msg.sender, productId, collateralToken, true);

        positions[positionKey] = MockPosition({
            user: msg.sender,
            productId: productId,
            subaccount: subaccount,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            sizeDelta: int256(sizeDeltaUsd),
            timestamp: block.timestamp,
            isOpen: true
        });

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd);
        emit PositionOpened(positionKey, msg.sender, sizeDeltaUsd, collateralAmount);

        return orderKey;
    }

    /**
     * @notice Mock opening a market short position
     * @dev Vertex natively supports shorts via negative sizeDelta
     */
    function openMarketShort(
        uint32 productId,
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice
    ) external payable returns (bytes32 orderKey) {
        bytes32 subaccount = getOrCreateSubaccount(msg.sender);

        orderKey = keccak256(abi.encode(
            msg.sender,
            productId,
            collateralAmount,
            sizeDeltaUsd,
            block.timestamp,
            orderCounter++
        ));

        bytes32 positionKey = _computePositionKey(msg.sender, productId, collateralToken, false);

        positions[positionKey] = MockPosition({
            user: msg.sender,
            productId: productId,
            subaccount: subaccount,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            sizeDelta: -int256(sizeDeltaUsd),  // Negative for short
            timestamp: block.timestamp,
            isOpen: true
        });

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd);
        emit PositionOpened(positionKey, msg.sender, sizeDeltaUsd, collateralAmount);

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
     * @notice Get position by user, productId, collateral, direction
     */
    function getPositionByParams(
        address user,
        uint32 productId,
        address collateralToken,
        bool isLong
    ) external view returns (MockPosition memory) {
        bytes32 positionKey = _computePositionKey(user, productId, collateralToken, isLong);
        return positions[positionKey];
    }

    /**
     * @notice Check if position is open
     */
    function isPositionOpen(bytes32 positionKey) external view returns (bool) {
        return positions[positionKey].isOpen;
    }

    /**
     * @notice Get user's subaccount
     */
    function getSubaccount(address user) external view returns (bytes32) {
        return subaccounts[user];
    }

    /**
     * @notice Check if position is long or short
     */
    function isLong(bytes32 positionKey) external view returns (bool) {
        return positions[positionKey].sizeDelta > 0;
    }

    /**
     * @notice Compute position key (matches GMX V2 pattern)
     */
    function computePositionKey(
        address account,
        uint32 productId,
        address collateralToken,
        bool long
    ) external pure returns (bytes32) {
        return _computePositionKey(account, productId, collateralToken, long);
    }

    // ============================================
    // Internal Functions
    // ============================================

    function _computePositionKey(
        address account,
        uint32 productId,
        address collateralToken,
        bool _isLong
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, productId, collateralToken, _isLong));
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
