// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/adapters/GMXAdapterSimple.sol";

/**
 * @title GMXAdapterSimple Fork Test
 * @notice Tests GMX V2.2+ adapter against real Arbitrum mainnet contracts
 * @dev Run with: forge test --fork-url https://arb1.arbitrum.io/rpc --match-contract GMXAdapterSimpleTest -vv
 *
 * These tests validate the multicall(sendWnt + createOrder) pattern
 * that was proven on Arbitrum Sepolia (see umip_week5_gmx_validation.md).
 *
 * Expected behavior on fork:
 * - createOrder succeeds (order is created in DataStore)
 * - Keeper execution doesn't happen (no keepers on fork)
 * - We can only validate order creation, not position fills
 */
contract GMXAdapterSimpleTest is Test {
    GMXAdapterSimple adapter;

    // Token Addresses (Arbitrum Mainnet)
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // GMX Market (Arbitrum Mainnet — ETH/USD)
    address constant ETH_USD_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    address trader;

    function setUp() public {
        adapter = new GMXAdapterSimple();
        trader = makeAddr("trader");
        vm.deal(trader, 10 ether);
        deal(WETH, trader, 5 ether);
        deal(USDC, trader, 50000e6);

        console.log("=== GMXAdapterSimple Fork Test ===");
        console.log("Adapter:", address(adapter));
        console.log("Trader:", trader);
    }

    /**
     * @notice Test opening a market long position with USDC collateral
     * @dev Validates the full multicall(sendWnt + createOrder) pattern
     */
    function test_OpenMarketLongUSDC() public {
        vm.startPrank(trader);

        uint256 collateralAmount = 200e6;
        uint256 sizeDeltaUsd = 1000e30;
        uint256 acceptablePrice = type(uint256).max;
        uint256 executionFee = 0.001 ether;

        // Transfer USDC to adapter (simulates vault sending collateral)
        IERC20(USDC).transfer(address(adapter), collateralAmount);

        // Open position via multicall pattern
        bytes32 orderKey = adapter.openMarketLong{value: executionFee}(
            ETH_USD_MARKET,
            collateralAmount,
            USDC,
            sizeDeltaUsd,
            acceptablePrice,
            executionFee
        );

        console.log("Order created successfully!");
        console.logBytes32(orderKey);

        assertTrue(orderKey != bytes32(0), "Order key should not be zero");

        vm.stopPrank();
    }

    /**
     * @notice Test opening a market long position with WETH collateral
     */
    function test_OpenMarketLongWETH() public {
        vm.startPrank(trader);

        uint256 collateralAmount = 0.1 ether;
        uint256 sizeDeltaUsd = 1000e30;
        uint256 acceptablePrice = type(uint256).max;
        uint256 executionFee = 0.001 ether;

        IERC20(WETH).transfer(address(adapter), collateralAmount);

        bytes32 orderKey = adapter.openMarketLong{value: executionFee}(
            ETH_USD_MARKET,
            collateralAmount,
            WETH,
            sizeDeltaUsd,
            acceptablePrice,
            executionFee
        );

        console.logBytes32(orderKey);
        assertTrue(orderKey != bytes32(0), "Order key should not be zero");

        vm.stopPrank();
    }

    /**
     * @notice Test that insufficient execution fee reverts
     */
    function test_RevertInsufficientExecutionFee() public {
        vm.startPrank(trader);

        IERC20(USDC).transfer(address(adapter), 200e6);

        vm.expectRevert(GMXAdapterSimple.InsufficientExecutionFee.selector);
        adapter.openMarketLong{value: 0.0001 ether}(
            ETH_USD_MARKET,
            200e6,
            USDC,
            1000e30,
            type(uint256).max,
            0.001 ether // requires 0.001 but only sending 0.0001
        );

        vm.stopPrank();
    }
}
