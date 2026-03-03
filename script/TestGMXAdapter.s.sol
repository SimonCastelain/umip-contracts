// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/adapters/GMXAdapterSimple.sol";

/**
 * @title Test GMXAdapterSimple on Mainnet
 * @notice Interactive test script for validating adapter with small positions
 * @dev Run after deploying GMXAdapterSimple
 *
 * Usage:
 *   forge script script/TestGMXAdapter.s.sol \
 *     --rpc-url $ARBITRUM_RPC_URL \
 *     --broadcast \
 *     --private-key $TEST_WALLET_PRIVATE_KEY
 */
contract TestGMXAdapter is Script {
    // GMX Market
    address constant ETH_USD_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    // Tokens
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Test parameters (SMALL amounts)
    uint256 constant COLLATERAL_AMOUNT = 20e6; // $20 USDC
    uint256 constant POSITION_SIZE = 100e30; // $100 position (5x leverage)
    uint256 constant EXECUTION_FEE = 0.0001 ether; // ~$0.20 execution fee

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("TEST_WALLET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get deployed adapter address from environment or use latest deployment
        address adapterAddress = vm.envOr("GMX_ADAPTER_ADDRESS", address(0));
        require(adapterAddress != address(0), "Set GMX_ADAPTER_ADDRESS in .env");

        GMXAdapterSimple adapter = GMXAdapterSimple(payable(adapterAddress));

        console.log("=== GMXAdapter Mainnet Test ===");
        console.log("Deployer:", deployer);
        console.log("Adapter:", address(adapter));
        console.log("ETH balance:", deployer.balance);
        console.log("USDC balance:", IERC20(USDC).balanceOf(deployer));

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Transfer USDC to adapter
        console.log("\nStep 1: Transferring $20 USDC to adapter...");
        IERC20(USDC).transfer(address(adapter), COLLATERAL_AMOUNT);

        // Step 2: Open position
        console.log("Step 2: Opening $100 long position...");
        console.log("Collateral: $20 USDC");
        console.log("Position size: $100 (5x leverage)");
        console.log("Execution fee:", EXECUTION_FEE);

        bytes32 orderKey = adapter.openMarketLong{value: EXECUTION_FEE}(
            ETH_USD_MARKET,
            COLLATERAL_AMOUNT,
            USDC,
            POSITION_SIZE,
            type(uint256).max, // Accept any price (market order)
            EXECUTION_FEE
        );

        console.log("\n=== SUCCESS ===");
        console.log("Order created!");
        console.log("Order Key:");
        console.logBytes32(orderKey);
        console.log("\nNext steps:");
        console.log("1. Find this transaction on Arbiscan");
        console.log("2. Wait for keeper to execute (usually 1-5 minutes)");
        console.log("3. Check position on app.gmx.io");

        vm.stopBroadcast();
    }
}
