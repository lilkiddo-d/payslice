// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable swap venue. Implementations MUST enforce `deadline` and `minOut`.
interface IDexAdapter {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amountOut);

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool);
}

/// @notice Swappable price source. Prices are USD with 18 decimals and are staleness/peg checked.
interface IOracleAdapter {
    function getPrice(address token) external view returns (uint256 price1e18);

    function hasFeed(address token) external view returns (bool);
}

/// @notice US equity market-hours gate.
interface IMarketClock {
    function isMarketOpen() external view returns (bool);
}

/// @notice Pluggable allowlist. When disabled every account is allowed.
interface IComplianceRegistry {
    function isAllowed(address account) external view returns (bool);
}

/// @notice Optional project-token features. Every function degrades to a no-op while the token is unset.
interface IProjectTokenHooks {
    function isActive() external view returns (bool);

    function feeDiscountBps(address account) external view returns (uint256);

    function isRewardToken(address token) external view returns (bool);

    function notifyReward(address token, uint256 amount) external;
}

interface IFeeCollector {
    enum FeeKind {
        Payroll,
        Conversion
    }

    function receiveFee(address token, uint256 amount, FeeKind kind) external;
}

interface ISliceRouter {
    function split(address worker, uint256 amount) external view returns (uint256 stablePart, uint256 slicePart);

    function allocationOf(address worker)
        external
        view
        returns (uint16 sliceBps, address[] memory assets, uint16[] memory weights);

    function autoHarvest(address worker) external view returns (bool);

    function isSupportedAsset(address asset) external view returns (bool);
}

interface IBatchConverter {
    function inputToken() external view returns (address);

    function deposit(address worker, uint256 amount) external;
}

interface IPayrollFactory {
    function paused() external view returns (bool);

    function effectiveFeeBps(address employer) external view returns (uint256);

    function feeCollector() external view returns (address);

    function sliceRouter() external view returns (ISliceRouter);

    function batchConverter() external view returns (IBatchConverter);

    function isAllowed(address account) external view returns (bool);

    function onStreamCreated(address worker) external;

    function onEmployerTransferred(address previousEmployer, address newEmployer) external;
}
