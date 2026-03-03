// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GMXAdapterSimple
 * @notice GMX V2.2+ adapter for Arbitrum Mainnet
 * @dev Validated on Arbitrum Sepolia (Feb 2026) — see umip_week5_gmx_validation.md
 *
 * Execution Pattern (proven on-chain):
 *   1. Transfer collateral directly to OrderVault via ERC20.transfer()
 *   2. multicall([sendWnt(OrderVault, fee), createOrder(params)])
 *
 * Why multicall + sendWnt instead of createOrder{value: fee}:
 *   GMX V2 requires execution fees deposited as WETH to OrderVault.
 *   sendWnt wraps ETH→WETH and transfers to the vault.
 *   Direct msg.value on createOrder is silently ignored → "revert at 850 gas".
 *
 * Why direct transfer instead of Router.sendTokens:
 *   sendTokens requires ROUTER_PLUGIN approval on the ExchangeRouter.
 *   Direct ERC20 transfer to OrderVault bypasses this permission entirely.
 *
 * V2.2+ Interface Changes (breaking):
 *   CreateOrderParams gained `bool autoCancel` and `bytes32[] dataList`.
 *   This changes the function selector. Old V2 selector won't match deployed contracts.
 *
 * Market Address Discovery:
 *   Markets are registered in GMX's DataStore. Not all markets are active on all networks.
 *   On mainnet, ETH/USD = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336
 *   On Sepolia, ETH/USD (WETH-USDC.SG) = 0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc
 *   Always verify market exists via DataStore before using. Use a real successful tx as reference.
 */
contract GMXAdapterSimple is IAdapter {
    // ============================================
    // GMX V2 Contract Addresses (Arbitrum Mainnet)
    // ============================================
    address public constant EXCHANGE_ROUTER = 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8;
    address public constant ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;

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

        // Step 1: Transfer collateral directly to OrderVault (bypasses ROUTER_PLUGIN)
        bool success = IERC20(collateralToken).transfer(ORDER_VAULT, collateralAmount);
        if (!success) revert TokenTransferFailed();

        // Step 2: multicall(sendWnt + createOrder)
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

        // No collateral transfer for close — collateral is in the position
        IGMXExchangeRouter.CreateOrderParams memory params = _buildOrderParams(
            msg.sender,
            market,
            collateralToken,
            sizeDeltaUsd,
            0, // no collateral delta for close
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

    /**
     * @dev Wraps execution fee via sendWnt and creates order in a single multicall.
     *      This is the only correct way to create GMX V2 orders — direct msg.value fails.
     */
    function _multicallCreateOrder(
        IGMXExchangeRouter.CreateOrderParams memory params,
        uint256 executionFee
    ) internal returns (bytes32 orderKey) {
        bytes[] memory multicallData = new bytes[](2);

        // Call 1: sendWnt — wraps ETH → WETH and sends to OrderVault
        multicallData[0] = abi.encodeWithSelector(
            IGMXExchangeRouter.sendWnt.selector,
            ORDER_VAULT,
            executionFee
        );

        // Call 2: createOrder — uses V2.2+ params (autoCancel, dataList)
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

    // Allow contract to receive ETH
    receive() external payable {}
}

// ============================================
// GMX V2.2+ Interface (matches deployed contracts Feb 2026)
// Validated against Arbitrum Sepolia ExchangeRouter
// Function selector for createOrder: 0xf59c48eb
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

    // V2.2+ struct — includes autoCancel and dataList (changes function selector)
    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers numbers;
        OrderType orderType;
        DecreasePositionSwapType decreasePositionSwapType;
        bool isLong;
        bool shouldUnwrapNativeToken;
        bool autoCancel;          // Added in V2.2+
        bytes32 referralCode;
        bytes32[] dataList;       // Added in V2.2+
    }

    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
    function sendWnt(address receiver, uint256 amount) external payable;
    function sendTokens(address token, address receiver, uint256 amount) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
