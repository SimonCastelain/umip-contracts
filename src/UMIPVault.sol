// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAdapter.sol";

/**
 * @title UMIPVault
 * @notice Hub-and-spoke vault for multi-platform perpetual position management
 * @dev Manages collateral flow between idle state and platform adapters (GMX, Vertex)
 *
 * Architecture:
 * - User deposits USDC -> tracked as idle collateral
 * - Opening position: idle -> transferred to adapter -> adapter opens position
 * - Closing position: adapter closes position -> collateral returned to vault -> idle
 *
 * Invariant (must always hold):
 * userIdleCollateral + userAllocatedToGMX + userAllocatedToVertex = userTotalDeposited
 */
contract UMIPVault {
    using SafeERC20 for IERC20;

    // ============================================
    // Types
    // ============================================

    enum Platform {
        GMX,
        Vertex,
        GainsTrade
    }

    struct Position {
        Platform platform;
        address market;              // Market address for closing
        uint256 collateralAmount;
        uint256 sizeDeltaUsd;        // For closing
        uint256 openTimestamp;
        bool isOpen;
    }

    // ============================================
    // State
    // ============================================

    IERC20 public immutable collateralToken;  // USDC

    // Collateral accounting (per user)
    mapping(address => uint256) public userIdleCollateral;
    mapping(address => uint256) public userAllocatedToGMX;
    mapping(address => uint256) public userAllocatedToVertex;
    mapping(address => uint256) public userAllocatedToGainsTrade;
    mapping(address => uint256) public userTotalDeposited;

    // Position tracking
    mapping(address => Position[]) public userPositions;
    mapping(address => uint256) public userPositionCount;

    // Adapters
    address public gmxAdapter;
    address public vertexAdapter;
    address public gainsTradeAdapter;

    // Configurable default markets (set via setMarket after deployment)
    mapping(Platform => address) public defaultMarket;

    // ============================================
    // Events
    // ============================================

    event Deposited(address indexed user, uint256 amount, uint256 newIdleBalance);
    event Withdrawn(address indexed user, uint256 amount, uint256 newIdleBalance);
    event PositionOpened(
        address indexed user,
        Platform platform,
        uint256 positionId,
        uint256 collateralAmount,
        address market
    );
    event PositionClosed(
        address indexed user,
        uint256 positionId,
        uint256 returnedAmount
    );
    event AdaptersUpdated(address gmxAdapter, address vertexAdapter, address gainsTradeAdapter);

    // ============================================
    // Errors
    // ============================================

    error InsufficientIdleCollateral(uint256 requested, uint256 available);
    error InvalidAmount();
    error PositionNotFound(uint256 positionId);
    error PositionAlreadyClosed(uint256 positionId);
    error AdapterNotSet(Platform platform);

    // ============================================
    // Constructor
    // ============================================

    constructor(address _collateralToken) {
        collateralToken = IERC20(_collateralToken);
    }

    // ============================================
    // Admin Functions
    // ============================================

    /**
     * @notice Set adapter addresses
     * @dev In production, this would have access control
     */
    function setAdapters(address _gmxAdapter, address _vertexAdapter, address _gainsTradeAdapter) external {
        gmxAdapter = _gmxAdapter;
        vertexAdapter = _vertexAdapter;
        gainsTradeAdapter = _gainsTradeAdapter;
        emit AdaptersUpdated(_gmxAdapter, _vertexAdapter, _gainsTradeAdapter);
    }

    /**
     * @notice Set the default market address for a platform
     * @dev Must be called post-deployment to configure network-specific market addresses
     */
    function setMarket(Platform platform, address market) external {
        defaultMarket[platform] = market;
    }

    // ============================================
    // Deposit / Withdraw
    // ============================================

    /**
     * @notice Deposit collateral into the vault
     * @param amount Amount of collateral token to deposit
     */
    function deposit(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        // Transfer tokens from user to vault
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // Track as idle collateral
        userIdleCollateral[msg.sender] += amount;
        userTotalDeposited[msg.sender] += amount;

        emit Deposited(msg.sender, amount, userIdleCollateral[msg.sender]);
    }

    /**
     * @notice Withdraw idle collateral from the vault
     * @param amount Amount to withdraw (must be <= idle collateral)
     */
    function withdraw(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        uint256 idle = userIdleCollateral[msg.sender];
        if (amount > idle) {
            revert InsufficientIdleCollateral(amount, idle);
        }

        // Update accounting
        userIdleCollateral[msg.sender] -= amount;
        userTotalDeposited[msg.sender] -= amount;

        // Transfer tokens back to user
        collateralToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, userIdleCollateral[msg.sender]);
    }

    // ============================================
    // Position Management
    // ============================================

    /**
     * @notice Open a position on a platform
     * @param platform The platform to open position on (GMX or Vertex)
     * @param collateralAmount Amount of collateral to allocate
     * @param sizeDeltaUsd Position size in USD (30 decimals for GMX)
     * @param acceptablePrice Maximum acceptable price (30 decimals)
     */
    function openPosition(
        Platform platform,
        uint256 collateralAmount,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice
    ) external payable returns (uint256 positionId) {
        // Check idle collateral
        uint256 idle = userIdleCollateral[msg.sender];
        if (collateralAmount > idle) {
            revert InsufficientIdleCollateral(collateralAmount, idle);
        }

        // Get adapter
        address adapter = _getAdapter(platform);
        if (adapter == address(0)) revert AdapterNotSet(platform);

        // Move collateral from idle to allocated
        userIdleCollateral[msg.sender] -= collateralAmount;
        if (platform == Platform.GMX) {
            userAllocatedToGMX[msg.sender] += collateralAmount;
        } else if (platform == Platform.Vertex) {
            userAllocatedToVertex[msg.sender] += collateralAmount;
        } else {
            userAllocatedToGainsTrade[msg.sender] += collateralAmount;
        }

        address market = _getDefaultMarket(platform);

        // Transfer collateral to adapter, then call openMarketLong
        _callAdapterOpen(
            adapter,
            market,
            collateralAmount,
            sizeDeltaUsd,
            acceptablePrice
        );

        // Track position
        positionId = userPositionCount[msg.sender];
        userPositions[msg.sender].push(Position({
            platform: platform,
            market: market,
            collateralAmount: collateralAmount,
            sizeDeltaUsd: sizeDeltaUsd,
            openTimestamp: block.timestamp,
            isOpen: true
        }));
        userPositionCount[msg.sender]++;

        emit PositionOpened(
            msg.sender,
            platform,
            positionId,
            collateralAmount,
            market
        );
    }

    /**
     * @notice Close a position and return collateral to idle
     * @param positionId The position ID to close
     */
    function closePosition(uint256 positionId) external payable {
        if (positionId >= userPositionCount[msg.sender]) {
            revert PositionNotFound(positionId);
        }

        Position storage position = userPositions[msg.sender][positionId];
        if (!position.isOpen) {
            revert PositionAlreadyClosed(positionId);
        }

        // Get adapter
        address adapter = _getAdapter(position.platform);
        if (adapter == address(0)) revert AdapterNotSet(position.platform);

        _callAdapterClose(
            adapter,
            position.market,
            position.sizeDeltaUsd
        );

        // Move collateral from allocated back to idle
        uint256 returnedAmount = position.collateralAmount;

        if (position.platform == Platform.GMX) {
            userAllocatedToGMX[msg.sender] -= position.collateralAmount;
        } else if (position.platform == Platform.Vertex) {
            userAllocatedToVertex[msg.sender] -= position.collateralAmount;
        } else {
            userAllocatedToGainsTrade[msg.sender] -= position.collateralAmount;
        }
        userIdleCollateral[msg.sender] += returnedAmount;

        // Mark closed
        position.isOpen = false;

        emit PositionClosed(msg.sender, positionId, returnedAmount);
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get user's collateral breakdown
     */
    function getUserCollateral(address user) external view returns (
        uint256 idle,
        uint256 allocatedGMX,
        uint256 allocatedVertex,
        uint256 allocatedGainsTrade,
        uint256 total
    ) {
        idle = userIdleCollateral[user];
        allocatedGMX = userAllocatedToGMX[user];
        allocatedVertex = userAllocatedToVertex[user];
        allocatedGainsTrade = userAllocatedToGainsTrade[user];
        total = userTotalDeposited[user];
    }

    /**
     * @notice Get user's position details
     */
    function getPosition(address user, uint256 positionId) external view returns (Position memory) {
        if (positionId >= userPositionCount[user]) {
            revert PositionNotFound(positionId);
        }
        return userPositions[user][positionId];
    }

    /**
     * @notice Verify the collateral invariant holds
     * @dev idle + allocatedGMX + allocatedVertex == total
     */
    function checkInvariant(address user) external view returns (bool) {
        uint256 sum = userIdleCollateral[user] +
                      userAllocatedToGMX[user] +
                      userAllocatedToVertex[user] +
                      userAllocatedToGainsTrade[user];
        return sum == userTotalDeposited[user];
    }

    // ============================================
    // Internal Functions
    // ============================================

    function _getAdapter(Platform platform) internal view returns (address) {
        if (platform == Platform.GMX) {
            return gmxAdapter;
        } else if (platform == Platform.Vertex) {
            return vertexAdapter;
        } else {
            return gainsTradeAdapter;
        }
    }

    /**
     * @notice Get default market for a platform
     */
    function _getDefaultMarket(Platform platform) internal view returns (address) {
        address configured = defaultMarket[platform];
        if (configured != address(0)) return configured;
        // Fallback placeholders (overridden by setMarket() post-deployment)
        if (platform == Platform.GMX) {
            return address(uint160(1));
        } else if (platform == Platform.Vertex) {
            return address(uint160(4));
        } else {
            return address(uint160(0x101));
        }
    }

    /**
     * @notice Transfer collateral to adapter and call openMarketLong
     */
    function _callAdapterOpen(
        address adapter,
        address market,
        uint256 collateralAmount,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice
    ) internal {
        collateralToken.safeTransfer(adapter, collateralAmount);

        IAdapter(adapter).openMarketLong{value: msg.value}(
            market,
            collateralAmount,
            address(collateralToken),
            sizeDeltaUsd,
            acceptablePrice,
            msg.value  // execution fee
        );
    }

    /**
     * @notice Call adapter to close position
     */
    function _callAdapterClose(
        address adapter,
        address market,
        uint256 sizeDeltaUsd
    ) internal {
        IAdapter(adapter).closeMarketLong{value: msg.value}(
            market,
            address(collateralToken),
            sizeDeltaUsd,
            0,  // acceptablePrice (0 = any price for market orders)
            msg.value  // execution fee
        );
    }
}
