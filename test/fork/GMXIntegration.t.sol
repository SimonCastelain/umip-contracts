// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title GMXIntegration Fork Test
 * @notice UMIP Week 1: Testing GMX adapter viability
 * @dev These tests validate that a smart contract (future UMIPVault) can open/close GMX positions
 *
 * Key Questions:
 * 1. Can our vault contract create GMX orders?
 * 2. What's the simplest working integration pattern?
 * 3. Can we query positions after creation?
 *
 * Run with: forge test --fork-url https://arb1.arbitrum.io/rpc --match-contract GMXIntegration -vvv
 */
contract GMXIntegrationTest is Test {
    // ============================================
    // GMX V2 Contract Addresses (Arbitrum Mainnet) - Updated 2026
    // ============================================
    address constant GMX_EXCHANGE_ROUTER = 0x602b805EedddBbD9ddff44A7dcBD46cb07849685;
    address constant GMX_ROUTER = 0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6;
    address constant GMX_READER = 0xf60becbba223EEA9495Da3f606753867eC10d139;
    address constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant GMX_ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;

    // Token Addresses
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    // GMX Market Addresses
    address constant ETH_USD_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336; // ETH/USD market

    // Test accounts
    address trader;
    uint256 traderKey;

    // Test amounts
    uint256 constant INITIAL_ETH = 10 ether;
    uint256 constant INITIAL_USDC = 50000e6; // 50k USDC

    function setUp() public {
        // Create a test trader account
        (trader, traderKey) = makeAddrAndKey("trader");

        // Fund trader with ETH and tokens
        vm.deal(trader, INITIAL_ETH);

        // Give trader some WETH and USDC
        deal(WETH, trader, 5 ether);
        deal(USDC, trader, INITIAL_USDC);

        console.log("=== GMX V2 UMIP Adapter Test ===");
        console.log("Trader:", trader);
        console.log("WETH balance:", IERC20(WETH).balanceOf(trader));
        console.log("USDC balance:", IERC20(USDC).balanceOf(trader));
    }

    /**
     * @notice Test 1: Simple order creation - Direct transfer method
     * @dev UMIP Goal: Prove a vault contract can open positions
     */
    function test_SimpleOrderCreation() public {
        console.log("\n=== Test 1: Simple GMX Order Creation ===");

        IExchangeRouter router = IExchangeRouter(GMX_EXCHANGE_ROUTER);

        vm.startPrank(trader);

        uint256 collateralAmount = 100e6; // 100 USDC
        uint256 executionFee = 0.0001 ether;

        // Step 1: Transfer collateral directly to OrderVault
        // This is GMX V2's required pattern: collateral must be in vault before createOrder
        console.log("Step 1: Transferring collateral to OrderVault...");
        IERC20(USDC).transfer(GMX_ORDER_VAULT, collateralAmount);
        console.log("Transferred", collateralAmount, "USDC to OrderVault");

        // Step 2: Build createOrder params
        console.log("Step 2: Building createOrder params...");
        IExchangeRouter.CreateOrderParams memory params = IExchangeRouter.CreateOrderParams({
            addresses: IExchangeRouter.CreateOrderParamsAddresses({
                receiver: trader,
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: ETH_USD_MARKET,
                initialCollateralToken: USDC,
                swapPath: new address[](0)
            }),
            numbers: IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: 1000e30, // $1000 position size
                initialCollateralDeltaAmount: collateralAmount,
                triggerPrice: 0, // 0 for market orders
                acceptablePrice: type(uint256).max, // Accept any price (market order)
                executionFee: executionFee,
                callbackGasLimit: 0,
                minOutputAmount: 0
            }),
            orderType: IExchangeRouter.OrderType.MarketIncrease,
            decreasePositionSwapType: IExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong: true,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        // Step 3: Create order
        console.log("Step 3: Calling createOrder...");
        bytes32 orderKey = router.createOrder{value: executionFee}(params);

        console.log("Order created successfully!");
        console.log("Order Key:");
        console.logBytes32(orderKey);

        vm.stopPrank();
    }
}

// ============================================
// Minimal Interface Definitions
// ============================================

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IExchangeRouter {
    enum OrderType {
        MarketSwap,
        LimitSwap,
        MarketIncrease,
        LimitIncrease,
        MarketDecrease,
        LimitDecrease,
        StopLossDecrease,
        Liquidation
    }

    enum DecreasePositionSwapType {
        NoSwap,
        SwapPnlTokenToCollateralToken,
        SwapCollateralTokenToPnlToken
    }

    struct CreateOrderParamsAddresses {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialCollateralToken;
        address[] swapPath;
    }

    struct CreateOrderParamsNumbers {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
    }

    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers numbers;
        OrderType orderType;
        DecreasePositionSwapType decreasePositionSwapType;
        bool isLong;
        bool shouldUnwrapNativeToken;
        bytes32 referralCode;
    }

    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
}
