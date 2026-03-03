// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/adapters/GTradeAdapterMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Mock USDC for gTrade adapter testing
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/**
 * @title GTradeAdapterMock Test
 * @notice Validates mock gTrade adapter works correctly for vault integration
 *
 * Tests cover:
 * 1. Open position reduces adapter USDC balance
 * 2. Close position returns USDC to adapter caller
 * 3. getTrades() iteration finds correct trade by pairIndex
 * 4. Revert when no active trade for market
 * 5. Multiple open trades (different pairs) closes correct one
 * 6. Leverage derivation from sizeDeltaUsd / collateralAmount
 * 7. Trade counter increments correctly per user
 */
contract GTradeAdapterMockTest is Test {
    GTradeAdapterMock adapter;
    MockUSDC usdc;
    address user;
    address mockBTCMarket;
    address mockETHMarket;
    address mockLINKMarket;

    function setUp() public {
        adapter = new GTradeAdapterMock();
        usdc = new MockUSDC();
        user = makeAddr("user");
        mockBTCMarket = address(0x100);  // BTC/USD
        mockETHMarket = address(0x101);  // ETH/USD
        mockLINKMarket = address(0x102); // LINK/USD

        // Configure markets (mirrors real adapter setup)
        adapter.setMarket(mockBTCMarket, 0);   // pairIndex 0 = BTC
        adapter.setMarket(mockETHMarket, 1);   // pairIndex 1 = ETH
        adapter.setMarket(mockLINKMarket, 2);  // pairIndex 2 = LINK

        // Configure USDC collateral
        adapter.setCollateral(address(usdc), 3); // collateralIndex 3 = USDC

        vm.deal(user, 10 ether);
    }

    // ============================================
    // Test 1: Open position
    // ============================================

    function test_OpenPosition() public {
        // Simulate vault sending collateral to adapter
        usdc.mint(address(adapter), 100e6);

        vm.startPrank(user);

        bytes32 orderKey = adapter.openMarketLong(
            mockETHMarket,
            100e6,              // $100 collateral
            address(usdc),
            500e30,             // $500 position (5x leverage)
            type(uint256).max,  // accept any price
            0                   // no execution fee for gTrade
        );

        // orderKey should be pairIndex (1 for ETH)
        assertEq(uint256(orderKey), 1, "Order key should be pairIndex");

        // Verify trade stored correctly
        GTradeAdapterMock.MockTrade memory trade = adapter.getTrade(user, 0);
        assertEq(trade.user, user, "User should match");
        assertEq(trade.pairIndex, 1, "PairIndex should be ETH (1)");
        assertEq(trade.collateralAmount, 100e6, "Collateral should match");
        assertTrue(trade.isOpen, "Trade should be open");
        assertTrue(trade.long, "Trade should be long");

        // Verify leverage derivation: 500e30 * 1000 / (100e6 * 1e24) = 5000 (5x)
        assertEq(trade.leverage, 5000, "Leverage should be 5x (5000)");

        vm.stopPrank();
    }

    // ============================================
    // Test 2: Close position returns USDC
    // ============================================

    function test_ClosePosition() public {
        usdc.mint(address(adapter), 100e6);

        vm.startPrank(user);

        // Open position
        adapter.openMarketLong(
            mockETHMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0
        );

        // Verify adapter holds USDC
        assertEq(usdc.balanceOf(address(adapter)), 100e6, "Adapter should hold USDC");

        uint256 balanceBefore = usdc.balanceOf(user);

        // Close position
        bytes32 closeKey = adapter.closeMarketLong(
            mockETHMarket, address(usdc), 500e30, 0, 0
        );

        // Verify trade closed
        GTradeAdapterMock.MockTrade memory trade = adapter.getTrade(user, 0);
        assertFalse(trade.isOpen, "Trade should be closed");

        // Verify USDC returned to caller
        assertEq(usdc.balanceOf(user), balanceBefore + 100e6, "USDC should be returned");
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no USDC left");

        vm.stopPrank();
    }

    // ============================================
    // Test 3: getTrades() finds correct trade by pairIndex
    // ============================================

    function test_GetTrades_FiltersByOpenStatus() public {
        usdc.mint(address(adapter), 300e6);

        vm.startPrank(user);

        // Open 3 trades on different markets
        adapter.openMarketLong(mockBTCMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0);
        adapter.openMarketLong(mockETHMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0);
        adapter.openMarketLong(mockLINKMarket, 100e6, address(usdc), 200e30, type(uint256).max, 0);

        // getTrades should return all 3
        GTradeAdapterMock.MockTrade[] memory openTrades = adapter.getTrades(user);
        assertEq(openTrades.length, 3, "Should have 3 open trades");

        // Close ETH trade
        adapter.closeMarketLong(mockETHMarket, address(usdc), 500e30, 0, 0);

        // getTrades should now return 2
        openTrades = adapter.getTrades(user);
        assertEq(openTrades.length, 2, "Should have 2 open trades after closing ETH");

        // Verify remaining trades are BTC and LINK
        bool foundBTC = false;
        bool foundLINK = false;
        for (uint256 i = 0; i < openTrades.length; i++) {
            if (openTrades[i].pairIndex == 0) foundBTC = true;
            if (openTrades[i].pairIndex == 2) foundLINK = true;
        }
        assertTrue(foundBTC, "BTC trade should still be open");
        assertTrue(foundLINK, "LINK trade should still be open");

        vm.stopPrank();
    }

    // ============================================
    // Test 4: Revert when no active trade for market
    // ============================================

    function test_RevertWhenNoActiveTrade() public {
        vm.startPrank(user);

        // Try to close without any open trades
        vm.expectRevert("No active trade for market");
        adapter.closeMarketLong(mockETHMarket, address(usdc), 500e30, 0, 0);

        vm.stopPrank();
    }

    function test_RevertWhenClosingAlreadyClosedTrade() public {
        usdc.mint(address(adapter), 100e6);

        vm.startPrank(user);

        // Open and close
        adapter.openMarketLong(mockETHMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0);
        adapter.closeMarketLong(mockETHMarket, address(usdc), 500e30, 0, 0);

        // Try to close again
        vm.expectRevert("No active trade for market");
        adapter.closeMarketLong(mockETHMarket, address(usdc), 500e30, 0, 0);

        vm.stopPrank();
    }

    // ============================================
    // Test 5: Multiple trades — closes correct one
    // ============================================

    function test_MultipleTrades_ClosesCorrectOne() public {
        usdc.mint(address(adapter), 300e6);

        vm.startPrank(user);

        // Open BTC (100 USDC), ETH (150 USDC), LINK (50 USDC)
        adapter.openMarketLong(mockBTCMarket, 100e6, address(usdc), 1000e30, type(uint256).max, 0);
        adapter.openMarketLong(mockETHMarket, 150e6, address(usdc), 750e30, type(uint256).max, 0);
        adapter.openMarketLong(mockLINKMarket, 50e6, address(usdc), 250e30, type(uint256).max, 0);

        uint256 balanceBefore = usdc.balanceOf(user);

        // Close only ETH — should return 150 USDC
        adapter.closeMarketLong(mockETHMarket, address(usdc), 750e30, 0, 0);

        assertEq(usdc.balanceOf(user), balanceBefore + 150e6, "Should return ETH trade's 150 USDC");

        // BTC and LINK should still be open
        assertTrue(adapter.hasOpenTrade(user, 0), "BTC trade should still be open");
        assertFalse(adapter.hasOpenTrade(user, 1), "ETH trade should be closed");
        assertTrue(adapter.hasOpenTrade(user, 2), "LINK trade should still be open");

        vm.stopPrank();
    }

    // ============================================
    // Test 6: Leverage derivation
    // ============================================

    function test_LeverageDerivation() public {
        usdc.mint(address(adapter), 100e6);

        vm.startPrank(user);

        // 10x leverage: $1000 position on $100 collateral
        adapter.openMarketLong(mockETHMarket, 100e6, address(usdc), 1000e30, type(uint256).max, 0);

        GTradeAdapterMock.MockTrade memory trade = adapter.getTrade(user, 0);
        assertEq(trade.leverage, 10000, "Leverage should be 10x (10000 with 3 decimals)");

        vm.stopPrank();
    }

    function test_LeverageDerivation_HighLeverage() public {
        usdc.mint(address(adapter), 10e6);

        vm.startPrank(user);

        // 50x leverage: $500 position on $10 collateral
        adapter.openMarketLong(mockBTCMarket, 10e6, address(usdc), 500e30, type(uint256).max, 0);

        GTradeAdapterMock.MockTrade memory trade = adapter.getTrade(user, 0);
        assertEq(trade.leverage, 50000, "Leverage should be 50x (50000 with 3 decimals)");

        vm.stopPrank();
    }

    // ============================================
    // Test 7: Trade counter
    // ============================================

    function test_TradeCounter_Increments() public {
        usdc.mint(address(adapter), 300e6);

        vm.startPrank(user);

        assertEq(adapter.getTradeCount(user), 0, "Counter should start at 0");

        adapter.openMarketLong(mockBTCMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0);
        assertEq(adapter.getTradeCount(user), 1, "Counter should be 1");

        adapter.openMarketLong(mockETHMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0);
        assertEq(adapter.getTradeCount(user), 2, "Counter should be 2");

        // Close doesn't decrement counter (matches gTrade behavior)
        adapter.closeMarketLong(mockBTCMarket, address(usdc), 500e30, 0, 0);
        assertEq(adapter.getTradeCount(user), 2, "Counter should still be 2 after close");

        // New trade gets index 2, not 0
        adapter.openMarketLong(mockLINKMarket, 100e6, address(usdc), 200e30, type(uint256).max, 0);
        assertEq(adapter.getTradeCount(user), 3, "Counter should be 3");

        GTradeAdapterMock.MockTrade memory trade = adapter.getTrade(user, 2);
        assertEq(trade.pairIndex, 2, "Third trade should be LINK");
        assertEq(trade.index, 2, "Index should be 2");

        vm.stopPrank();
    }

    // ============================================
    // Test 8: Isolated users
    // ============================================

    function test_IsolatedUsers() public {
        address user2 = makeAddr("user2");
        usdc.mint(address(adapter), 200e6);

        vm.prank(user);
        adapter.openMarketLong(mockBTCMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0);

        vm.prank(user2);
        adapter.openMarketLong(mockBTCMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0);

        // Each user has their own counter
        assertEq(adapter.getTradeCount(user), 1, "User 1 count");
        assertEq(adapter.getTradeCount(user2), 1, "User 2 count");

        // Each user's trades are independent
        GTradeAdapterMock.MockTrade[] memory user1Trades = adapter.getTrades(user);
        GTradeAdapterMock.MockTrade[] memory user2Trades = adapter.getTrades(user2);
        assertEq(user1Trades.length, 1, "User 1 should have 1 trade");
        assertEq(user2Trades.length, 1, "User 2 should have 1 trade");
    }
}
