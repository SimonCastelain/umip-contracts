// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAdapter
 * @notice Common interface for perpetual protocol adapters (GMX, Vertex)
 * @dev All adapters must implement this interface for vault integration
 *
 * Design Notes:
 * - openMarketLong: adapter expects to receive collateral tokens BEFORE this call
 * - closeMarketLong: no positionKey needed - GMX identifies positions by account+market+collateral+isLong
 * - Execution fees sent as msg.value
 */
interface IAdapter {
    /**
     * @notice Opens a market long position
     * @dev Caller MUST transfer collateral tokens to adapter before calling
     * @param market Protocol market address (GMX market token, Vertex productId converted)
     * @param collateralAmount Amount of collateral to use
     * @param collateralToken Address of collateral token (USDC, WETH, etc.)
     * @param sizeDeltaUsd Position size in USD (30 decimals for GMX)
     * @param acceptablePrice Maximum acceptable price (30 decimals)
     * @param executionFee Fee for keeper/sequencer execution
     * @return orderKey Unique identifier for tracking the order
     */
    function openMarketLong(
        address market,
        uint256 collateralAmount,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable returns (bytes32 orderKey);

    /**
     * @notice Closes a market long position
     * @dev Position identified by msg.sender + market + collateralToken + isLong
     * @param market Protocol market address
     * @param collateralToken Address of collateral token
     * @param sizeDeltaUsd Position size to close in USD (30 decimals)
     * @param acceptablePrice Minimum acceptable price (30 decimals)
     * @param executionFee Fee for keeper/sequencer execution
     * @return orderKey Unique identifier for tracking the order
     */
    function closeMarketLong(
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee
    ) external payable returns (bytes32 orderKey);
}
