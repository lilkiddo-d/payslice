// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {StreamMath} from "./libraries/StreamMath.sol";
import {DateTimeLib} from "./libraries/DateTimeLib.sol";
import {
    IPayrollFactory, ISliceRouter, IBatchConverter, IFeeCollector
} from "./interfaces/IPayslice.sol";

/// @title Payroll
/// @notice One employer's payroll, deployed by PayrollFactory as an EIP-1167 minimal proxy.
///         The employer funds it with a stablecoin and streams per-second salaries to workers.
///
/// Accounting model (all amounts scaled by 1e18, see StreamMath):
///  - `unallocatedX`  funds not yet reserved for any stream. Only this can be withdrawn by the employer.
///  - Every second the payroll reserves `totalRateX` from `unallocatedX` (global settle, O(1)).
///  - Each stream lazily converts its reservation into `earnedX` when touched; any over-reservation
///    (before a stream starts / after it ends) is released back to `unallocatedX`.
///  - If `unallocatedX` cannot cover the next second, the payroll is insolvent: `paidUntil` stops at the
///    exact depletion second and no stream accrues until new funds arrive (auto-pause, never negative).
///
/// Worker guarantees: earned pay can never be reduced, cancelled, frozen or withdrawn by the employer, by
/// the protocol admin, or by a global pause. Withdrawals are never paused.
contract Payroll is Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StreamMath for StreamMath.Gaps;

    // ----------------------------------------------------------------------------------------------
    // Types & constants
    // ----------------------------------------------------------------------------------------------

    enum Status {
        None,
        Active,
        Paused,
        Cancelled
    }

    struct Stream {
        address worker;
        Status status;
        bool counted; // included in totalRateX
        uint64 start;
        uint64 end; // 0 = open ended
        uint64 cliff; // 0 = none; earned pay is withdrawable from this time (waived on cancel)
        uint64 checkpoint; // accrual settled up to here (<= paidUntil)
        uint64 monthCursor; // start of the current payslip month
        uint256 rateX;
        uint256 earnedX;
        uint256 earnedXAtMonthStart;
        uint256 withdrawn; // token base units
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BATCH = 50;
    uint256 public constant MAX_PAYSLIP_MONTHS = 12;
    uint256 public constant MAX_RATE_X = 1e45;
    uint32 public constant DEFAULT_WARN_DAYS = 14;
    uint32 public constant MAX_WARN_DAYS = 365;

    // ----------------------------------------------------------------------------------------------
    // Storage
    // ----------------------------------------------------------------------------------------------

    IPayrollFactory public factory;
    IERC20 public token;
    address public employer;
    address public pendingEmployer;
    string public name;

    uint32 public warnDays;
    bool public insolvent;
    uint64 public paidUntil;

    uint256 public unallocatedX;
    uint256 public totalRateX;
    uint256 public streamCount;

    uint256 public totalDeposited;
    uint256 public totalFeesPaid;
    uint256 public totalWithdrawnByWorkers;

    mapping(uint256 => Stream) internal _streams;
    mapping(address => uint256[]) internal _workerStreams;
    StreamMath.Gaps internal _gaps;

    // ----------------------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------------------

    event PayrollInitialized(address indexed employer, address indexed token, string name);
    event Deposited(address indexed from, uint256 amount, uint256 fee);
    event UnallocatedWithdrawn(address indexed to, uint256 amount);
    event StreamCreated(
        uint256 indexed streamId, address indexed worker, uint256 rateX, uint64 start, uint64 end, uint64 cliff
    );
    event StreamUpdated(uint256 indexed streamId, uint256 rateX, uint64 end);
    event CliffReduced(uint256 indexed streamId, uint64 cliff);
    event StreamPaused(uint256 indexed streamId);
    event StreamResumed(uint256 indexed streamId);
    event StreamCancelled(uint256 indexed streamId, uint256 earned, uint256 withdrawn);
    event StreamEnded(uint256 indexed streamId);
    event Withdrawn(
        uint256 indexed streamId, address indexed worker, uint256 amount, uint256 stablePart, uint256 slicePart
    );
    event SliceFallback(uint256 indexed streamId, uint256 amount);
    event Payslip(
        uint256 indexed streamId,
        address indexed worker,
        uint64 periodStart,
        uint64 periodEnd,
        uint256 earned,
        uint256 cumulativeEarned,
        uint256 cumulativeWithdrawn
    );
    event RanDry(uint64 depletedAt);
    event Resumed(uint64 gapStart, uint64 gapEnd);
    event LowRunway(uint256 runwaySeconds, uint256 thresholdSeconds);
    event WarnDaysSet(uint32 warnDays);
    event EmployerTransferStarted(address indexed current, address indexed pending);
    event EmployerTransferred(address indexed previous, address indexed current);

    // ----------------------------------------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------------------------------------

    error NotEmployer();
    error NotWorker();
    error NotPendingEmployer();
    error ProtocolPaused();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRate();
    error InvalidSchedule();
    error UnknownStream();
    error StreamNotActive();
    error StreamNotPaused();
    error StreamIsCancelled();
    error CliffNotReached();
    error NothingToWithdraw();
    error InsufficientUnallocated();
    error BatchTooLarge();
    error NotAllowed(address account);
    error InvalidWarnDays();

    // ----------------------------------------------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------------------------------------------

    modifier onlyEmployer() {
        if (msg.sender != employer) revert NotEmployer();
        _;
    }

    modifier whenProtocolActive() {
        if (factory.paused()) revert ProtocolPaused();
        _;
    }

    // ----------------------------------------------------------------------------------------------
    // Init
    // ----------------------------------------------------------------------------------------------

    constructor() {
        _disableInitializers();
    }

    function initialize(address employer_, address token_, string calldata name_) external initializer {
        if (employer_ == address(0) || token_ == address(0)) revert ZeroAddress();
        factory = IPayrollFactory(msg.sender);
        employer = employer_;
        token = IERC20(token_);
        name = name_;
        warnDays = DEFAULT_WARN_DAYS;
        paidUntil = uint64(block.timestamp);
        emit PayrollInitialized(employer_, token_, name_);
    }

    // ----------------------------------------------------------------------------------------------
    // Funding
    // ----------------------------------------------------------------------------------------------

    /// @notice Fund the payroll. Anyone may fund; a protocol fee (reduced for stakers) is taken on deposit.
    function deposit(uint256 amount) external nonReentrant whenProtocolActive {
        if (amount == 0) revert ZeroAmount();
        _settle();

        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balBefore;

        uint256 fee = (received * factory.effectiveFeeBps(employer)) / BPS;
        uint256 net = received - fee;

        unallocatedX += net * StreamMath.SCALE;
        totalDeposited += net;
        totalFeesPaid += fee;
        emit Deposited(msg.sender, received, fee);

        _tryResume();
        _checkRunway();

        if (fee != 0) {
            address collector = factory.feeCollector();
            token.forceApprove(collector, fee);
            IFeeCollector(collector).receiveFee(address(token), fee, IFeeCollector.FeeKind.Payroll);
        }
    }

    /// @notice Employer withdraws funds that are not reserved for any stream. Earned pay is untouchable.
    function withdrawUnallocated(uint256 amount, address to) external nonReentrant onlyEmployer {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _settle();
        uint256 amountX = amount * StreamMath.SCALE;
        if (amountX > unallocatedX) revert InsufficientUnallocated();
        unallocatedX -= amountX;
        emit UnallocatedWithdrawn(to, amount);
        _checkRunway();
        token.safeTransfer(to, amount);
    }

    // ----------------------------------------------------------------------------------------------
    // Stream management (employer)
    // ----------------------------------------------------------------------------------------------

    /// @param worker recipient
    /// @param rateX token base units per second scaled by 1e18
    /// @param start 0 = now, otherwise >= now
    /// @param end 0 = open ended, otherwise > start
    /// @param cliff 0 = none, otherwise in [start, end]
    function createStream(address worker, uint256 rateX, uint64 start, uint64 end, uint64 cliff)
        external
        onlyEmployer
        whenProtocolActive
        returns (uint256 streamId)
    {
        if (worker == address(0)) revert ZeroAddress();
        if (rateX == 0 || rateX > MAX_RATE_X) revert InvalidRate();
        if (!factory.isAllowed(worker)) revert NotAllowed(worker);
        if (!factory.isAllowed(employer)) revert NotAllowed(employer);
        uint64 nowT = uint64(block.timestamp);
        if (start == 0) start = nowT;
        if (start < nowT) revert InvalidSchedule();
        if (end != 0 && end <= start) revert InvalidSchedule();
        if (cliff != 0 && (cliff < start || (end != 0 && cliff > end))) revert InvalidSchedule();

        _settle();

        streamId = ++streamCount;
        Stream storage s = _streams[streamId];
        s.worker = worker;
        s.status = Status.Active;
        s.counted = true;
        s.start = start;
        s.end = end;
        s.cliff = cliff;
        s.checkpoint = paidUntil;
        s.monthCursor = uint64(DateTimeLib.monthStart(paidUntil));
        s.rateX = rateX;
        totalRateX += rateX;
        _workerStreams[worker].push(streamId);

        emit StreamCreated(streamId, worker, rateX, start, end, cliff);
        _checkRunway();
        factory.onStreamCreated(worker);
    }

    /// @notice Change the rate and/or end of a stream going forward. Already-earned pay is unaffected.
    function updateStream(uint256 streamId, uint256 newRateX, uint64 newEnd) external onlyEmployer whenProtocolActive {
        if (newRateX == 0 || newRateX > MAX_RATE_X) revert InvalidRate();
        Stream storage s = _get(streamId);
        if (s.status == Status.Cancelled) revert StreamIsCancelled();
        _settle();
        _syncStream(streamId, s);
        if (newEnd != 0 && (newEnd <= s.start || newEnd < paidUntil || (s.cliff != 0 && newEnd < s.cliff))) {
            revert InvalidSchedule();
        }

        if (s.counted) totalRateX -= s.rateX;
        s.rateX = newRateX;
        s.end = newEnd;
        bool live = s.status == Status.Active && (newEnd == 0 || newEnd > paidUntil);
        s.counted = live;
        if (live) totalRateX += newRateX;

        emit StreamUpdated(streamId, newRateX, newEnd);
        _tryResume();
        _checkRunway();
    }

    /// @notice A cliff can only be moved earlier (never used to delay pay).
    function reduceCliff(uint256 streamId, uint64 newCliff) external onlyEmployer {
        Stream storage s = _get(streamId);
        if (newCliff >= s.cliff || (newCliff != 0 && newCliff < s.start)) revert InvalidSchedule();
        s.cliff = newCliff;
        emit CliffReduced(streamId, newCliff);
    }

    function pauseStream(uint256 streamId) external onlyEmployer {
        Stream storage s = _get(streamId);
        if (s.status != Status.Active) revert StreamNotActive();
        _settle();
        _syncStream(streamId, s);
        if (s.counted) {
            totalRateX -= s.rateX;
            s.counted = false;
        }
        s.status = Status.Paused;
        emit StreamPaused(streamId);
        _tryResume();
    }

    function resumeStream(uint256 streamId) external onlyEmployer whenProtocolActive {
        Stream storage s = _get(streamId);
        if (s.status != Status.Paused) revert StreamNotPaused();
        _settle();
        _syncStream(streamId, s);
        s.status = Status.Active;
        if (s.end == 0 || s.end > paidUntil) {
            s.counted = true;
            totalRateX += s.rateX;
        }
        emit StreamResumed(streamId);
        _checkRunway();
    }

    /// @notice Stop a stream permanently. Everything earned so far stays withdrawable and any cliff is waived.
    function cancelStream(uint256 streamId) external onlyEmployer {
        Stream storage s = _get(streamId);
        if (s.status == Status.Cancelled) revert StreamIsCancelled();
        _settle();
        _syncStream(streamId, s);
        if (s.counted) {
            totalRateX -= s.rateX;
            s.counted = false;
        }
        s.status = Status.Cancelled;
        _emitPayslip(streamId, s, paidUntil);
        emit StreamCancelled(streamId, StreamMath.toTokens(s.earnedX), s.withdrawn);
        _tryResume();
    }

    function setWarnDays(uint32 days_) external onlyEmployer {
        if (days_ > MAX_WARN_DAYS) revert InvalidWarnDays();
        warnDays = days_;
        emit WarnDaysSet(days_);
        _checkRunway();
    }

    function transferEmployer(address newEmployer) external onlyEmployer {
        if (newEmployer == address(0)) revert ZeroAddress();
        pendingEmployer = newEmployer;
        emit EmployerTransferStarted(employer, newEmployer);
    }

    function acceptEmployer() external {
        if (msg.sender != pendingEmployer) revert NotPendingEmployer();
        address previous = employer;
        employer = msg.sender;
        pendingEmployer = address(0);
        emit EmployerTransferred(previous, msg.sender);
        factory.onEmployerTransferred(previous, msg.sender);
    }

    // ----------------------------------------------------------------------------------------------
    // Worker
    // ----------------------------------------------------------------------------------------------

    /// @notice Withdraw everything earned on a stream. The worker's slice rule decides how much is queued for
    ///         stock conversion; the rest is paid in stablecoin. Never blocked by pauses. If the worker opted
    ///         into auto-harvest, anyone (e.g. the keeper) may trigger it — funds always go to the worker.
    function withdraw(uint256 streamId) external nonReentrant returns (uint256 amount) {
        Stream storage s = _get(streamId);
        address worker = s.worker;
        if (msg.sender != worker && !_autoHarvest(worker)) revert NotWorker();

        _settle();
        _syncStream(streamId, s);
        if (s.status != Status.Cancelled && s.cliff != 0 && block.timestamp < s.cliff) revert CliffNotReached();

        amount = StreamMath.toTokens(s.earnedX) - s.withdrawn;
        if (amount == 0) revert NothingToWithdraw();
        s.withdrawn += amount;
        totalWithdrawnByWorkers += amount;

        uint256 slicePart = _sliceAmount(worker, amount);
        if (slicePart != 0) {
            IBatchConverter conv = factory.batchConverter();
            token.forceApprove(address(conv), slicePart);
            try conv.deposit(worker, slicePart) {}
            catch {
                token.forceApprove(address(conv), 0);
                emit SliceFallback(streamId, slicePart);
                slicePart = 0;
            }
        }
        uint256 stablePart = amount - slicePart;
        emit Withdrawn(streamId, worker, amount, stablePart, slicePart);
        if (stablePart != 0) token.safeTransfer(worker, stablePart);
    }

    // ----------------------------------------------------------------------------------------------
    // Keeper / public
    // ----------------------------------------------------------------------------------------------

    /// @notice Settle the payroll and a bounded batch of streams (emits monthly Payslip events).
    function syncStreams(uint256[] calldata streamIds) external {
        if (streamIds.length > MAX_BATCH) revert BatchTooLarge();
        _settle();
        for (uint256 i; i < streamIds.length; ++i) {
            _syncStream(streamIds[i], _get(streamIds[i]));
        }
        _tryResume();
        _checkRunway();
    }

    // ----------------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------------

    function getStream(uint256 streamId) external view returns (Stream memory) {
        return _streams[streamId];
    }

    function streamsOf(address worker) external view returns (uint256[] memory) {
        return _workerStreams[worker];
    }

    function gapCount() external view returns (uint256) {
        return _gaps.count();
    }

    /// @notice Total earned on a stream as of now (token units, floored).
    function earned(uint256 streamId) public view returns (uint256) {
        Stream storage s = _streams[streamId];
        (uint64 pu,,) = _previewSettle();
        return StreamMath.toTokens(_previewEarnedX(s, pu));
    }

    /// @notice Amount the worker could withdraw right now.
    function withdrawable(uint256 streamId) external view returns (uint256) {
        Stream storage s = _streams[streamId];
        if (s.status == Status.None) return 0;
        if (s.status != Status.Cancelled && s.cliff != 0 && block.timestamp < s.cliff) return 0;
        return earned(streamId) - s.withdrawn;
    }

    /// @notice Unallocated balance (token units) as of now.
    function unallocated() external view returns (uint256) {
        (, uint256 u,) = _previewSettle();
        return StreamMath.toTokens(u);
    }

    /// @notice Conservative seconds of runway left at the current committed burn rate.
    function runwaySeconds() public view returns (uint256) {
        (, uint256 u, bool ins) = _previewSettle();
        if (ins) return 0;
        if (totalRateX == 0) return type(uint256).max;
        return u / totalRateX;
    }

    /// @notice Committed burn per second in token units scaled by 1e18.
    function burnRateX() external view returns (uint256) {
        return totalRateX;
    }

    function isLowRunway() external view returns (bool) {
        return warnDays != 0 && runwaySeconds() < uint256(warnDays) * 1 days;
    }

    function isInsolvent() external view returns (bool) {
        (,, bool ins) = _previewSettle();
        return ins;
    }

    // ----------------------------------------------------------------------------------------------
    // Internal accounting
    // ----------------------------------------------------------------------------------------------

    function _get(uint256 streamId) internal view returns (Stream storage s) {
        s = _streams[streamId];
        if (s.status == Status.None) revert UnknownStream();
    }

    /// @dev Reserve funds for every second since `paidUntil` at the committed rate. O(1).
    function _settle() internal {
        (uint64 pu, uint256 u, bool ins) = _previewSettle();
        if (ins && !insolvent) emit RanDry(pu);
        paidUntil = pu;
        unallocatedX = u;
        insolvent = ins;
    }

    function _previewSettle() internal view returns (uint64 pu, uint256 u, bool ins) {
        pu = paidUntil;
        u = unallocatedX;
        ins = insolvent;
        uint64 nowT = uint64(block.timestamp);
        if (ins || pu >= nowT) return (pu, u, ins);
        uint256 rate = totalRateX;
        // slither-disable-next-line incorrect-equality
        if (rate == 0) return (nowT, u, false);
        uint256 need = rate * (nowT - pu);
        if (need <= u) return (nowT, u - need, false);
        // Whole seconds the remaining balance can fund; the remainder (< rate) stays unallocated.
        // slither-disable-next-line divide-before-multiply
        uint256 secs = u / rate;
        return (pu + uint64(secs), u - secs * rate, true);
    }

    /// @dev Leave insolvency once there is at least one second of runway. The dry period becomes a gap that
    ///      no stream accrues over.
    function _tryResume() internal {
        if (!insolvent) return;
        if (totalRateX != 0 && unallocatedX < totalRateX) return;
        uint64 nowT = uint64(block.timestamp);
        uint64 gapStart = paidUntil;
        _gaps.record(gapStart, nowT);
        paidUntil = nowT;
        insolvent = false;
        emit Resumed(gapStart, nowT);
    }

    function _checkRunway() internal {
        uint256 threshold = uint256(warnDays) * 1 days;
        if (threshold == 0) return;
        uint256 r = runwaySeconds();
        if (r < threshold) emit LowRunway(r, threshold);
    }

    /// @dev Bring a stream's checkpoint up to `paidUntil`, emitting a Payslip for each completed month.
    function _syncStream(uint256 streamId, Stream storage s) internal {
        if (s.status == Status.Cancelled) return;
        uint64 b = paidUntil;
        uint64 a = s.checkpoint;
        if (b <= a) return;

        uint64 boundary = uint64(DateTimeLib.nextMonthStart(s.monthCursor));
        uint256 steps;
        while (boundary <= b && steps < MAX_PAYSLIP_MONTHS) {
            _accrueSegment(s, a, boundary);
            _emitPayslip(streamId, s, boundary);
            s.earnedXAtMonthStart = s.earnedX;
            s.monthCursor = boundary;
            a = boundary;
            boundary = uint64(DateTimeLib.nextMonthStart(boundary));
            ++steps;
        }
        if (boundary <= b) {
            // Long-untouched stream: roll the remaining whole months into one catch-up payslip.
            uint64 lastBoundary = uint64(DateTimeLib.monthStart(b));
            _accrueSegment(s, a, lastBoundary);
            _emitPayslip(streamId, s, lastBoundary);
            s.earnedXAtMonthStart = s.earnedX;
            s.monthCursor = lastBoundary;
            a = lastBoundary;
        }
        _accrueSegment(s, a, b);
        s.checkpoint = b;

        if (s.counted && s.end != 0 && b >= s.end) {
            s.counted = false;
            totalRateX -= s.rateX;
            emit StreamEnded(streamId);
        }
    }

    function _accrueSegment(Stream storage s, uint64 a, uint64 b) internal {
        if (!s.counted || b <= a) return;
        (uint256 reservedX, uint256 earnedX) = _gaps.accrue(s.rateX, s.start, s.end, a, b);
        s.earnedX += earnedX;
        uint256 released = reservedX - earnedX;
        if (released != 0) unallocatedX += released;
    }

    function _emitPayslip(uint256 streamId, Stream storage s, uint64 periodEnd) internal {
        uint256 periodEarned = StreamMath.toTokens(s.earnedX) - StreamMath.toTokens(s.earnedXAtMonthStart);
        if (periodEarned == 0) return;
        emit Payslip(
            streamId,
            s.worker,
            s.monthCursor,
            periodEnd,
            periodEarned,
            StreamMath.toTokens(s.earnedX),
            s.withdrawn
        );
    }

    function _previewEarnedX(Stream storage s, uint64 pu) internal view returns (uint256) {
        if (!s.counted || pu <= s.checkpoint) return s.earnedX;
        return s.earnedX + _gaps.earnedOver(s.rateX, s.start, s.end, s.checkpoint, pu);
    }

    function _autoHarvest(address worker) internal view returns (bool) {
        ISliceRouter router = factory.sliceRouter();
        if (address(router) == address(0)) return false;
        try router.autoHarvest(worker) returns (bool on) {
            return on;
        } catch {
            return false;
        }
    }

    function _sliceAmount(address worker, uint256 amount) internal view returns (uint256) {
        ISliceRouter router = factory.sliceRouter();
        IBatchConverter conv = factory.batchConverter();
        if (address(router) == address(0) || address(conv) == address(0)) return 0;
        try conv.inputToken() returns (address input) {
            if (input != address(token)) return 0;
        } catch {
            return 0;
        }
        try router.split(worker, amount) returns (uint256 stablePart, uint256 slicePart) {
            return stablePart + slicePart == amount ? slicePart : 0;
        } catch {
            return 0;
        }
    }
}
