// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IProjectTokenHooks} from "./interfaces/IPayslice.sol";

/// @title ProjectTokenHooks
/// @notice Optional $SLCE features. Payslice does NOT deploy a token: the address is supplied once, later,
///         via `setProjectToken` (Timelock only). Until then every feature is disabled:
///         `isActive() == false`, `feeDiscountBps() == 0`, staking reverts, and FeeCollector sends 100% of
///         fees to the treasury.
///
///         Once set:
///          - Staking: stake $SLCE; unstake after `lockPeriod` since your last stake (blocks flash-staking).
///          - Fee discount: employers whose stake meets a tier get a discount on payroll deposit fees.
///          - Fee sharing: a share of conversion fees is distributed pro-rata to stakers (accumulator model,
///            O(#reward tokens) per action, max 4 reward tokens).
contract ProjectTokenHooks is IProjectTokenHooks, AccessControl, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant ACC = 1e36; // high precision: 6-dec rewards vs 18-dec stake
    uint256 public constant MAX_REWARD_TOKENS = 4;
    uint256 public constant MAX_TIERS = 4;
    uint256 public constant MAX_LOCK = 30 days;

    IERC20 public projectToken;
    uint256 public lockPeriod = 7 days;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public unlockAt;

    // fee-discount tiers (ascending thresholds)
    uint256[] internal _tierThresholds;
    uint256[] internal _tierDiscountBps;

    // rewards
    address[] internal _rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => uint256) public accRewardPerShare; // token => acc * ACC
    mapping(address => uint256) public queuedRewards; // received while nobody staked
    mapping(address => mapping(address => uint256)) public rewardDebt; // user => token => debt
    mapping(address => mapping(address => uint256)) public pendingRewards; // user => token => owed

    event ProjectTokenSet(address indexed token);
    event Staked(address indexed account, uint256 amount, uint256 unlockAt);
    event Unstaked(address indexed account, uint256 amount);
    event RewardNotified(address indexed token, uint256 amount);
    event RewardClaimed(address indexed account, address indexed token, uint256 amount);
    event RewardTokenAdded(address indexed token);
    event TiersSet(uint256[] thresholds, uint256[] discountBps);
    event LockPeriodSet(uint256 lockPeriod);

    error AlreadySet();
    error TokenNotSet();
    error ZeroAddress();
    error ZeroAmount();
    error Locked(uint256 unlockAt);
    error Insufficient();
    error TooMany();
    error BadTiers();
    error NotRewardToken(address token);
    error BadParam();

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ----------------------------------------------------------------------------------------------
    // One-time token wiring (Timelock)
    // ----------------------------------------------------------------------------------------------

    /// @notice Set the $SLCE address. Callable exactly once, by the Timelock.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert AlreadySet();
        if (token == address(0)) revert ZeroAddress();
        if (isRewardToken[token]) revert BadParam();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function isActive() public view returns (bool) {
        return address(projectToken) != address(0) && !paused();
    }

    // ----------------------------------------------------------------------------------------------
    // Staking
    // ----------------------------------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        IERC20 t = projectToken;
        if (address(t) == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);

        uint256 balBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - balBefore;

        stakedOf[msg.sender] += received;
        totalStaked += received;
        uint256 unlock = block.timestamp + lockPeriod;
        unlockAt[msg.sender] = unlock;
        _resetDebt(msg.sender);
        _flushQueued();
        emit Staked(msg.sender, received, unlock);
    }

    /// @notice Unstaking is never blocked by pause (only by the lock).
    function unstake(uint256 amount) external nonReentrant {
        IERC20 t = projectToken;
        if (address(t) == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < unlockAt[msg.sender]) revert Locked(unlockAt[msg.sender]);
        if (amount > stakedOf[msg.sender]) revert Insufficient();
        _accrue(msg.sender);
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        _resetDebt(msg.sender);
        emit Unstaked(msg.sender, amount);
        t.safeTransfer(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        _accrue(msg.sender);
        _resetDebt(msg.sender);
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 owed = pendingRewards[msg.sender][token];
            if (owed == 0) continue;
            pendingRewards[msg.sender][token] = 0;
            emit RewardClaimed(msg.sender, token, owed);
            IERC20(token).safeTransfer(msg.sender, owed);
        }
    }

    function pendingReward(address account, address token) external view returns (uint256) {
        return pendingRewards[account][token]
            + (stakedOf[account] * accRewardPerShare[token]) / ACC - rewardDebt[account][token];
    }

    // ----------------------------------------------------------------------------------------------
    // Fee hooks
    // ----------------------------------------------------------------------------------------------

    /// @inheritdoc IProjectTokenHooks
    function feeDiscountBps(address account) external view returns (uint256 discount) {
        if (!isActive()) return 0;
        uint256 s = stakedOf[account];
        uint256 n = _tierThresholds.length;
        for (uint256 i; i < n; ++i) {
            if (s >= _tierThresholds[i]) discount = _tierDiscountBps[i];
        }
    }

    /// @inheritdoc IProjectTokenHooks
    function notifyReward(address token, uint256 amount) external nonReentrant {
        if (!isRewardToken[token]) revert NotRewardToken(token);
        if (amount == 0) return;
        IERC20 t = IERC20(token);
        uint256 balBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - balBefore;
        // slither-disable-next-line incorrect-equality
        if (totalStaked == 0) {
            queuedRewards[token] += received;
        } else {
            accRewardPerShare[token] += (received * ACC) / totalStaked;
        }
        emit RewardNotified(token, received);
    }

    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    function tiers() external view returns (uint256[] memory thresholds, uint256[] memory discountBps) {
        return (_tierThresholds, _tierDiscountBps);
    }

    // ----------------------------------------------------------------------------------------------
    // Internal
    // ----------------------------------------------------------------------------------------------

    function _accrue(address account) internal {
        uint256 s = stakedOf[account];
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 accrued = (s * accRewardPerShare[token]) / ACC;
            uint256 debt = rewardDebt[account][token];
            if (accrued > debt) pendingRewards[account][token] += accrued - debt;
        }
    }

    function _resetDebt(address account) internal {
        uint256 s = stakedOf[account];
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            rewardDebt[account][token] = (s * accRewardPerShare[token]) / ACC;
        }
    }

    // slither-disable-next-line incorrect-equality
    function _flushQueued() internal {
        if (totalStaked == 0) return;
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 q = queuedRewards[token];
            if (q != 0) {
                queuedRewards[token] = 0;
                accRewardPerShare[token] += (q * ACC) / totalStaked;
                emit RewardNotified(token, q);
            }
        }
    }

    // ----------------------------------------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------------------------------------

    function addRewardToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (isRewardToken[token]) return;
        if (token == address(projectToken)) revert BadParam();
        if (_rewardTokens.length >= MAX_REWARD_TOKENS) revert TooMany();
        isRewardToken[token] = true;
        _rewardTokens.push(token);
        emit RewardTokenAdded(token);
    }

    function setTiers(uint256[] calldata thresholds, uint256[] calldata discountBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (thresholds.length != discountBps.length || thresholds.length > MAX_TIERS) revert BadTiers();
        for (uint256 i; i < thresholds.length; ++i) {
            if (discountBps[i] > BPS) revert BadTiers();
            if (i != 0 && (thresholds[i] <= thresholds[i - 1] || discountBps[i] < discountBps[i - 1])) {
                revert BadTiers();
            }
        }
        _tierThresholds = thresholds;
        _tierDiscountBps = discountBps;
        emit TiersSet(thresholds, discountBps);
    }

    function setLockPeriod(uint256 period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (period > MAX_LOCK) revert BadParam();
        lockPeriod = period;
        emit LockPeriodSet(period);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
