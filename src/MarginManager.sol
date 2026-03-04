// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UMIPVault.sol";

/**
 * @title MarginManager
 * @notice Tracks health factor across all user positions on GMX and Vertex
 * @dev Reads position data from UMIPVault to calculate aggregate margin health
 *
 * Health Factor = Total Collateral / Total Required Margin
 * - > 1.0 = healthy (collateral exceeds margin requirements)
 * - = 1.0 = at margin threshold
 * - < 1.0 = undercollateralized (liquidation risk)
 *
 * Uses basis points (10000 = 100%) for precision without floating point.
 * Health factor of 15000 = 150% = 1.5x collateralized.
 */
contract MarginManager {
    // ============================================
    // Constants
    // ============================================

    /// @notice 100% in basis points
    uint256 public constant BPS = 10000;

    /// @notice Default maintenance margin: 5% (500 bps)
    /// GMX maintenance margin is typically 1%, but we use 5% as safety buffer
    uint256 public constant DEFAULT_MAINTENANCE_MARGIN_BPS = 500;

    /// @notice Warning threshold: health factor below 150% (15000 bps)
    uint256 public constant WARNING_THRESHOLD_BPS = 15000;

    /// @notice Critical threshold: health factor below 120% (12000 bps)
    uint256 public constant CRITICAL_THRESHOLD_BPS = 12000;

    /// @notice Liquidation threshold: health factor below 100% (10000 bps)
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 10000;

    // ============================================
    // State
    // ============================================

    UMIPVault public immutable vault;

    /// @notice Per-platform maintenance margin override (in bps)
    /// 0 = use DEFAULT_MAINTENANCE_MARGIN_BPS
    mapping(UMIPVault.Platform => uint256) public platformMarginBps;

    // ============================================
    // Events
    // ============================================

    event HealthFactorChecked(
        address indexed user,
        uint256 healthFactorBps,
        uint256 totalCollateral,
        uint256 totalRequiredMargin
    );

    event HealthFactorWarning(
        address indexed user,
        uint256 healthFactorBps,
        string level // "WARNING", "CRITICAL", "LIQUIDATABLE"
    );

    event PlatformMarginUpdated(UMIPVault.Platform platform, uint256 marginBps);

    // ============================================
    // Errors
    // ============================================

    error InvalidMarginBps();

    // ============================================
    // Constructor
    // ============================================

    constructor(address _vault) {
        vault = UMIPVault(payable(_vault));
    }

    // ============================================
    // Admin Functions
    // ============================================

    /**
     * @notice Set maintenance margin for a specific platform
     * @dev In production, this would have access control
     * @param platform The platform (GMX or Vertex)
     * @param marginBps Maintenance margin in basis points (e.g., 500 = 5%)
     */
    function setPlatformMargin(UMIPVault.Platform platform, uint256 marginBps) external {
        if (marginBps == 0 || marginBps > BPS) revert InvalidMarginBps();
        platformMarginBps[platform] = marginBps;
        emit PlatformMarginUpdated(platform, marginBps);
    }

    // ============================================
    // Health Factor Calculation
    // ============================================

    /**
     * @notice Calculate aggregate health factor for a user across all positions
     * @param user The user address
     * @return healthFactorBps Health factor in basis points (10000 = 100%)
     * @return totalCollateral Total collateral allocated to open positions
     * @return totalRequiredMargin Total maintenance margin required
     */
    function getHealthFactor(address user) public view returns (
        uint256 healthFactorBps,
        uint256 totalCollateral,
        uint256 totalRequiredMargin
    ) {
        uint256 positionCount = vault.userPositionCount(user);

        if (positionCount == 0) {
            // No positions = infinite health (return max)
            return (type(uint256).max, 0, 0);
        }

        for (uint256 i = 0; i < positionCount; i++) {
            (
                UMIPVault.Platform platform,
                ,  // market
                uint256 collateralAmount,
                uint256 sizeDeltaUsd,
                ,  // openTimestamp
                bool isOpen
            ) = vault.userPositions(user, i);

            if (!isOpen) continue;

            totalCollateral += collateralAmount;

            // Convert size to 6 decimals (sizeDeltaUsd uses GMX's 30-decimal format)
            uint256 sizeIn6Decimals = sizeDeltaUsd / 1e24;
            uint256 marginBps = _getMarginBps(platform);
            uint256 requiredMargin = (sizeIn6Decimals * marginBps) / BPS;

            totalRequiredMargin += requiredMargin;
        }

        if (totalRequiredMargin == 0) {
            // No open positions with margin requirements
            return (type(uint256).max, totalCollateral, 0);
        }

        // Health factor = (totalCollateral * BPS) / totalRequiredMargin
        healthFactorBps = (totalCollateral * BPS) / totalRequiredMargin;
    }

    /**
     * @notice Check health and emit appropriate events
     * @param user The user address
     * @return healthFactorBps The current health factor
     */
    function checkHealth(address user) external returns (uint256 healthFactorBps) {
        uint256 totalCollateral;
        uint256 totalRequiredMargin;

        (healthFactorBps, totalCollateral, totalRequiredMargin) = getHealthFactor(user);

        emit HealthFactorChecked(user, healthFactorBps, totalCollateral, totalRequiredMargin);

        // Emit warnings based on threshold
        if (healthFactorBps < LIQUIDATION_THRESHOLD_BPS) {
            emit HealthFactorWarning(user, healthFactorBps, "LIQUIDATABLE");
        } else if (healthFactorBps < CRITICAL_THRESHOLD_BPS) {
            emit HealthFactorWarning(user, healthFactorBps, "CRITICAL");
        } else if (healthFactorBps < WARNING_THRESHOLD_BPS) {
            emit HealthFactorWarning(user, healthFactorBps, "WARNING");
        }
    }

    // ============================================
    // Per-Position Analysis
    // ============================================

    /**
     * @notice Get margin details for a specific position
     * @param user The user address
     * @param positionId The position ID in the vault
     * @return collateral Position collateral amount
     * @return requiredMargin Required maintenance margin
     * @return leverage Effective leverage in basis points (10000 = 1x)
     * @return positionHealthBps Position-level health factor
     */
    function getPositionMargin(address user, uint256 positionId) external view returns (
        uint256 collateral,
        uint256 requiredMargin,
        uint256 leverage,
        uint256 positionHealthBps
    ) {
        UMIPVault.Position memory pos = vault.getPosition(user, positionId);

        if (!pos.isOpen) {
            return (0, 0, 0, type(uint256).max);
        }

        collateral = pos.collateralAmount;

        // Convert size to 6 decimals
        uint256 sizeIn6Decimals = pos.sizeDeltaUsd / 1e24;

        // Required margin
        uint256 marginBps = _getMarginBps(pos.platform);
        requiredMargin = (sizeIn6Decimals * marginBps) / BPS;

        // Leverage = size / collateral (in bps, so 50000 = 5x)
        if (collateral > 0) {
            leverage = (sizeIn6Decimals * BPS) / collateral;
        }

        // Position health = collateral / required margin
        if (requiredMargin > 0) {
            positionHealthBps = (collateral * BPS) / requiredMargin;
        } else {
            positionHealthBps = type(uint256).max;
        }
    }

    // ============================================
    // Summary View
    // ============================================

    /**
     * @notice Get complete margin summary for a user
     * @param user The user address
     */
    function getUserSummary(address user) external view returns (
        uint256 idle,
        uint256 allocatedGMX,
        uint256 allocatedVertex,
        uint256 totalDeposited,
        uint256 openPositionCount,
        uint256 healthFactorBps,
        uint256 totalRequiredMargin,
        uint256 availableToWithdraw
    ) {
        (idle, allocatedGMX, allocatedVertex,, totalDeposited) = vault.getUserCollateral(user);

        uint256 posCount = vault.userPositionCount(user);
        for (uint256 i = 0; i < posCount; i++) {
            (,,,,, bool isOpen) = vault.userPositions(user, i);
            if (isOpen) openPositionCount++;
        }

        uint256 totalCollateral;
        (healthFactorBps, totalCollateral, totalRequiredMargin) = getHealthFactor(user);

        availableToWithdraw = idle;
    }

    // ============================================
    // Internal Functions
    // ============================================

    /**
     * @notice Get maintenance margin for a platform in basis points
     */
    function _getMarginBps(UMIPVault.Platform platform) internal view returns (uint256) {
        uint256 custom = platformMarginBps[platform];
        return custom > 0 ? custom : DEFAULT_MAINTENANCE_MARGIN_BPS;
    }
}
