// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Payroll} from "./Payroll.sol";
import {
    ISliceRouter,
    IBatchConverter,
    IComplianceRegistry,
    IProjectTokenHooks
} from "./interfaces/IPayslice.sol";

/// @title PayrollFactory
/// @notice Deploys employer Payrolls as EIP-1167 minimal proxies and holds protocol-wide configuration.
///         DEFAULT_ADMIN_ROLE is held by the 48h Timelock. GUARDIAN_ROLE can pause/unpause. A pause blocks new payrolls, deposits and stream changes, but never
///         worker withdrawals.
contract PayrollFactory is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 public constant MAX_FEE_BPS = 100; // 1%
    uint256 public constant BPS = 10_000;

    address public immutable implementation;

    address public feeCollector;
    ISliceRouter public sliceRouter;
    IBatchConverter public batchConverter;
    IComplianceRegistry public compliance;
    IProjectTokenHooks public projectHooks;
    uint256 public payrollFeeBps;

    mapping(address => bool) public isAllowedToken;
    mapping(address => bool) public isPayroll;
    address[] internal _payrolls;
    mapping(address => address[]) internal _payrollsOf;
    mapping(address => address[]) internal _workerPayrolls;
    mapping(address => mapping(address => bool)) internal _workerIndexed;

    event PayrollCreated(address indexed payroll, address indexed employer, address indexed token, string name);
    event TokenAllowed(address indexed token, bool allowed);
    event FeeCollectorSet(address indexed feeCollector);
    event SliceRouterSet(address indexed sliceRouter);
    event BatchConverterSet(address indexed batchConverter);
    event ComplianceSet(address indexed compliance);
    event ProjectHooksSet(address indexed hooks);
    event PayrollFeeSet(uint256 feeBps);
    event WorkerIndexed(address indexed worker, address indexed payroll);
    event EmployerIndexed(address indexed employer, address indexed payroll);

    error ZeroAddress();
    error TokenNotAllowed(address token);
    error FeeTooHigh();
    error NotPayroll();
    error NotAllowed(address account);

    constructor(address admin, address guardian, address feeCollector_, uint256 payrollFeeBps_) {
        if (admin == address(0) || guardian == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        if (payrollFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        implementation = address(new Payroll());
        feeCollector = feeCollector_;
        payrollFeeBps = payrollFeeBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        emit FeeCollectorSet(feeCollector_);
        emit PayrollFeeSet(payrollFeeBps_);
    }

    // ----------------------------------------------------------------------------------------------
    // Payroll creation
    // ----------------------------------------------------------------------------------------------

    function createPayroll(address token, string calldata name) external whenNotPaused returns (address payroll) {
        if (!isAllowedToken[token]) revert TokenNotAllowed(token);
        if (!isAllowed(msg.sender)) revert NotAllowed(msg.sender);
        payroll = Clones.clone(implementation);
        isPayroll[payroll] = true;
        _payrolls.push(payroll);
        _payrollsOf[msg.sender].push(payroll);
        emit PayrollCreated(payroll, msg.sender, token, name);
        Payroll(payroll).initialize(msg.sender, token, name);
    }

    // ----------------------------------------------------------------------------------------------
    // Hooks called by payrolls
    // ----------------------------------------------------------------------------------------------

    function onStreamCreated(address worker) external {
        if (!isPayroll[msg.sender]) revert NotPayroll();
        if (_workerIndexed[worker][msg.sender]) return;
        _workerIndexed[worker][msg.sender] = true;
        _workerPayrolls[worker].push(msg.sender);
        emit WorkerIndexed(worker, msg.sender);
    }

    function onEmployerTransferred(address, address newEmployer) external {
        if (!isPayroll[msg.sender]) revert NotPayroll();
        _payrollsOf[newEmployer].push(msg.sender);
        emit EmployerIndexed(newEmployer, msg.sender);
    }

    // ----------------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------------

    /// @notice Payroll fee after the employer's staking discount (0 discount while the project token is unset).
    function effectiveFeeBps(address employer) external view returns (uint256) {
        uint256 fee = payrollFeeBps;
        IProjectTokenHooks hooks = projectHooks;
        if (fee == 0 || address(hooks) == address(0)) return fee;
        try hooks.feeDiscountBps(employer) returns (uint256 discount) {
            if (discount >= BPS) return 0;
            return fee - (fee * discount) / BPS;
        } catch {
            return fee;
        }
    }

    function isAllowed(address account) public view returns (bool) {
        IComplianceRegistry c = compliance;
        if (address(c) == address(0)) return true;
        return c.isAllowed(account);
    }

    function payrollCount() external view returns (uint256) {
        return _payrolls.length;
    }

    /// @notice Paged list of all payrolls.
    function payrolls(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        return _page(_payrolls, offset, limit);
    }

    function payrollsOf(address employer) external view returns (address[] memory) {
        return _payrollsOf[employer];
    }

    function workerPayrolls(address worker) external view returns (address[] memory) {
        return _workerPayrolls[worker];
    }

    // ----------------------------------------------------------------------------------------------
    // Admin (Timelock) & guardian
    // ----------------------------------------------------------------------------------------------

    function setAllowedToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        isAllowedToken[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setFeeCollector(address collector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (collector == address(0)) revert ZeroAddress();
        feeCollector = collector;
        emit FeeCollectorSet(collector);
    }

    function setSliceRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sliceRouter = ISliceRouter(router);
        emit SliceRouterSet(router);
    }

    function setBatchConverter(address converter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        batchConverter = IBatchConverter(converter);
        emit BatchConverterSet(converter);
    }

    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ComplianceSet(registry);
    }

    function setProjectHooks(address hooks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        projectHooks = IProjectTokenHooks(hooks);
        emit ProjectHooksSet(hooks);
    }

    function setPayrollFeeBps(uint256 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        payrollFeeBps = feeBps;
        emit PayrollFeeSet(feeBps);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function _page(address[] storage arr, uint256 offset, uint256 limit) internal view returns (address[] memory out) {
        uint256 n = arr.length;
        if (offset >= n) return new address[](0);
        uint256 end = offset + limit > n ? n : offset + limit;
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = arr[i];
        }
    }
}
