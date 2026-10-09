// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    ISliceRouter,
    IDexAdapter,
    IOracleAdapter,
    IMarketClock,
    IFeeCollector,
    IComplianceRegistry
} from "./interfaces/IPayslice.sol";
import {IERC20Decimals} from "./interfaces/IExternal.sol";

/// @title BatchConverter
/// @notice Pools workers' slice deposits into weekly epochs and converts each (epoch, stock) pool in one
///         batched swap during US market hours. Workers then claim exactly their pro-rata share:
///             out_i = floor(in_i * totalOut / totalIn)
///         which is O(1) per worker (no loops over workers).
///
/// Anti-sandwich design:
///  - Only *closed* epochs can be executed, so the batch size is fixed and public in advance.
///  - Only KEEPER_ROLE executes, during market hours, with a deadline.
///  - Every swap's minOut is at least the Chainlink-implied output minus `maxSlippageBps`, regardless of
///    what the keeper passes; the keeper can only tighten it. Large batches can be split in chunks.
///  - If a batch cannot be executed for `refundDelay`, workers can reclaim their unconverted input.
contract BatchConverter is AccessControl, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 public constant EPOCH = 7 days;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 100; // 1%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 public constant MAX_CLAIM_BATCH = 50;

    struct Batch {
        uint256 totalIn; // gross deposits
        uint256 fee; // conversion fee taken (set on first execution)
        uint256 executedIn; // input swapped so far (net of fee)
        uint256 totalOut; // stock tokens received
        bool feeTaken;
        bool finalized; // fully converted: claims open
        bool refunding; // stale: refunds open
    }

    IERC20 public immutable inputToken_;
    uint256 public immutable genesis;

    ISliceRouter public sliceRouter;
    IDexAdapter public dex;
    IOracleAdapter public oracle;
    IMarketClock public clock;
    IFeeCollector public feeCollector;
    IComplianceRegistry public compliance;

    uint256 public conversionFeeBps;
    uint256 public maxSlippageBps;
    uint256 public refundDelay = 4 weeks;

    mapping(uint256 => mapping(address => Batch)) public batches;
    mapping(uint256 => mapping(address => mapping(address => uint256))) public userIn;
    mapping(uint256 => mapping(address => mapping(address => bool))) public settled;

    event Deposited(uint256 indexed epoch, address indexed worker, address indexed asset, uint256 amount);
    event BatchExecuted(
        uint256 indexed epoch, address indexed asset, uint256 amountIn, uint256 amountOut, uint256 oracleMinOut
    );
    event BatchFinalized(uint256 indexed epoch, address indexed asset, uint256 totalIn, uint256 totalOut);
    event ConversionFeeTaken(uint256 indexed epoch, address indexed asset, uint256 fee);
    event Claimed(uint256 indexed epoch, address indexed asset, address indexed worker, uint256 amountOut);
    event RefundsOpened(uint256 indexed epoch, address indexed asset);
    event Refunded(
        uint256 indexed epoch, address indexed asset, address indexed worker, uint256 inputBack, uint256 assetOut
    );
    event ConfigSet(bytes32 indexed key, address value);
    event ParamsSet(uint256 conversionFeeBps, uint256 maxSlippageBps, uint256 refundDelay);

    error ZeroAddress();
    error ZeroAmount();
    error NoAllocation();
    error UnsupportedAsset(address asset);
    error EpochNotClosed();
    error MarketClosed();
    error Expired();
    error BatchClosed();
    error NothingToExecute();
    error NotFinalized();
    error AlreadySettled();
    error NotStale();
    error NothingToClaim();
    error ParamTooHigh();
    error BatchTooLarge();
    error NotAllowed(address account);
    error SlippageExceeded();

    constructor(
        address admin,
        address guardian,
        address input,
        address sliceRouter_,
        address dex_,
        address oracle_,
        address clock_,
        address feeCollector_,
        uint256 conversionFeeBps_,
        uint256 maxSlippageBps_
    ) {
        if (
            admin == address(0) || guardian == address(0) || input == address(0) || sliceRouter_ == address(0)
                || dex_ == address(0) || oracle_ == address(0) || clock_ == address(0) || feeCollector_ == address(0)
        ) revert ZeroAddress();
        if (conversionFeeBps_ > MAX_FEE_BPS || maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert ParamTooHigh();
        inputToken_ = IERC20(input);
        genesis = block.timestamp;
        sliceRouter = ISliceRouter(sliceRouter_);
        dex = IDexAdapter(dex_);
        oracle = IOracleAdapter(oracle_);
        clock = IMarketClock(clock_);
        feeCollector = IFeeCollector(feeCollector_);
        conversionFeeBps = conversionFeeBps_;
        maxSlippageBps = maxSlippageBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function inputToken() external view returns (address) {
        return address(inputToken_);
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / EPOCH;
    }

    function epochEnd(uint256 epoch) public view returns (uint256) {
        return genesis + (epoch + 1) * EPOCH;
    }

    // ----------------------------------------------------------------------------------------------
    // Deposits (called by Payroll on withdraw, or by anyone for any worker with their own funds)
    // ----------------------------------------------------------------------------------------------

    function deposit(address worker, uint256 amount) external nonReentrant whenNotPaused {
        if (worker == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IComplianceRegistry c = compliance;
        if (address(c) != address(0) && !c.isAllowed(worker)) revert NotAllowed(worker);

        (address[] memory assets, uint16[] memory weights, uint256 totalWeight) = _allocation(worker);
        uint256 balBefore = inputToken_.balanceOf(address(this));
        inputToken_.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = inputToken_.balanceOf(address(this)) - balBefore;
        _credit(worker, currentEpoch(), assets, weights, totalWeight, received);
    }

    function _allocation(address worker)
        internal
        view
        returns (address[] memory assets, uint16[] memory weights, uint256 totalWeight)
    {
        uint16 sliceBps;
        (sliceBps, assets, weights) = sliceRouter.allocationOf(worker);
        uint256 n = assets.length;
        if (n == 0 || sliceBps == 0) revert NoAllocation();
        for (uint256 i; i < n; ++i) {
            address asset = assets[i];
            if (!oracle.hasFeed(asset) || !dex.hasRoute(address(inputToken_), asset)) revert UnsupportedAsset(asset);
            totalWeight += weights[i];
        }
    }

    function _credit(
        address worker,
        uint256 epoch,
        address[] memory assets,
        uint16[] memory weights,
        uint256 totalWeight,
        uint256 received
    ) internal {
        uint256 n = assets.length;
        uint256 remaining = received;
        for (uint256 i; i < n; ++i) {
            uint256 part = i == n - 1 ? remaining : (received * weights[i]) / totalWeight;
            remaining -= part;
            if (part != 0) {
                batches[epoch][assets[i]].totalIn += part;
                userIn[epoch][assets[i]][worker] += part;
                emit Deposited(epoch, worker, assets[i], part);
            }
        }
    }

    // ----------------------------------------------------------------------------------------------
    // Keeper execution
    // ----------------------------------------------------------------------------------------------

    /// @notice Convert (part of) a closed epoch's pool for `asset`.
    /// @param amountIn chunk size (0 = everything remaining)
    /// @param minOut keeper-supplied floor; the oracle floor is always enforced on top of it
    function executeBatch(uint256 epoch, address asset, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        onlyRole(KEEPER_ROLE)
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (epoch >= currentEpoch()) revert EpochNotClosed();
        Batch storage b = batches[epoch][asset];
        if (b.finalized || b.refunding) revert BatchClosed();
        if (b.totalIn == 0) revert NothingToExecute();
        if (!clock.isMarketOpen()) revert MarketClosed();

        uint256 fee = 0;
        if (!b.feeTaken) {
            b.feeTaken = true;
            fee = (b.totalIn * conversionFeeBps) / BPS;
            b.fee = fee;
        }
        uint256 remaining = b.totalIn - b.fee - b.executedIn;
        if (remaining == 0) revert NothingToExecute();
        if (amountIn == 0 || amountIn > remaining) amountIn = remaining;

        uint256 oracleMin = quoteMinOut(asset, amountIn);
        if (minOut < oracleMin) minOut = oracleMin;
        b.executedIn += amountIn;
        bool done = b.executedIn >= b.totalIn - b.fee;
        if (done) b.finalized = true;

        // interactions (nonReentrant; every entry point that reads `batches` is also nonReentrant)
        if (fee != 0) _payFee(epoch, asset, fee);
        amountOut = _swap(asset, amountIn, minOut, deadline);

        // slither-disable-next-line reentrancy-no-eth
        b.totalOut += amountOut;
        emit BatchExecuted(epoch, asset, amountIn, amountOut, oracleMin);
        if (done) emit BatchFinalized(epoch, asset, b.totalIn, b.totalOut);
    }

    function _payFee(uint256 epoch, address asset, uint256 fee) internal {
        inputToken_.forceApprove(address(feeCollector), fee);
        feeCollector.receiveFee(address(inputToken_), fee, IFeeCollector.FeeKind.Conversion);
        emit ConversionFeeTaken(epoch, asset, fee);
    }

    function _swap(address asset, uint256 amountIn, uint256 minOut, uint256 deadline)
        internal
        returns (uint256 amountOut)
    {
        IERC20 out = IERC20(asset);
        // Balance-diff accounting around a call to the Timelock-configured adapter; guarded by nonReentrant.
        // slither-disable-next-line reentrancy-balance
        uint256 balBefore = out.balanceOf(address(this));
        inputToken_.forceApprove(address(dex), amountIn);
        uint256 reported = dex.swapExactIn(address(inputToken_), asset, amountIn, minOut, deadline, address(this));
        inputToken_.forceApprove(address(dex), 0);
        amountOut = out.balanceOf(address(this)) - balBefore;
        if (amountOut < minOut || reported < minOut) revert SlippageExceeded();
    }

    /// @notice Oracle-implied minimum output for `amountIn` of input token, after max slippage.
    function quoteMinOut(address asset, uint256 amountIn) public view returns (uint256) {
        uint256 pIn = oracle.getPrice(address(inputToken_));
        uint256 pOut = oracle.getPrice(asset);
        uint256 decIn = IERC20Decimals(address(inputToken_)).decimals();
        uint256 decOut = IERC20Decimals(asset).decimals();
        // minOut = amountIn * pIn / 10^decIn * 10^decOut / pOut * (1 - slippage), one rounding step
        return Math.mulDiv(amountIn * (BPS - maxSlippageBps), pIn * (10 ** decOut), pOut * (10 ** decIn) * BPS);
    }

    // ----------------------------------------------------------------------------------------------
    // Claims & refunds
    // ----------------------------------------------------------------------------------------------

    /// @notice Pro-rata share of a finalized batch. Anyone may trigger; tokens go to the worker.
    function claim(uint256 epoch, address asset, address worker) public nonReentrant returns (uint256 amountOut) {
        Batch storage b = batches[epoch][asset];
        if (!b.finalized) revert NotFinalized();
        amountOut = _claimable(b, epoch, asset, worker);
        settled[epoch][asset][worker] = true;
        emit Claimed(epoch, asset, worker, amountOut);
        if (amountOut != 0) IERC20(asset).safeTransfer(worker, amountOut);
    }

    function claimMany(uint256[] calldata epochs, address[] calldata assets, address worker) external {
        if (epochs.length != assets.length) revert NothingToClaim();
        if (epochs.length > MAX_CLAIM_BATCH) revert BatchTooLarge();
        for (uint256 i; i < epochs.length; ++i) {
            claim(epochs[i], assets[i], worker);
        }
    }

    function claimable(uint256 epoch, address asset, address worker) external view returns (uint256) {
        Batch storage b = batches[epoch][asset];
        if (!b.finalized || settled[epoch][asset][worker]) return 0;
        return (userIn[epoch][asset][worker] * b.totalOut) / b.totalIn;
    }

    /// @notice Open refunds for a batch that could not be (fully) converted within `refundDelay`.
    function openRefunds(uint256 epoch, address asset) external {
        Batch storage b = batches[epoch][asset];
        if (b.finalized || b.refunding) revert BatchClosed();
        if (b.totalIn == 0) revert NothingToExecute();
        if (block.timestamp < epochEnd(epoch) + refundDelay) revert NotStale();
        b.refunding = true;
        emit RefundsOpened(epoch, asset);
    }

    /// @notice Worker's share of the unconverted input plus their share of anything already converted.
    function refund(uint256 epoch, address asset, address worker)
        external
        nonReentrant
        returns (uint256 inputBack, uint256 assetOut)
    {
        Batch storage b = batches[epoch][asset];
        if (!b.refunding) revert NotStale();
        if (settled[epoch][asset][worker]) revert AlreadySettled();
        uint256 u = userIn[epoch][asset][worker];
        if (u == 0) revert NothingToClaim();
        settled[epoch][asset][worker] = true;
        uint256 leftover = b.totalIn - b.fee - b.executedIn;
        inputBack = (u * leftover) / b.totalIn;
        assetOut = (u * b.totalOut) / b.totalIn;
        emit Refunded(epoch, asset, worker, inputBack, assetOut);
        if (inputBack != 0) inputToken_.safeTransfer(worker, inputBack);
        if (assetOut != 0) IERC20(asset).safeTransfer(worker, assetOut);
    }

    function _claimable(Batch storage b, uint256 epoch, address asset, address worker)
        internal
        view
        returns (uint256)
    {
        if (settled[epoch][asset][worker]) revert AlreadySettled();
        uint256 u = userIn[epoch][asset][worker];
        if (u == 0) revert NothingToClaim();
        return (u * b.totalOut) / b.totalIn;
    }

    // ----------------------------------------------------------------------------------------------
    // Admin (Timelock) & guardian
    // ----------------------------------------------------------------------------------------------

    function setDex(address dex_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (dex_ == address(0)) revert ZeroAddress();
        dex = IDexAdapter(dex_);
        emit ConfigSet("dex", dex_);
    }

    function setOracle(address oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IOracleAdapter(oracle_);
        emit ConfigSet("oracle", oracle_);
    }

    function setClock(address clock_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (clock_ == address(0)) revert ZeroAddress();
        clock = IMarketClock(clock_);
        emit ConfigSet("clock", clock_);
    }

    function setSliceRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddress();
        sliceRouter = ISliceRouter(router);
        emit ConfigSet("sliceRouter", router);
    }

    function setFeeCollector(address collector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (collector == address(0)) revert ZeroAddress();
        feeCollector = IFeeCollector(collector);
        emit ConfigSet("feeCollector", collector);
    }

    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ConfigSet("compliance", registry);
    }

    function setParams(uint256 feeBps, uint256 slippageBps, uint256 refundDelay_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (feeBps > MAX_FEE_BPS || slippageBps > MAX_SLIPPAGE_BPS) revert ParamTooHigh();
        if (refundDelay_ < 1 weeks || refundDelay_ > 12 weeks) revert ParamTooHigh();
        conversionFeeBps = feeBps;
        maxSlippageBps = slippageBps;
        refundDelay = refundDelay_;
        emit ParamsSet(feeBps, slippageBps, refundDelay_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
