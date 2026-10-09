// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/IExternal.sol";

/// @notice Test-only ERC-20 (the project never deploys a real token).
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Takes a 1% fee on every transfer.
contract FeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Fee Token", "FOT", 6) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
        roundId++;
        answeredInRound = roundId;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function setRounds(uint80 r, uint80 air) external {
        roundId = r;
        answeredInRound = air;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @notice Simulates SwapRouter02.exactInput at a fixed price: out = in * num / den, minus `skimBps`.
contract MockSwapRouter {
    mapping(address => mapping(address => uint256)) public num;
    mapping(address => mapping(address => uint256)) public den;
    uint256 public skimBps;

    function setRate(address tokenIn, address tokenOut, uint256 n, uint256 d) external {
        num[tokenIn][tokenOut] = n;
        den[tokenIn][tokenOut] = d;
    }

    function setSkim(uint256 bps) external {
        skimBps = bps;
    }

    function exactInput(ISwapRouter02.ExactInputParams calldata p) external payable returns (uint256 out) {
        address tokenIn = address(bytes20(p.path[0:20]));
        address tokenOut = address(bytes20(p.path[p.path.length - 20:]));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = (p.amountIn * num[tokenIn][tokenOut]) / den[tokenIn][tokenOut];
        out = (out * (10_000 - skimBps)) / 10_000;
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(tokenOut).mint(p.recipient, out);
    }
}

/// @notice Converter that always reverts on deposit (to test the Payroll fallback path).
contract RevertingConverter {
    address public inputToken;

    constructor(address t) {
        inputToken = t;
    }

    function deposit(address, uint256) external pure {
        revert("nope");
    }
}
