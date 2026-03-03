// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/UMIPVault.sol";

/**
 * @title Deploy Agent V2 (With UMIP) — UMIPVault on Arbitrum Sepolia
 *
 * Deploys UMIPVault wired to the existing GMXAdapterSepolia.
 * Mints SG_USDC directly to the vault (vault acts as its own depositor for demo).
 *
 * Prerequisites:
 *   1. DEPLOYER_PRIVATE_KEY in .env
 *   2. GMXAdapterSepolia already deployed at GMX_ADAPTER below
 *
 * Run:
 *   cd contracts
 *   source ../.env
 *   forge script script/DeployV2.s.sol \
 *     --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
 *     --broadcast -vvvv
 */
contract DeployV2 is Script {
    // ─── Sepolia Addresses ───────────────────────────────────────────────────
    address constant SG_USDC       = 0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773;
    address constant GMX_ADAPTER   = 0x148B975C477bdf6196670Fa09F9AA12C86F1Fe00;
    address constant ETH_USD_MARKET = 0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc; // WETH-USDC.SG

    // ─── Demo Parameters ─────────────────────────────────────────────────────
    uint256 constant MINT_AMOUNT   = 1000e6;   // 1000 SG_USDC for the demo

    function run() external {
        address deployer = msg.sender;

        console.log("=== Agent V2 (With UMIP) Deployment ===");
        console.log("Deployer:", deployer);
        console.log("ETH balance:", deployer.balance);

        vm.startBroadcast();

        // ── Step 1: Deploy UMIPVault ──────────────────────────────────────────
        console.log("\n--- Step 1: Deploy UMIPVault(SG_USDC) ---");
        UMIPVault vault = new UMIPVault(SG_USDC);
        console.log("UMIPVault deployed at:", address(vault));

        // ── Step 2: Set GMX adapter ───────────────────────────────────────────
        console.log("\n--- Step 2: setAdapters(GMX_ADAPTER) ---");
        vault.setAdapters(GMX_ADAPTER, address(0), address(0));
        console.log("GMX adapter configured:", GMX_ADAPTER);

        // ── Step 3: Configure GMX market ─────────────────────────────────────
        console.log("\n--- Step 3: setMarket(GMX, ETH_USD_MARKET) ---");
        vault.setMarket(UMIPVault.Platform.GMX, ETH_USD_MARKET);
        console.log("GMX default market:", ETH_USD_MARKET);

        // ── Step 4: Mint SG_USDC to deployer, then deposit into vault ─────────
        console.log("\n--- Step 4: Mint SG_USDC and deposit into vault ---");
        IMintableToken(SG_USDC).mint(deployer, MINT_AMOUNT);
        console.log("Minted", MINT_AMOUNT / 1e6, "SG_USDC to deployer");

        IERC20(SG_USDC).approve(address(vault), MINT_AMOUNT);
        vault.deposit(MINT_AMOUNT);
        console.log("Deposited", MINT_AMOUNT / 1e6, "SG_USDC into vault");

        // ── Verify state ──────────────────────────────────────────────────────
        (uint256 idle,,,, uint256 total) = vault.getUserCollateral(deployer);
        console.log("\n=== VAULT STATE ===");
        console.log("Deployer idle collateral:", idle / 1e6, "USDC");
        console.log("Deployer total deposited:", total / 1e6, "USDC");
        console.log("Vault USDC balance:", IERC20(SG_USDC).balanceOf(address(vault)) / 1e6);

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("UMIPVault address:", address(vault));
        console.log("Update agents/v2_with_umip/config.py with:");
        console.log("  UMIP_VAULT_SEP =", address(vault));

        vm.stopBroadcast();
    }
}

interface IMintableToken {
    function mint(address account, uint256 amount) external;
}
