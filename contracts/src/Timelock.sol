// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Timelock
/// @notice Holds DEFAULT_ADMIN_ROLE on every Payslice contract. Every admin change waits at least 48 hours.
contract Timelock is TimelockController {
    uint256 public constant MIN_DELAY = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY) revert DelayTooShort();
    }
}
