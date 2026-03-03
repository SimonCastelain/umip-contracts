// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/adapters/GMXAdapterSimple.sol";

/**
 * @title Deploy GMXAdapterSimple
 * @notice Deployment script for UMIP GMX adapter
 * @dev Run with:
 *   Arbitrum Goerli:
 *     forge script script/DeployGMXAdapter.s.sol --rpc-url $ARBITRUM_GOERLI_RPC_URL --broadcast --verify
 *
 *   Arbitrum Mainnet (when ready):
 *     forge script script/DeployGMXAdapter.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
 */
contract DeployGMXAdapter is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy adapter
        GMXAdapterSimple adapter = new GMXAdapterSimple();

        console.log("=== GMXAdapterSimple Deployed ===");
        console.log("Address:", address(adapter));
        console.log("ExchangeRouter:", adapter.EXCHANGE_ROUTER());
        console.log("OrderVault:", adapter.ORDER_VAULT());
        console.log("\n=== Add to .env ===");
        console.log("GMX_ADAPTER_ADDRESS=%s", address(adapter));

        vm.stopBroadcast();
    }
}
