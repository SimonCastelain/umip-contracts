// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/adapters/VertexAdapterMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Mock USDC for adapter testing
 */
contract MockTokenVertex is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title VertexAdapterMock Test
 * @notice Validates mock Vertex adapter works correctly for vault integration
 *
 * Week 4 Updates:
 * - Position tracking by account+productId+collateral+isLong (not orderKey)
 * - closeMarketLong no longer takes positionKey parameter
 * - openMarketLongByProductId and openMarketShort now require collateralToken
 * - Close tests require tokens to be sent to adapter first (simulating vault flow)
 */
contract VertexAdapterMockTest is Test {
    VertexAdapterMock adapter;
    MockTokenVertex usdc;
    address user;
    address user2;

    function setUp() public {
        adapter = new VertexAdapterMock();
        usdc = new MockTokenVertex();
        user = makeAddr("user");
        user2 = makeAddr("user2");
        vm.deal(user, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function test_OpenPositionWithAddressInterface() public {
        vm.startPrank(user);

        // Use address-based interface (compatible with IAdapter)
        bytes32 orderKey = adapter.openMarketLong{value: 0.001 ether}(
            address(uint160(adapter.PRODUCT_ETH_PERP())), // productId as address
            100e6,              // $100 USDC collateral
            address(usdc),      // collateral token
            500e30,             // $500 position size
            type(uint256).max,  // accept any price
            0.001 ether         // execution fee
        );

        assertTrue(orderKey != bytes32(0), "Order key should not be zero");

        // Position is now tracked by account+productId+collateral+isLong
        bytes32 positionKey = adapter.computePositionKey(
            user, adapter.PRODUCT_ETH_PERP(), address(usdc), true
        );
        assertTrue(adapter.isPositionOpen(positionKey), "Position should be open");

        VertexAdapterMock.MockPosition memory pos = adapter.getPosition(positionKey);
        assertEq(pos.user, user, "User should match");
        assertEq(pos.collateralAmount, 100e6, "Collateral should match");
        assertTrue(pos.sizeDelta > 0, "Should be long position");
        assertTrue(pos.isOpen, "Position should be marked open");

        vm.stopPrank();
    }

    function test_OpenPositionWithProductId() public {
        vm.startPrank(user);

        // Use native Vertex productId interface
        bytes32 orderKey = adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_ETH_PERP(), // ETH-PERP
            100e6,                       // $100 USDC
            address(usdc),               // collateral token
            500e30,                      // $500 size
            type(uint256).max            // accept any price
        );

        assertTrue(orderKey != bytes32(0), "Order key should not be zero");

        bytes32 positionKey = adapter.computePositionKey(
            user, adapter.PRODUCT_ETH_PERP(), address(usdc), true
        );
        assertTrue(adapter.isPositionOpen(positionKey), "Position should be open");

        VertexAdapterMock.MockPosition memory pos = adapter.getPosition(positionKey);
        assertEq(pos.productId, adapter.PRODUCT_ETH_PERP(), "Product ID should match");

        vm.stopPrank();
    }

    function test_OpenShortPosition() public {
        vm.startPrank(user);

        bytes32 orderKey = adapter.openMarketShort{value: 0.001 ether}(
            adapter.PRODUCT_BTC_PERP(), // BTC-PERP
            200e6,                       // $200 USDC
            address(usdc),               // collateral token
            1000e30,                     // $1000 size
            0                            // any price
        );

        assertTrue(orderKey != bytes32(0), "Order key should not be zero");

        bytes32 positionKey = adapter.computePositionKey(
            user, adapter.PRODUCT_BTC_PERP(), address(usdc), false  // isLong = false for short
        );
        assertTrue(adapter.isPositionOpen(positionKey), "Position should be open");
        assertFalse(adapter.isLong(positionKey), "Should be short position");

        VertexAdapterMock.MockPosition memory pos = adapter.getPosition(positionKey);
        assertTrue(pos.sizeDelta < 0, "Size delta should be negative for short");

        vm.stopPrank();
    }

    function test_ClosePosition() public {
        // Simulate vault flow: mint tokens to adapter (as if vault sent them)
        usdc.mint(address(adapter), 100e6);

        vm.startPrank(user);

        address productAsAddress = address(uint160(adapter.PRODUCT_ETH_PERP()));

        // Open position
        adapter.openMarketLong{value: 0.001 ether}(
            productAsAddress,
            100e6,
            address(usdc),
            500e30,
            type(uint256).max,
            0.001 ether
        );

        // Verify position is open
        bytes32 positionKey = adapter.computePositionKey(
            user, adapter.PRODUCT_ETH_PERP(), address(usdc), true
        );
        assertTrue(adapter.isPositionOpen(positionKey), "Position should be open");

        uint256 balanceBefore = usdc.balanceOf(user);

        // Close position - no positionKey param, uses market+collateral+direction
        bytes32 closeOrderKey = adapter.closeMarketLong{value: 0.001 ether}(
            productAsAddress,
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

    function test_SubaccountCreation() public {
        vm.startPrank(user);

        // Subaccount should not exist initially
        bytes32 subaccountBefore = adapter.getSubaccount(user);
        assertEq(subaccountBefore, bytes32(0), "Subaccount should not exist initially");

        // Opening a position creates a subaccount
        adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_ETH_PERP(),
            100e6,
            address(usdc),
            500e30,
            type(uint256).max
        );

        bytes32 subaccount = adapter.getSubaccount(user);
        assertTrue(subaccount != bytes32(0), "Subaccount should be created");

        vm.stopPrank();

        // Different user gets different subaccount
        vm.startPrank(user2);

        adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_ETH_PERP(),
            50e6,
            address(usdc),
            250e30,
            type(uint256).max
        );

        bytes32 subaccount2 = adapter.getSubaccount(user2);
        assertTrue(subaccount2 != bytes32(0), "User2 should have subaccount");
        assertTrue(subaccount != subaccount2, "Subaccounts should be unique per user");

        vm.stopPrank();
    }

    function test_MultiplePositions() public {
        vm.startPrank(user);

        // Open ETH long
        adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_ETH_PERP(), 100e6, address(usdc), 500e30, type(uint256).max
        );

        // Open BTC long
        adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_BTC_PERP(), 200e6, address(usdc), 1000e30, type(uint256).max
        );

        // Open ARB short
        adapter.openMarketShort{value: 0.001 ether}(
            adapter.PRODUCT_ARB_PERP(), 50e6, address(usdc), 250e30, 0
        );

        bytes32 pos1Key = adapter.computePositionKey(user, adapter.PRODUCT_ETH_PERP(), address(usdc), true);
        bytes32 pos2Key = adapter.computePositionKey(user, adapter.PRODUCT_BTC_PERP(), address(usdc), true);
        bytes32 pos3Key = adapter.computePositionKey(user, adapter.PRODUCT_ARB_PERP(), address(usdc), false);

        assertTrue(pos1Key != pos2Key, "Position keys should be unique");
        assertTrue(pos2Key != pos3Key, "Position keys should be unique");
        assertTrue(adapter.isPositionOpen(pos1Key), "Position 1 should be open");
        assertTrue(adapter.isPositionOpen(pos2Key), "Position 2 should be open");
        assertTrue(adapter.isPositionOpen(pos3Key), "Position 3 should be open");

        // Verify different position types
        assertTrue(adapter.isLong(pos1Key), "Pos1 should be long");
        assertTrue(adapter.isLong(pos2Key), "Pos2 should be long");
        assertFalse(adapter.isLong(pos3Key), "Pos3 should be short");

        vm.stopPrank();
    }

    function test_MultipleProducts() public {
        vm.startPrank(user);

        // Open positions on different products
        adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_ETH_PERP(), 100e6, address(usdc), 500e30, type(uint256).max
        );

        adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_BTC_PERP(), 100e6, address(usdc), 500e30, type(uint256).max
        );

        adapter.openMarketLongByProductId{value: 0.001 ether}(
            adapter.PRODUCT_ARB_PERP(), 100e6, address(usdc), 500e30, type(uint256).max
        );

        // Verify product IDs via getPositionByParams
        VertexAdapterMock.MockPosition memory ethPos = adapter.getPositionByParams(
            user, adapter.PRODUCT_ETH_PERP(), address(usdc), true
        );
        VertexAdapterMock.MockPosition memory btcPos = adapter.getPositionByParams(
            user, adapter.PRODUCT_BTC_PERP(), address(usdc), true
        );
        VertexAdapterMock.MockPosition memory arbPos = adapter.getPositionByParams(
            user, adapter.PRODUCT_ARB_PERP(), address(usdc), true
        );

        assertEq(ethPos.productId, adapter.PRODUCT_ETH_PERP());
        assertEq(btcPos.productId, adapter.PRODUCT_BTC_PERP());
        assertEq(arbPos.productId, adapter.PRODUCT_ARB_PERP());

        vm.stopPrank();
    }
}
