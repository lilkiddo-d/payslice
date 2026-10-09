// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDexAdapter} from "../interfaces/IPayslice.sol";
import {ISwapRouter02} from "../interfaces/IExternal.sol";

/// @title DexAdapter (Uniswap v3 via SwapRouter02)
/// @notice Swappable swap venue used by BatchConverter. Routes are Uniswap v3 encoded paths
///         (tokenIn | fee | [token | fee]* | tokenOut) set by the Timelock per pair.
///         Enforces deadline and minOut itself (SwapRouter02 structs carry no deadline) and holds no funds
///         between calls. Replace with another IDexAdapter (RFQ, v4, Rialto...) without touching other contracts.
contract DexAdapter is IDexAdapter, AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;

    mapping(address => mapping(address => bytes)) internal _paths;

    event RouteSet(address indexed tokenIn, address indexed tokenOut, bytes path);
    event Swapped(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address recipient
    );

    error ZeroAddress();
    error Expired();
    error NoRoute();
    error BadPath();
    error SlippageExceeded();

    constructor(address admin, address router_) {
        if (admin == address(0) || router_ == address(0)) revert ZeroAddress();
        router = ISwapRouter02(router_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (recipient == address(0)) revert ZeroAddress();
        bytes memory path = _paths[tokenIn][tokenOut];
        if (path.length == 0) revert NoRoute();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Balance-diff check around the Timelock-configured router; guarded by nonReentrant.
        // slither-disable-next-line reentrancy-balance
        uint256 balBefore = IERC20(tokenOut).balanceOf(recipient);
        uint256 routerOut = router.exactInput(
            ISwapRouter02.ExactInputParams({
                path: path, recipient: recipient, amountIn: amountIn, amountOutMinimum: minOut
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        amountOut = IERC20(tokenOut).balanceOf(recipient) - balBefore;
        if (amountOut < minOut || routerOut < minOut) revert SlippageExceeded();
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool) {
        return _paths[tokenIn][tokenOut].length != 0;
    }

    function pathOf(address tokenIn, address tokenOut) external view returns (bytes memory) {
        return _paths[tokenIn][tokenOut];
    }

    /// @notice Set (or clear with empty bytes) the v3 path for a pair.
    function setRoute(address tokenIn, address tokenOut, bytes calldata path) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (path.length != 0) {
            // 20 bytes token + n * (3 bytes fee + 20 bytes token)
            if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadPath();
            if (address(bytes20(path[0:20])) != tokenIn) revert BadPath();
            if (address(bytes20(path[path.length - 20:])) != tokenOut) revert BadPath();
        }
        _paths[tokenIn][tokenOut] = path;
        emit RouteSet(tokenIn, tokenOut, path);
    }
}
