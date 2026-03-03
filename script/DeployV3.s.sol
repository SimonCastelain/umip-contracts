// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/UMIPVault.sol";

/**
 * @title Deploy UMIP Vault V3 — Public Demo with Circle USDC (Arbitrum Sepolia)
 *
 * Uses Circle's official Arbitrum Sepolia USDC so anyone can get testnet tokens
 * via https://faucet.circle.com/
 *
 * Prerequisites:
 *   1. DEPLOYER_PRIVATE_KEY in .env
 *   2. ~0.02 ETH on Arbitrum Sepolia (for gas)
 *   3. GMXAdapterSepolia already deployed at GMX_ADAPTER_SEP
 *
 * Run:
 *   cd contracts
 *   source ../.env
 *   forge script script/DeployV3.s.sol \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
 *     --broadcast -vvvv
 *
 * After deployment:
 *   1. Update UMIP_VAULT_SEP in agents/v2_with_umip/config.py with new vault address
 *   2. Update NEXT_PUBLIC_VAULT_ADDRESS in umip-sandbox/.env.local
 *   3. Users get Circle USDC at: https://faucet.circle.com/
 */
contract DeployV3 is Script {
    // Circle's official USDC on Arbitrum Sepolia (public faucet: https://faucet.circle.com/)
    address constant CIRCLE_USDC    = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    // Existing GMXAdapterSepolia — collateralToken is passed as param so no redeploy needed
    address constant GMX_ADAPTER    = 0x148B975C477bdf6196670Fa09F9AA12C86F1Fe00;

    // ETH/USD market on Arbitrum Sepolia GMX (WETH-USDC.SG market — used for position routing)
    address constant ETH_USD_MARKET = 0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc;

    function run() external {
        address deployer = msg.sender;

        console.log("=== UMIP Vault V3 Deployment (Circle USDC) ===");
        console.log("Deployer:     ", deployer);
        console.log("Circle USDC:  ", CIRCLE_USDC);
        console.log("GMX Adapter:  ", GMX_ADAPTER);
        console.log("ETH balance:  ", deployer.balance / 1e15, "mETH");

        vm.startBroadcast();

        // Step 1: Deploy UMIPVault with Circle USDC as collateral token
        UMIPVault vault = new UMIPVault(CIRCLE_USDC);
        console.log("\nUMIPVault deployed at:", address(vault));

        // Step 2: Wire GMX adapter
        vault.setAdapters(GMX_ADAPTER, address(0), address(0));
        console.log("GMX adapter set.");

        // Step 3: Set default ETH/USD market
        vault.setMarket(UMIPVault.Platform.GMX, ETH_USD_MARKET);
        console.log("Default GMX market set.");

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("New vault address:", address(vault));
        console.log("\nNext steps:");
        console.log("  1. Get Circle USDC at: https://faucet.circle.com/");
        console.log("  2. Update UMIP_VAULT_SEP in agents/v2_with_umip/config.py");
        console.log("  3. Set NEXT_PUBLIC_VAULT_ADDRESS in umip-sandbox/.env.local");
    }
}
