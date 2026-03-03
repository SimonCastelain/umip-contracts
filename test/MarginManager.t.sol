// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MarginManager.sol";
import "../src/UMIPVault.sol";
import "../src/adapters/GMXAdapterMock.sol";
import "../src/adapters/VertexAdapterMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Mock USDC for MarginManager testing
 */
contract MockUSDCMargin is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MarginManager Tests
 * @notice Tests health factor calculation, thresholds, and per-position analysis
 */
contract MarginManagerTest is Test {
    MarginManager marginManager;
    UMIPVault vault;
    MockUSDCMargin usdc;
    GMXAdapterMock gmxAdapter;
    VertexAdapterMock vertexAdapter;

    address user;
    address user2;

    uint256 constant INITIAL_BALANCE = 10000e6; // 10,000 USDC

    function setUp() public {
        // Deploy contracts
        usdc = new MockUSDCMargin();
        vault = new UMIPVault(address(usdc));
        gmxAdapter = new GMXAdapterMock();
        vertexAdapter = new VertexAdapterMock();
        marginManager = new MarginManager(address(vault));

        // Set adapters
        vault.setAdapters(address(gmxAdapter), address(vertexAdapter), address(0));

        // Setup users
        user = makeAddr("user");
        user2 = makeAddr("user2");

        // Mint USDC
        usdc.mint(user, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);

        // Give ETH for execution fees
        vm.deal(user, 10 ether);
        vm.deal(user2, 10 ether);
    }

    // ============================================
    // No Positions
    // ============================================

    function test_NoPositions_ReturnsMaxHealth() public view {
        (uint256 healthBps, uint256 collateral, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(healthBps, type(uint256).max, "No positions = max health");
        assertEq(collateral, 0, "No collateral allocated");
        assertEq(margin, 0, "No margin required");
    }

    // ============================================
    // Single Position Health Factor
    // ============================================

    function test_SinglePosition_HealthyLeverage() public {
        // $1000 collateral, $2000 position = 2x leverage
        // Required margin at 5% = $100
        // Health factor = $1000 / $100 = 10x = 100000 bps
        _openGMXPosition(user, 1000e6, 2000e30);

        (uint256 healthBps, uint256 collateral, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(collateral, 1000e6, "Collateral should be 1000 USDC");
        assertEq(margin, 100e6, "Required margin should be 100 USDC (5% of 2000)");
        assertEq(healthBps, 100000, "Health factor should be 1000%");
    }

    function test_SinglePosition_HighLeverage() public {
        // $100 collateral, $2000 position = 20x leverage
        // Required margin at 5% = $100
        // Health factor = $100 / $100 = 1x = 10000 bps (at liquidation threshold!)
        _openGMXPosition(user, 100e6, 2000e30);

        (uint256 healthBps,, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(margin, 100e6, "Required margin should be 100 USDC");
        assertEq(healthBps, 10000, "Health factor should be exactly 100% (liquidation threshold)");
    }

    function test_SinglePosition_5xLeverage() public {
        // $200 collateral, $1000 position = 5x leverage
        // Required margin at 5% = $50
        // Health factor = $200 / $50 = 4x = 40000 bps
        _openGMXPosition(user, 200e6, 1000e30);

        (uint256 healthBps,, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(margin, 50e6, "Required margin should be 50 USDC");
        assertEq(healthBps, 40000, "Health factor should be 400%");
    }

    // ============================================
    // Multi-Position Aggregate Health
    // ============================================

    function test_MultiPosition_AggregateHealth() public {
        // Position 1: $400 collateral, $2000 size on GMX
        // Position 2: $300 collateral, $1500 size on Vertex
        // Total collateral: $700
        // Total required margin: $100 + $75 = $175
        // Health factor = $700 / $175 = 4x = 40000 bps
        _openGMXPosition(user, 400e6, 2000e30);
        _openVertexPosition(user, 300e6, 1500e30);

        (uint256 healthBps, uint256 collateral, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(collateral, 700e6, "Total collateral should be 700");
        assertEq(margin, 175e6, "Total margin should be 175");
        assertEq(healthBps, 40000, "Health factor should be 400%");
    }

    function test_MultiPosition_DifferentPlatformMargins() public {
        // Set Vertex margin to 10% (more conservative)
        marginManager.setPlatformMargin(UMIPVault.Platform.Vertex, 1000);

        // Position 1: $400 collateral, $2000 size on GMX (5% margin = $100)
        // Position 2: $300 collateral, $1500 size on Vertex (10% margin = $150)
        // Total collateral: $700
        // Total required margin: $100 + $150 = $250
        // Health factor = $700 / $250 = 2.8x = 28000 bps
        _openGMXPosition(user, 400e6, 2000e30);
        _openVertexPosition(user, 300e6, 1500e30);

        (uint256 healthBps, uint256 collateral, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(collateral, 700e6, "Total collateral should be 700");
        assertEq(margin, 250e6, "Total margin should be 250");
        assertEq(healthBps, 28000, "Health factor should be 280%");
    }

    // ============================================
    // Closed Positions Excluded
    // ============================================

    function test_ClosedPositions_Excluded() public {
        // Open two positions
        _openGMXPosition(user, 400e6, 2000e30);
        _openVertexPosition(user, 300e6, 1500e30);

        // Close the GMX position
        vm.prank(user);
        vault.closePosition{value: 0.001 ether}(0); // positionId 0

        // Only Vertex position should count
        // Collateral: $300, Required margin: $75
        // Health = $300 / $75 = 4x = 40000 bps
        (uint256 healthBps, uint256 collateral, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(collateral, 300e6, "Only Vertex collateral should count");
        assertEq(margin, 75e6, "Only Vertex margin should count");
        assertEq(healthBps, 40000, "Health factor should be 400%");
    }

    function test_AllPositionsClosed_MaxHealth() public {
        _openGMXPosition(user, 400e6, 2000e30);

        vm.prank(user);
        vault.closePosition{value: 0.001 ether}(0);

        (uint256 healthBps,, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(margin, 0, "No margin required");
        assertEq(healthBps, type(uint256).max, "All closed = max health");
    }

    // ============================================
    // Health Check Events
    // ============================================

    function test_CheckHealth_EmitsWarning() public {
        // $120 collateral, $2000 position = 16.6x leverage
        // Required margin at 5% = $100
        // Health factor = $120 / $100 = 1.2x = 12000 bps (WARNING level)
        _openGMXPosition(user, 120e6, 2000e30);

        vm.expectEmit(true, false, false, true);
        emit MarginManager.HealthFactorChecked(user, 12000, 120e6, 100e6);

        vm.expectEmit(true, false, false, true);
        emit MarginManager.HealthFactorWarning(user, 12000, "WARNING");

        marginManager.checkHealth(user);
    }

    function test_CheckHealth_EmitsCritical() public {
        // $110 collateral, $2000 position
        // Health = $110 / $100 = 1.1x = 11000 bps (CRITICAL level)
        _openGMXPosition(user, 110e6, 2000e30);

        vm.expectEmit(true, false, false, true);
        emit MarginManager.HealthFactorWarning(user, 11000, "CRITICAL");

        marginManager.checkHealth(user);
    }

    function test_CheckHealth_EmitsLiquidatable() public {
        // $90 collateral, $2000 position
        // Health = $90 / $100 = 0.9x = 9000 bps (LIQUIDATABLE)
        _openGMXPosition(user, 90e6, 2000e30);

        vm.expectEmit(true, false, false, true);
        emit MarginManager.HealthFactorWarning(user, 9000, "LIQUIDATABLE");

        marginManager.checkHealth(user);
    }

    function test_CheckHealth_NoWarningWhenHealthy() public {
        // $500 collateral, $2000 position
        // Health = $500 / $100 = 5x = 50000 bps (well above warning)
        _openGMXPosition(user, 500e6, 2000e30);

        // Only HealthFactorChecked should emit, NOT HealthFactorWarning
        vm.expectEmit(true, false, false, true);
        emit MarginManager.HealthFactorChecked(user, 50000, 500e6, 100e6);

        // Record logs to verify no warning emitted
        vm.recordLogs();
        marginManager.checkHealth(user);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Should have exactly 1 log (HealthFactorChecked only)
        assertEq(logs.length, 1, "Should only emit HealthFactorChecked");
    }

    // ============================================
    // Per-Position Analysis
    // ============================================

    function test_PositionMargin_Details() public {
        // $200 collateral, $1000 size = 5x leverage
        _openGMXPosition(user, 200e6, 1000e30);

        (
            uint256 collateral,
            uint256 requiredMargin,
            uint256 leverage,
            uint256 positionHealthBps
        ) = marginManager.getPositionMargin(user, 0);

        assertEq(collateral, 200e6, "Collateral should be 200");
        assertEq(requiredMargin, 50e6, "Required margin should be 50 (5% of 1000)");
        assertEq(leverage, 50000, "Leverage should be 5x (50000 bps)");
        assertEq(positionHealthBps, 40000, "Position health should be 400%");
    }

    function test_PositionMargin_ClosedPosition() public {
        _openGMXPosition(user, 200e6, 1000e30);

        vm.prank(user);
        vault.closePosition{value: 0.001 ether}(0);

        (
            uint256 collateral,
            uint256 requiredMargin,
            uint256 leverage,
            uint256 positionHealthBps
        ) = marginManager.getPositionMargin(user, 0);

        assertEq(collateral, 0, "Closed position = 0 collateral");
        assertEq(requiredMargin, 0, "Closed position = 0 margin");
        assertEq(leverage, 0, "Closed position = 0 leverage");
        assertEq(positionHealthBps, type(uint256).max, "Closed = max health");
    }

    // ============================================
    // User Summary
    // ============================================

    function test_UserSummary_Complete() public {
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX, 400e6, 2000e30, type(uint256).max
        );
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex, 300e6, 1500e30, type(uint256).max
        );
        vm.stopPrank();

        (
            uint256 idle,
            uint256 allocatedGMX,
            uint256 allocatedVertex,
            uint256 totalDeposited,
            uint256 openPositionCount,
            uint256 healthFactorBps,
            uint256 totalRequiredMargin,
            uint256 availableToWithdraw
        ) = marginManager.getUserSummary(user);

        assertEq(idle, 300e6, "300 idle");
        assertEq(allocatedGMX, 400e6, "400 on GMX");
        assertEq(allocatedVertex, 300e6, "300 on Vertex");
        assertEq(totalDeposited, 1000e6, "1000 total");
        assertEq(openPositionCount, 2, "2 open positions");
        assertEq(healthFactorBps, 40000, "Health = 400%");
        assertEq(totalRequiredMargin, 175e6, "175 total margin");
        assertEq(availableToWithdraw, 300e6, "300 available to withdraw");
    }

    // ============================================
    // Platform Margin Config
    // ============================================

    function test_SetPlatformMargin() public {
        marginManager.setPlatformMargin(UMIPVault.Platform.GMX, 200); // 2%

        _openGMXPosition(user, 200e6, 2000e30);

        // Required margin at 2% = $40
        // Health = $200 / $40 = 5x = 50000 bps
        (uint256 healthBps,, uint256 margin) = marginManager.getHealthFactor(user);

        assertEq(margin, 40e6, "Margin should be 40 at 2%");
        assertEq(healthBps, 50000, "Health should be 500%");
    }

    function test_SetPlatformMargin_RevertsOnInvalid() public {
        vm.expectRevert(MarginManager.InvalidMarginBps.selector);
        marginManager.setPlatformMargin(UMIPVault.Platform.GMX, 0);

        vm.expectRevert(MarginManager.InvalidMarginBps.selector);
        marginManager.setPlatformMargin(UMIPVault.Platform.GMX, 10001);
    }

    // ============================================
    // Multi-User Isolation
    // ============================================

    function test_MultiUser_IsolatedHealth() public {
        // User 1: conservative (2x leverage)
        _openGMXPosition(user, 1000e6, 2000e30);

        // User 2: aggressive (10x leverage)
        _openGMXPosition(user2, 200e6, 2000e30);

        (uint256 health1,,) = marginManager.getHealthFactor(user);
        (uint256 health2,,) = marginManager.getHealthFactor(user2);

        assertEq(health1, 100000, "User1 health = 1000%");
        assertEq(health2, 20000, "User2 health = 200%");

        assertTrue(health1 > health2, "User1 should be healthier");
    }

    // ============================================
    // Helpers
    // ============================================

    function _openGMXPosition(address _user, uint256 collateral, uint256 size) internal {
        vm.startPrank(_user);
        usdc.approve(address(vault), collateral);
        vault.deposit(collateral);
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX, collateral, size, type(uint256).max
        );
        vm.stopPrank();
    }

    function _openVertexPosition(address _user, uint256 collateral, uint256 size) internal {
        vm.startPrank(_user);
        usdc.approve(address(vault), collateral);
        vault.deposit(collateral);
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex, collateral, size, type(uint256).max
        );
        vm.stopPrank();
    }
}
