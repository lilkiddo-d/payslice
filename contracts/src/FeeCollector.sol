// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeeCollector, IProjectTokenHooks} from "./interfaces/IPayslice.sol";

/// @title FeeCollector
/// @notice Receives payroll and conversion fees. While the project token is active, `stakerShareBps` of
///         conversion fees are streamed to stakers through ProjectTokenHooks; everything else accrues to the
///         treasury and can be swept there by anyone.
contract FeeCollector is IFeeCollector, AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    address public treasury;
    IProjectTokenHooks public hooks;
    uint256 public stakerShareBps;

    mapping(address => uint256) public treasuryBalance;

    event FeeReceived(address indexed from, address indexed token, uint256 amount, FeeKind kind, uint256 toStakers);
    event TreasurySwept(address indexed token, address indexed treasury, uint256 amount);
    event TreasurySet(address indexed treasury);
    event HooksSet(address indexed hooks);
    event StakerShareSet(uint256 bps);

    error ZeroAddress();
    error BadParam();

    constructor(address admin, address treasury_, uint256 stakerShareBps_) {
        if (admin == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (stakerShareBps_ > BPS) revert BadParam();
        treasury = treasury_;
        stakerShareBps = stakerShareBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IFeeCollector
    function receiveFee(address token, uint256 amount, FeeKind kind) external nonReentrant {
        if (amount == 0) return;
        IERC20 t = IERC20(token);
        uint256 balBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - balBefore;

        uint256 toStakers = 0;
        IProjectTokenHooks h = hooks;
        if (kind == FeeKind.Conversion && address(h) != address(0) && h.isActive() && h.isRewardToken(token)) {
            toStakers = (received * stakerShareBps) / BPS;
        }
        treasuryBalance[token] += received - toStakers;
        emit FeeReceived(msg.sender, token, received, kind, toStakers);

        if (toStakers != 0) {
            t.forceApprove(address(h), toStakers);
            h.notifyReward(token, toStakers);
        }
    }

    /// @notice Push accrued treasury fees to the treasury address. Callable by anyone.
    function sweep(address token) external nonReentrant {
        uint256 amount = treasuryBalance[token];
        if (amount == 0) return;
        treasuryBalance[token] = 0;
        emit TreasurySwept(token, treasury, amount);
        IERC20(token).safeTransfer(treasury, amount);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setHooks(address hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = IProjectTokenHooks(hooks_);
        emit HooksSet(hooks_);
    }

    function setStakerShareBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > BPS) revert BadParam();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }
}
