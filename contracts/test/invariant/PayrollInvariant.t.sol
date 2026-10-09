// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../Base.t.sol";
import {Payroll} from "../../src/Payroll.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @notice Drives a payroll through random employer / worker / time actions.
contract PayrollHandler is Test {
    Payroll public payroll;
    MockERC20 public usd;
    address public employer;
    address[] public workers;
    uint256[] public ids;
    mapping(uint256 => uint256) public lastEarned;

    bool public earnedDecreased;
    bool public withdrawFailed;
    bool public overpaid;
    uint256 public totalPaidOut;

    constructor(Payroll p, MockERC20 u, address e) {
        payroll = p;
        usd = u;
        employer = e;
        for (uint256 i; i < 4; ++i) workers.push(address(uint160(0xA000 + i)));
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _check() internal {
        for (uint256 i; i < ids.length; ++i) {
            uint256 e = payroll.earned(ids[i]);
            if (e < lastEarned[ids[i]]) earnedDecreased = true;
            lastEarned[ids[i]] = e;
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 20 days));
        _check();
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 50_000e6);
        usd.mint(employer, amount);
        vm.startPrank(employer);
        usd.approve(address(payroll), amount);
        payroll.deposit(amount);
        vm.stopPrank();
        _check();
    }

    function create(uint256 w, uint256 monthly, uint256 startIn, uint256 endIn, bool withCliff) external {
        if (ids.length >= 12) return;
        address worker = workers[w % workers.length];
        uint256 rateX = (bound(monthly, 1, 20_000e6) * 1e18) / 30 days;
        uint64 start = uint64(block.timestamp + bound(startIn, 0, 10 days));
        uint64 end = endIn % 3 == 0 ? 0 : start + uint64(bound(endIn, 1 days, 90 days));
        uint64 cliff = withCliff ? start + 3 days : 0;
        if (end != 0 && cliff > end) cliff = 0;
        vm.prank(employer);
        ids.push(payroll.createStream(worker, rateX, start, end, cliff));
        _check();
    }

    function update(uint256 i, uint256 monthly, uint256 endIn) external {
        if (ids.length == 0) return;
        uint256 id = ids[i % ids.length];
        Payroll.Stream memory s = payroll.getStream(id);
        if (s.status == Payroll.Status.Cancelled) return;
        uint256 rateX = (bound(monthly, 1, 20_000e6) * 1e18) / 30 days;
        uint64 floor_ = uint64(block.timestamp) > s.start ? uint64(block.timestamp) : s.start + 1;
        if (s.cliff > floor_) floor_ = s.cliff;
        uint64 end = endIn % 2 == 0 ? 0 : floor_ + uint64(bound(endIn, 1, 60 days));
        vm.prank(employer);
        try payroll.updateStream(id, rateX, end) {} catch {}
        _check();
    }

    function pause(uint256 i) external {
        if (ids.length == 0) return;
        vm.prank(employer);
        try payroll.pauseStream(ids[i % ids.length]) {} catch {}
        _check();
    }

    function resume(uint256 i) external {
        if (ids.length == 0) return;
        vm.prank(employer);
        try payroll.resumeStream(ids[i % ids.length]) {} catch {}
        _check();
    }

    function cancel(uint256 i) external {
        if (ids.length == 0) return;
        vm.prank(employer);
        try payroll.cancelStream(ids[i % ids.length]) {} catch {}
        _check();
    }

    function withdraw(uint256 i) external {
        if (ids.length == 0) return;
        uint256 id = ids[i % ids.length];
        uint256 w = payroll.withdrawable(id);
        address worker = payroll.getStream(id).worker;
        uint256 before = usd.balanceOf(worker);
        vm.prank(worker);
        try payroll.withdraw(id) returns (uint256 amt) {
            if (amt != w) overpaid = true;
            if (usd.balanceOf(worker) - before != amt) overpaid = true;
            totalPaidOut += amt;
        } catch {
            if (w > 0) withdrawFailed = true; // accrued pay must ALWAYS be withdrawable
        }
        _check();
    }

    function employerWithdraw(uint256 amount) external {
        uint256 free = payroll.unallocated();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(employer);
        payroll.withdrawUnallocated(amount, employer);
        _check();
    }

    function sync() external {
        uint256 n = ids.length;
        uint256[] memory list = new uint256[](n);
        for (uint256 i; i < n; ++i) list[i] = ids[i];
        payroll.syncStreams(list);
        _check();
    }
}

contract PayrollInvariantTest is BaseTest {
    PayrollHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PayrollHandler(payroll, usd, employer);
        // worker addresses have no slice rule => pure stablecoin path
        targetContract(address(handler));
    }

    /// Accrued pay never exceeds the funded balance: tokens held >= unallocated + everything owed to workers.
    function invariant_solvent() public view {
        uint256 owed;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            owed += payroll.earned(id) - payroll.getStream(id).withdrawn;
        }
        assertGe(usd.balanceOf(address(payroll)), owed + payroll.unallocated());
    }

    /// Every stream's withdrawable amount is covered by the actual token balance.
    function invariant_withdrawableCovered() public view {
        uint256 n = handler.idCount();
        uint256 bal = usd.balanceOf(address(payroll));
        for (uint256 i; i < n; ++i) {
            assertLe(payroll.withdrawable(handler.ids(i)), bal);
        }
    }

    /// Accrued pay is always withdrawable; withdrawals pay exactly what was shown.
    function invariant_alwaysWithdrawable() public view {
        assertFalse(handler.withdrawFailed());
        assertFalse(handler.overpaid());
    }

    /// No employer action (pause / edit / cancel / withdraw) ever reduces what a worker earned.
    function invariant_earnedMonotonic() public view {
        assertFalse(handler.earnedDecreased());
    }

    /// Conservation: total deposited (net) == held + paid to workers + withdrawn by employer is checked
    /// indirectly: the payroll never pays out more than it received.
    function invariant_noValueCreated() public view {
        assertLe(handler.totalPaidOut(), payroll.totalDeposited());
    }
}
