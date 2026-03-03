// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/adapters/GMXAdapter.sol";

/**
 * @title GMXAdapter Fork Test
 * @notice UMIP Week 1 Deliverable: Test the GMXAdapter on Arbitrum fork
 * @dev Run with: forge test --fork-url https://arb1.arbitrum.io/rpc --match-contract GMXAdapterTest -vvv
 */
contract GMXAdapterTest is Test {
    GMXAdapter adapter;

    // Token Addresses (Arbitrum)
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // GMX Market
    address constant ETH_USD_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    address trader;

    function setUp() public {
        // Deploy adapter
        adapter = new GMXAdapter();

        // Create trader
        trader = makeAddr("trader");
        vm.deal(trader, 10 ether);

        // Give trader tokens
        deal(WETH, trader, 5 ether);
        deal(USDC, trader, 50000e6);

        console.log("=== GMXAdapter Test Setup ===");
        console.log("Adapter:", address(adapter));
        console.log("Trader:", trader);
    }

    /**
     * @notice Test opening a market long position with WETH collateral
     * @dev This is the core UMIP Week 1 goal: prove we can open positions from a contract
     */
    function test_OpenMarketLongWETH() public {
        console.log("\n=== Test: Open Market Long (WETH Collateral) ===");

        vm.startPrank(trader);

        uint256 collateralAmount = 0.1 ether; // 0.1 WETH
        uint256 sizeDeltaUsd = 1000e30; // $1000 position
        uint256 acceptablePrice = 5000e30; // Max $5000/ETH
        uint256 executionFee = 0.001 ether; // 0.001 ETH execution fee

        // Step 1: Transfer WETH to adapter
        console.log("Step 1: Transferring WETH to adapter...");
        IERC20(WETH).transfer(address(adapter), collateralAmount);

        // Step 2: Approve adapter to use WETH for GMX Router
        console.log("Step 2: Approving WETH...");
        vm.stopPrank();
        vm.prank(address(adapter));
        IERC20(WETH).approve(adapter.EXCHANGE_ROUTER(), collateralAmount);
        vm.startPrank(trader);

        // Step 3: Open position
        console.log("Step 3: Opening position...");
        bytes32 orderKey = adapter.openMarketLong{value: executionFee}(
            ETH_USD_MARKET,
            collateralAmount,
            WETH,
            sizeDeltaUsd,
            acceptablePrice,
            executionFee
        );

        console.log("Order created successfully!");
        console.log("Order Key:");
        console.logBytes32(orderKey);

        // Verify order key is non-zero
        assertTrue(orderKey != bytes32(0), "Order key should not be zero");

        vm.stopPrank();
    }

    /**
     * @notice Test opening a market long position with USDC collateral
     */
    function test_OpenMarketLongUSDC() public {
        console.log("\n=== Test: Open Market Long (USDC Collateral) ===");

        vm.startPrank(trader);

        uint256 collateralAmount = 200e6; // 200 USDC
        uint256 sizeDeltaUsd = 1000e30; // $1000 position
        uint256 acceptablePrice = 5000e30; // Max $5000/ETH
        uint256 executionFee = 0.001 ether;

        // Transfer USDC to adapter
        console.log("Transferring USDC to adapter...");
        IERC20(USDC).transfer(address(adapter), collateralAmount);

        // Approve USDC
        console.log("Approving USDC...");
        vm.stopPrank();
        vm.prank(address(adapter));
        IERC20(USDC).approve(adapter.EXCHANGE_ROUTER(), collateralAmount);
        vm.startPrank(trader);

        // Open position
        console.log("Opening position...");
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
     * @notice Test that execution fee validation works
     */
    function testFail_InsufficientExecutionFee() public {
        vm.startPrank(trader);

        uint256 collateralAmount = 0.1 ether;
        uint256 sizeDeltaUsd = 1000e30;
        uint256 acceptablePrice = 5000e30;
        uint256 executionFee = 0.001 ether;

        IERC20(WETH).transfer(address(adapter), collateralAmount);

        // This should fail: sending less ETH than execution fee
        adapter.openMarketLong{value: 0.0001 ether}(
            ETH_USD_MARKET,
            collateralAmount,
            WETH,
            sizeDeltaUsd,
            acceptablePrice,
            executionFee
        );

        vm.stopPrank();
    }
}
