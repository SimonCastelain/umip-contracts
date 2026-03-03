// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/adapters/GMXAdapterMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Mock USDC for adapter testing
 */
contract MockToken is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title GMXAdapterMock Test
 * @notice Validates mock adapter works correctly for vault integration
 *
 * Week 4 Updates:
 * - Position tracking by account+market+collateral+isLong (not orderKey)
 * - closeMarketLong no longer takes positionKey parameter
 * - Close tests require tokens to be sent to adapter first (simulating vault flow)
 */
contract GMXAdapterMockTest is Test {
    GMXAdapterMock adapter;
    MockToken usdc;
    address user;
    address mockMarket;

    function setUp() public {
        adapter = new GMXAdapterMock();
        usdc = new MockToken();
        user = makeAddr("user");
        mockMarket = address(0x1);
        vm.deal(user, 10 ether);
    }

    function test_OpenPosition() public {
        vm.startPrank(user);

        bytes32 orderKey = adapter.openMarketLong{value: 0.001 ether}(
            mockMarket,
            100e6,              // $100 collateral
            address(usdc),
            500e30,             // $500 position
            type(uint256).max,  // accept any price
            0.001 ether         // execution fee
        );

        assertTrue(orderKey != bytes32(0), "Order key should not be zero");

        // Position is now tracked by account+market+collateral+isLong, not orderKey
        bytes32 positionKey = adapter.computePositionKey(user, mockMarket, address(usdc), true);
        assertTrue(adapter.isPositionOpen(positionKey), "Position should be open");

        GMXAdapterMock.MockPosition memory pos = adapter.getPosition(positionKey);
        assertEq(pos.user, user, "User should match");
        assertEq(pos.collateralAmount, 100e6, "Collateral should match");
        assertEq(pos.sizeDeltaUsd, 500e30, "Size should match");
        assertTrue(pos.isOpen, "Position should be marked open");

        vm.stopPrank();
    }

    function test_ClosePosition() public {
        // Simulate vault flow: mint tokens to adapter (as if vault sent them)
        usdc.mint(address(adapter), 100e6);

        vm.startPrank(user);

        // Open position
        adapter.openMarketLong{value: 0.001 ether}(
            mockMarket,
            100e6,
            address(usdc),
            500e30,
            type(uint256).max,
            0.001 ether
        );

        // Compute position key for verification
        bytes32 positionKey = adapter.computePositionKey(user, mockMarket, address(usdc), true);
        assertTrue(adapter.isPositionOpen(positionKey), "Position should be open");

        uint256 balanceBefore = usdc.balanceOf(user);

        // Close position - no positionKey param needed, uses market+collateral+direction
        bytes32 closeOrderKey = adapter.closeMarketLong{value: 0.001 ether}(
            mockMarket,
            address(usdc),
            500e30,
            0,              // acceptablePrice
            0.001 ether     // executionFee
        );

        assertTrue(closeOrderKey != bytes32(0), "Close order key should not be zero");
        assertFalse(adapter.isPositionOpen(positionKey), "Position should be closed");

        // Verify tokens were returned
        assertEq(usdc.balanceOf(user), balanceBefore + 100e6, "Tokens should be returned");

        vm.stopPrank();
    }

    function test_MultiplePositions_DifferentMarkets() public {
        vm.startPrank(user);

        address market1 = address(0x1);
        address market2 = address(0x3);

        // Open position on market 1
        adapter.openMarketLong{value: 0.001 ether}(
            market1, 100e6, address(usdc), 500e30, type(uint256).max, 0.001 ether
        );

        // Open position on market 2
        adapter.openMarketLong{value: 0.001 ether}(
            market2, 200e6, address(usdc), 1000e30, type(uint256).max, 0.001 ether
        );

        bytes32 pos1Key = adapter.computePositionKey(user, market1, address(usdc), true);
        bytes32 pos2Key = adapter.computePositionKey(user, market2, address(usdc), true);

        assertTrue(pos1Key != pos2Key, "Position keys should be unique");
        assertTrue(adapter.isPositionOpen(pos1Key), "Position 1 should be open");
        assertTrue(adapter.isPositionOpen(pos2Key), "Position 2 should be open");

        GMXAdapterMock.MockPosition memory pos1 = adapter.getPosition(pos1Key);
        GMXAdapterMock.MockPosition memory pos2 = adapter.getPosition(pos2Key);

        assertEq(pos1.collateralAmount, 100e6, "Position 1 collateral");
        assertEq(pos2.collateralAmount, 200e6, "Position 2 collateral");

        vm.stopPrank();
    }

    function test_GetPositionByParams() public {
        vm.startPrank(user);

        adapter.openMarketLong{value: 0.001 ether}(
            mockMarket, 100e6, address(usdc), 500e30, type(uint256).max, 0.001 ether
        );

        // Use the helper function to get position
        GMXAdapterMock.MockPosition memory pos = adapter.getPositionByParams(
            user, mockMarket, address(usdc), true
        );

        assertEq(pos.user, user, "User should match");
        assertEq(pos.collateralAmount, 100e6, "Collateral should match");
        assertTrue(pos.isOpen, "Position should be open");

        vm.stopPrank();
    }
}
