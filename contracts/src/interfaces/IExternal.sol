// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink AggregatorV3Interface (subset used by Payslice).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Uniswap SwapRouter02 (IV3SwapRouter) exact-input entry points. Note: SwapRouter02 has no
///         deadline field in its structs, so deadlines are enforced by the DexAdapter itself.
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice ERC-20 with metadata decimals.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
