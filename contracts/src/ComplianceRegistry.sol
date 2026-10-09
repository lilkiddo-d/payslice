// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IComplianceRegistry} from "./interfaces/IPayslice.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook, OFF by default (every account allowed).
///         When enabled it gates *entry* actions: creating a payroll, opening a stream to a worker, setting
///         a stock slice, depositing into conversion batches and granting bonuses.
///         It deliberately never gates withdrawals of already-earned pay, so it can't be used to claw back
///         wages by freezing a worker.
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address => bool) public allowlisted;

    event EnabledSet(bool enabled);
    event AllowlistSet(address indexed account, bool allowed);

    error BatchTooLarge();
    error ZeroAddress();

    constructor(address admin, address complianceOperator) {
        if (admin == address(0) || complianceOperator == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, complianceOperator);
    }

    function isAllowed(address account) external view returns (bool) {
        return !enabled || allowlisted[account];
    }

    function setEnabled(bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = on;
        emit EnabledSet(on);
    }

    function setAllowlist(address[] calldata accounts, bool allowed) external onlyRole(COMPLIANCE_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowlisted[accounts[i]] = allowed;
            emit AllowlistSet(accounts[i], allowed);
        }
    }
}
