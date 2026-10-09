// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISliceRouter, IComplianceRegistry} from "./interfaces/IPayslice.sol";

/// @title BonusVesting
/// @notice Equity-style stock-token bonuses: an employer escrows stock tokens for a worker that vest
///         linearly after a cliff. Revocable grants return only the *unvested* part to the employer;
///         anything vested stays claimable by the worker forever. Claims are never paused.
contract BonusVesting is AccessControl, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint64 public constant MAX_DURATION = 10 * 365 days;

    struct Grant {
        address employer;
        address worker;
        address token;
        bool revocable;
        uint64 start;
        uint64 cliff; // absolute timestamp; nothing vests before it
        uint64 duration; // linear vesting from start over duration
        uint64 revokedAt; // 0 = not revoked
        uint256 total;
        uint256 claimed;
    }

    ISliceRouter public sliceRouter;
    IComplianceRegistry public compliance;

    uint256 public grantCount;
    mapping(uint256 => Grant) internal _grants;
    mapping(address => uint256[]) internal _grantsOfWorker;
    mapping(address => uint256[]) internal _grantsOfEmployer;

    event GrantCreated(
        uint256 indexed grantId,
        address indexed employer,
        address indexed worker,
        address token,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    );
    event BonusClaimed(uint256 indexed grantId, address indexed worker, uint256 amount);
    event GrantRevoked(uint256 indexed grantId, uint256 vested, uint256 returned);
    event ConfigSet(bytes32 indexed key, address value);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSchedule();
    error UnsupportedAsset(address token);
    error NotWorker();
    error NotEmployer();
    error NotRevocable();
    error AlreadyRevoked();
    error NothingToClaim();
    error UnknownGrant();
    error NotAllowed(address account);

    constructor(address admin, address guardian, address sliceRouter_) {
        if (admin == address(0) || guardian == address(0) || sliceRouter_ == address(0)) revert ZeroAddress();
        sliceRouter = ISliceRouter(sliceRouter_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    /// @param cliffDuration seconds after start before anything vests (<= duration)
    /// @param duration total linear vesting duration in seconds
    function grant(
        address worker,
        address token,
        uint256 amount,
        uint64 start,
        uint64 cliffDuration,
        uint64 duration,
        bool revocable
    ) external nonReentrant whenNotPaused returns (uint256 grantId) {
        if (worker == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!sliceRouter.isSupportedAsset(token)) revert UnsupportedAsset(token);
        if (duration == 0 || duration > MAX_DURATION || cliffDuration > duration) revert InvalidSchedule();
        if (start == 0) start = uint64(block.timestamp);
        if (start + 365 days < block.timestamp) revert InvalidSchedule();
        IComplianceRegistry c = compliance;
        if (address(c) != address(0)) {
            if (!c.isAllowed(msg.sender)) revert NotAllowed(msg.sender);
            if (!c.isAllowed(worker)) revert NotAllowed(worker);
        }

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;

        grantId = ++grantCount;
        _grants[grantId] = Grant({
            employer: msg.sender,
            worker: worker,
            token: token,
            revocable: revocable,
            start: start,
            cliff: start + cliffDuration,
            duration: duration,
            revokedAt: 0,
            total: received,
            claimed: 0
        });
        _grantsOfWorker[worker].push(grantId);
        _grantsOfEmployer[msg.sender].push(grantId);
        emit GrantCreated(grantId, msg.sender, worker, token, received, start, start + cliffDuration, duration, revocable);
    }

    function claim(uint256 grantId) external nonReentrant returns (uint256 amount) {
        Grant storage g = _get(grantId);
        if (msg.sender != g.worker) revert NotWorker();
        amount = vested(grantId) - g.claimed;
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert NothingToClaim();
        g.claimed += amount;
        emit BonusClaimed(grantId, g.worker, amount);
        IERC20(g.token).safeTransfer(g.worker, amount);
    }

    /// @notice Return the unvested remainder to the employer. Vested tokens remain the worker's.
    function revoke(uint256 grantId) external nonReentrant {
        Grant storage g = _get(grantId);
        if (msg.sender != g.employer) revert NotEmployer();
        if (!g.revocable) revert NotRevocable();
        if (g.revokedAt != 0) revert AlreadyRevoked();
        uint256 v = vested(grantId);
        uint256 returned = g.total - v;
        g.revokedAt = uint64(block.timestamp);
        g.total = v;
        emit GrantRevoked(grantId, v, returned);
        if (returned != 0) IERC20(g.token).safeTransfer(g.employer, returned);
    }

    function vested(uint256 grantId) public view returns (uint256) {
        Grant storage g = _grants[grantId];
        if (g.revokedAt != 0) return g.total; // frozen at revocation
        return _vestedAt(g, block.timestamp);
    }

    function claimableOf(uint256 grantId) external view returns (uint256) {
        return vested(grantId) - _grants[grantId].claimed;
    }

    function getGrant(uint256 grantId) external view returns (Grant memory) {
        return _grants[grantId];
    }

    function grantsOfWorker(address worker) external view returns (uint256[] memory) {
        return _grantsOfWorker[worker];
    }

    function grantsOfEmployer(address employer) external view returns (uint256[] memory) {
        return _grantsOfEmployer[employer];
    }

    function _vestedAt(Grant storage g, uint256 t) internal view returns (uint256) {
        if (t < g.cliff) return 0;
        uint256 end = uint256(g.start) + g.duration;
        if (t >= end) return g.total;
        return (g.total * (t - g.start)) / g.duration;
    }

    function _get(uint256 grantId) internal view returns (Grant storage g) {
        g = _grants[grantId];
        if (g.worker == address(0)) revert UnknownGrant();
    }

    // ----------------------------------------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------------------------------------

    function setSliceRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddress();
        sliceRouter = ISliceRouter(router);
        emit ConfigSet("sliceRouter", router);
    }

    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ConfigSet("compliance", registry);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
