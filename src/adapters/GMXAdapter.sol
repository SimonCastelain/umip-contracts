// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GMXAdapter
 * @notice GMX V2 integration adapter (Arbitrum Mainnet)
 * @dev Uses multicall pattern: ExchangeRouter.multicall([sendWnt(...), createOrder(...)])
 */
contract GMXAdapter {
    // ============================================
    // GMX V2 Contract Addresses (Arbitrum Mainnet)
    // ============================================
    address public constant EXCHANGE_ROUTER = 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8;
    address public constant ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;

    // ============================================
    // Errors
    // ============================================
    error InsufficientExecutionFee();
    error OrderCreationFailed();

    // ============================================
    // Events
    // ============================================
    event OrderCreated(bytes32 indexed orderKey, address indexed user, uint256 sizeDeltaUsd);

    /**
     * @notice Opens a market long position on GMX
     * @dev Uses the multicall pattern: sendWnt + createOrder
     * @param market GMX market address (e.g., ETH/USD market token)
     * @param collateralAmount Amount of collateral token to use
     * @param collateralToken Address of collateral token (WETH, USDC, etc.)
     * @param sizeDeltaUsd Position size in USD (30 decimals)
     * @param acceptablePrice Maximum acceptable execution price (30 decimals)
     * @param executionFee Fee for keeper execution (in ETH)
     * @return orderKey Unique identifier for the created order
     */
    function openMarketLong(
        address market,
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable returns (bytes32 orderKey) {
        // Validate execution fee
        if (msg.value < executionFee) revert InsufficientExecutionFee();

        IERC20(collateralToken).approve(EXCHANGE_ROUTER, collateralAmount);

        bytes[] memory multicallData = new bytes[](2);

        multicallData[0] = abi.encodeWithSignature(
            "sendTokens(address,address,uint256)",
            collateralToken,
            ORDER_VAULT,
            collateralAmount
        );

        IExchangeRouter.CreateOrderParams memory params = IExchangeRouter.CreateOrderParams({
            addresses: IExchangeRouter.CreateOrderParamsAddresses({
                receiver: msg.sender,
                cancellationReceiver: msg.sender,
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: market,
                initialCollateralToken: collateralToken,
                swapPath: new address[](0)
            }),
            numbers: IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaUsd,
                initialCollateralDeltaAmount: 0, // 0 when using sendWnt/sendTokens
                triggerPrice: 0, // 0 for market orders
                acceptablePrice: acceptablePrice,
                executionFee: executionFee,
                callbackGasLimit: 200000,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: IExchangeRouter.OrderType.MarketIncrease,
            decreasePositionSwapType: IExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong: true,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        // Encode createOrder call
        multicallData[1] = abi.encodeWithSignature(
            "createOrder((address,address,address,address,address,address,address[]),(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),uint8,uint8,bool,bool,bytes32)",
            params.addresses,
            params.numbers,
            params.orderType,
            params.decreasePositionSwapType,
            params.isLong,
            params.shouldUnwrapNativeToken,
            params.referralCode
        );

        // Execute multicall
        bytes[] memory results = IExchangeRouter(EXCHANGE_ROUTER).multicall{value: msg.value}(multicallData);

        // Decode orderKey from createOrder result
        if (results.length < 2 || results[1].length == 0) revert OrderCreationFailed();
        orderKey = abi.decode(results[1], (bytes32));

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd);
    }

    /**
     * @notice Closes a market long position on GMX
     * @dev Uses the same multicall pattern with MarketDecrease order type
     * @param market GMX market address
     * @param collateralToken Address of collateral token
     * @param sizeDeltaUsd Position size to close in USD (30 decimals)
     * @param acceptablePrice Minimum acceptable execution price (30 decimals)
     * @param executionFee Fee for keeper execution (in ETH)
     * @return orderKey Unique identifier for the created order
     */
    function closeMarketLong(
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable returns (bytes32 orderKey) {
        if (msg.value < executionFee) revert InsufficientExecutionFee();

        // For closing, we only need to createOrder (no collateral transfer)
        IExchangeRouter.CreateOrderParams memory params = IExchangeRouter.CreateOrderParams({
            addresses: IExchangeRouter.CreateOrderParamsAddresses({
                receiver: msg.sender,
                cancellationReceiver: msg.sender,
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: market,
                initialCollateralToken: collateralToken,
                swapPath: new address[](0)
            }),
            numbers: IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaUsd,
                initialCollateralDeltaAmount: 0,
                triggerPrice: 0,
                acceptablePrice: acceptablePrice,
                executionFee: executionFee,
                callbackGasLimit: 200000,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: IExchangeRouter.OrderType.MarketDecrease,
            decreasePositionSwapType: IExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong: true,
            shouldUnwrapNativeToken: false,
            referralCode: bytes32(0)
        });

        // Call createOrder directly (no multicall needed for decrease)
        orderKey = IExchangeRouter(EXCHANGE_ROUTER).createOrder{value: msg.value}(params);

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd);
    }

    /**
     * @notice Helper to approve tokens for GMX Router
     * @param token Token address to approve
     * @param amount Amount to approve
     */
    function approveToken(address token, uint256 amount) external {
        IERC20(token).approve(EXCHANGE_ROUTER, amount);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}

// ============================================
// Interface Definitions
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
        address cancellationReceiver;
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
        uint256 validFromTime;
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
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}
