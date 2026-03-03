// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/adapters/GMXAdapterSepolia.sol";

/**
 * @title Close position via GMXAdapterSepolia
 * @notice Closes the position opened by DeploySepoliaGMX
 *
 * Run:
 *   cd contracts
 *   source ../.env
 *   forge script script/CloseSepoliaGMX.s.sol \
 *     --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
 *     --broadcast \
 *     -vvvv
 *
 * Set GMX_ADAPTER_ADDRESS in .env after deployment
 */
contract CloseSepoliaGMX is Script {
    // Stargate USDC (matches DeploySepoliaGMX)
    address constant USDC = 0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773;
    // ETH/USD WETH-USDC.SG market (active on Sepolia)
    address constant ETH_USD_MARKET = 0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc;

    uint256 constant POSITION_SIZE = 500e30;          // Must match open size
    uint256 constant EXECUTION_FEE = 0.001 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address adapterAddress = vm.envAddress("GMX_ADAPTER_ADDRESS");

        GMXAdapterSepolia adapter = GMXAdapterSepolia(payable(adapterAddress));

        console.log("=== Close GMX Sepolia Position ===");
        console.log("Adapter:", adapterAddress);
        console.log("Deployer:", deployer);
        console.log("ETH balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        bytes32 orderKey = adapter.closeMarketLong{value: EXECUTION_FEE}(
            ETH_USD_MARKET,
            USDC,
            POSITION_SIZE,
            0, // Accept any price (market order — 0 = minimum for long close)
            EXECUTION_FEE
        );

        console.log("\n=== CLOSE ORDER CREATED ===");
        console.log("Order Key:");
        console.logBytes32(orderKey);
        console.log("\nCheck tx on https://sepolia.arbiscan.io");
        console.log("Wait for keeper execution, then verify position is closed");

        vm.stopBroadcast();
    }
}
