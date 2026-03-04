// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GMXAdapterSepolia
 * @notice GMX V2 adapter for Arbitrum Sepolia testnet
 * @dev Implements IAdapter for vault integration
 *
 * Pattern: multicall([sendWnt(OrderVault, fee), createOrder(params)])
 * Collateral transferred directly to OrderVault via ERC20 transfer (bypasses ROUTER_PLUGIN).
 * Execution fee sent via sendWnt which wraps ETH and deposits to OrderVault.
 *
 * Interface matches GMX V2.2+ with autoCancel and dataList fields.
 */
contract GMXAdapterSepolia is IAdapter {
    // ============================================
    // GMX V2 Contract Addresses (Arbitrum Sepolia)
    // ============================================
    address public constant EXCHANGE_ROUTER = 0xEd50B2A1eF0C35DAaF08Da6486971180237909c3;
    address public constant ORDER_VAULT = 0x1b8AC606de71686fd2a1AEDEcb6E0EFba28909a2;
    address public constant ROUTER = 0x72F13a44C8ba16a678CAD549F17bc9e06d2B8bD2;

    // Testnet token addresses
    address public constant USDC = 0x3321Fd36aEaB0d5CdfD26f4A3A93E2D2aAcCB99f;
    address public constant WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;

    // Market addresses
    address public constant ETH_USD_MARKET = 0x482Df3D320C964808579b585a8AC7Dd5D144eFaF;

    // ============================================
    // Errors
    // ============================================
    error InsufficientExecutionFee();
    error TokenTransferFailed();

    // ============================================
    // Events
    // ============================================
    event OrderCreated(bytes32 indexed orderKey, address indexed user, uint256 sizeDeltaUsd, bool isIncrease);

    // ============================================
    // IAdapter Implementation
    // ============================================

    function openMarketLong(
        address market,
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        if (msg.value < executionFee) revert InsufficientExecutionFee();

        bool success = IERC20(collateralToken).transfer(ORDER_VAULT, collateralAmount);
        if (!success) revert TokenTransferFailed();

        IGMXExchangeRouter.CreateOrderParams memory params = _buildOrderParams(
            msg.sender,
            market,
            collateralToken,
            sizeDeltaUsd,
            collateralAmount,
            acceptablePrice,
            executionFee,
            IGMXExchangeRouter.OrderType.MarketIncrease
        );

        orderKey = _multicallCreateOrder(params, executionFee);

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd, true);
    }

    function closeMarketLong(
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable override returns (bytes32 orderKey) {
        if (msg.value < executionFee) revert InsufficientExecutionFee();

        IGMXExchangeRouter.CreateOrderParams memory params = _buildOrderParams(
            msg.sender,
            market,
            collateralToken,
            sizeDeltaUsd,
            0,
            acceptablePrice,
            executionFee,
            IGMXExchangeRouter.OrderType.MarketDecrease
        );

        orderKey = _multicallCreateOrder(params, executionFee);

        emit OrderCreated(orderKey, msg.sender, sizeDeltaUsd, false);
    }

    // ============================================
    // Internal
    // ============================================

    function _multicallCreateOrder(
        IGMXExchangeRouter.CreateOrderParams memory params,
        uint256 executionFee
    ) internal returns (bytes32 orderKey) {
        bytes[] memory multicallData = new bytes[](2);

        multicallData[0] = abi.encodeWithSelector(
            IGMXExchangeRouter.sendWnt.selector,
            ORDER_VAULT,
            executionFee
        );

        multicallData[1] = abi.encodeWithSelector(
            IGMXExchangeRouter.createOrder.selector,
            params
        );

        bytes[] memory results = IGMXExchangeRouter(EXCHANGE_ROUTER).multicall{value: msg.value}(multicallData);

        orderKey = abi.decode(results[1], (bytes32));
    }

    function _buildOrderParams(
        address account,
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 collateralDeltaAmount,
        uint256 acceptablePrice,
        uint256 executionFee,
        IGMXExchangeRouter.OrderType orderType
    ) internal pure returns (IGMXExchangeRouter.CreateOrderParams memory) {
        return IGMXExchangeRouter.CreateOrderParams({
            addresses: IGMXExchangeRouter.CreateOrderParamsAddresses({
                receiver: account,
                cancellationReceiver: account,
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: market,
                initialCollateralToken: collateralToken,
                swapPath: new address[](0)
            }),
            numbers: IGMXExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaUsd,
                initialCollateralDeltaAmount: collateralDeltaAmount,
                triggerPrice: 0,
                acceptablePrice: acceptablePrice,
                executionFee: executionFee,
                callbackGasLimit: 200000,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: orderType,
            decreasePositionSwapType: IGMXExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong: true,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
    }

    receive() external payable {}
}

// ============================================
// GMX V2.2+ Interface
// ============================================

interface IGMXExchangeRouter {
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
        bool autoCancel;
        bytes32 referralCode;
        bytes32[] dataList;
    }

    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
    function sendWnt(address receiver, uint256 amount) external payable;
    function sendTokens(address token, address receiver, uint256 amount) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
