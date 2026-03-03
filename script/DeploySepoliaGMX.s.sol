// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/adapters/GMXAdapterSepolia.sol";

/**
 * @title Deploy + Test GMXAdapterSepolia on Arbitrum Sepolia
 * @notice All-in-one: deploy adapter, mint test USDC, open position
 *
 * Prerequisites:
 *   1. DEPLOYER_PRIVATE_KEY in .env
 *   2. ~0.005 ETH on Arbitrum Sepolia (for gas + execution fee)
 *
 * Run:
 *   cd contracts
 *   source ../.env
 *   forge script script/DeploySepoliaGMX.s.sol \
 *     --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
 *     --broadcast \
 *     -vvvv
 */
contract DeploySepoliaGMX is Script {
    // GMX Sepolia testnet USDC Stargate (freely mintable, used by active market)
    address constant USDC = 0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773;

    // GMX ETH/USD market on Sepolia (WETH-USDC.SG variant — confirmed active)
    address constant ETH_USD_MARKET = 0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc;

    // Test parameters (micro amounts)
    uint256 constant MINT_AMOUNT = 1000e6;          // 1000 USDC
    uint256 constant COLLATERAL_AMOUNT = 100e6;      // $100 USDC collateral
    uint256 constant POSITION_SIZE = 500e30;          // $500 position (5x leverage)
    uint256 constant EXECUTION_FEE = 0.001 ether;    // Execution fee for keeper

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== GMX Sepolia Deployment & Test ===");
        console.log("Deployer:", deployer);
        console.log("ETH balance:", deployer.balance);

        require(deployer.balance > 0.003 ether, "Need at least 0.003 ETH for gas + execution fee");

        vm.startBroadcast(deployerPrivateKey);

        // ---- Step 1: Deploy adapter ----
        console.log("\n--- Step 1: Deploy GMXAdapterSepolia ---");
        GMXAdapterSepolia adapter = new GMXAdapterSepolia();
        console.log("Adapter deployed at:", address(adapter));

        // ---- Step 2: Mint test USDC ----
        console.log("\n--- Step 2: Mint test USDC ---");
        IMintableToken(USDC).mint(address(adapter), MINT_AMOUNT);
        uint256 adapterBalance = IERC20(USDC).balanceOf(address(adapter));
        console.log("Adapter USDC balance:", adapterBalance);

        // ---- Step 3: Open a market long position ----
        console.log("\n--- Step 3: Open market long ETH/USD ---");
        console.log("Collateral: 100 USDC");
        console.log("Position size: $500 (5x leverage)");
        console.log("Execution fee:", EXECUTION_FEE);

        bytes32 orderKey = adapter.openMarketLong{value: EXECUTION_FEE}(
            ETH_USD_MARKET,
            COLLATERAL_AMOUNT,
            USDC,
            POSITION_SIZE,
            type(uint256).max, // Accept any price (market order long)
            EXECUTION_FEE
        );

        console.log("\n=== ORDER CREATED ===");
        console.log("Order Key:");
        console.logBytes32(orderKey);
        console.log("\nAdapter address:", address(adapter));
        console.log("Remaining USDC in adapter:", IERC20(USDC).balanceOf(address(adapter)));

        console.log("\n=== NEXT STEPS ===");
        console.log("1. Check tx on https://sepolia.arbiscan.io");
        console.log("2. Wait for keeper execution (1-10 minutes)");
        console.log("3. Verify position on https://test.gmx-interface.pages.dev/");
        console.log("4. Run CloseSepoliaGMX.s.sol to close the position");

        vm.stopBroadcast();
    }
}

interface IMintableToken {
    function mint(address account, uint256 amount) external;
}
