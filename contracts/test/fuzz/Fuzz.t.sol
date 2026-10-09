// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {Payroll} from "../../src/Payroll.sol";

contract PayrollFuzzTest is BaseTest {
    uint256 internal constant MAX_RATE = 1e6 * 1e18; // up to 1 tUSD / second

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        factory.setPayrollFeeBps(0);
        usd.mint(employer, type(uint128).max);
    }

    /// accrued == floor(rate * t / 1e18) exactly
    function testFuzz_accrualExact(uint256 rateX, uint32 dt) public {
        rateX = bound(rateX, 1, MAX_RATE);
        fund(1e30);
        uint256 id = stream(alice, rateX);
        vm.warp(block.timestamp + dt);
        assertEq(payroll.earned(id), (rateX * dt) / SCALE);
    }

    /// any sequence of rate edits loses nothing to rounding: earned == floor(sum(rate_i * dt_i) / 1e18)
    function testFuzz_noRoundingDrift(uint256 seed, uint8 nEdits) public {
        nEdits = uint8(bound(nEdits, 1, 30));
        fund(1e30);
        uint256 rate = bound(uint256(keccak256(abi.encode(seed, "r0"))), 1, MAX_RATE);
        uint256 id = stream(alice, rate);
        uint256 exactX;
        for (uint256 i; i < nEdits; ++i) {
            uint256 dt = bound(uint256(keccak256(abi.encode(seed, i, "t"))), 0, 40 days);
            vm.warp(block.timestamp + dt);
            exactX += rate * dt;
            rate = bound(uint256(keccak256(abi.encode(seed, i, "r"))), 1, MAX_RATE);
            vm.prank(employer);
            payroll.updateStream(id, rate, 0);
            if (i % 3 == 0) {
                // withdrawing in between never changes the total
                if (payroll.withdrawable(id) > 0) {
                    vm.prank(alice);
                    payroll.withdraw(id);
                }
            }
        }
        assertEq(payroll.earned(id), exactX / SCALE);
        assertEq(payroll.earned(id), payroll.getStream(id).withdrawn + payroll.withdrawable(id));
    }

    /// cancelling never reduces what the worker already earned, and it stays withdrawable
    function testFuzz_cancelKeepsEarned(uint256 rateX, uint32 dt, uint32 after_, uint32 cliffIn) public {
        rateX = bound(rateX, 1e12, MAX_RATE);
        dt = uint32(bound(dt, 1, 400 days));
        fund(1e30);
        uint64 cliff = uint64(block.timestamp + bound(cliffIn, 0, 800 days));
        vm.prank(employer);
        uint256 id = payroll.createStream(alice, rateX, 0, 0, cliff);
        vm.warp(block.timestamp + dt);
        uint256 e = payroll.earned(id);
        vm.prank(employer);
        payroll.cancelStream(id);
        assertEq(payroll.earned(id), e);
        vm.warp(block.timestamp + after_);
        assertEq(payroll.earned(id), e);
        assertEq(payroll.withdrawable(id), e); // cliff waived
        if (e > 0) {
            vm.prank(alice);
            assertEq(payroll.withdraw(id), e);
        }
    }

    /// pausing/editing/end-dating never reduces earned
    function testFuzz_employerActionsNeverReduceEarned(uint256 seed) public {
        fund(1e30);
        uint256 id = stream(alice, bound(seed, 1, MAX_RATE));
        uint256 last;
        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(seed, i))), 0, 30 days));
            uint256 action = uint256(keccak256(abi.encode(seed, i, "a"))) % 4;
            Payroll.Stream memory s = payroll.getStream(id);
            vm.startPrank(employer);
            if (action == 0 && s.status == Payroll.Status.Active) payroll.pauseStream(id);
            else if (action == 1 && s.status == Payroll.Status.Paused) payroll.resumeStream(id);
            else if (action == 2) payroll.updateStream(id, bound(seed >> i, 1, MAX_RATE), uint64(block.timestamp + 1 days));
            else if (action == 3) payroll.updateStream(id, bound(seed >> (i + 1), 1, MAX_RATE), 0);
            vm.stopPrank();
            uint256 e = payroll.earned(id);
            assertGe(e, last);
            last = e;
        }
    }

    /// with arbitrary funding, earned never exceeds what was funded and is always fully withdrawable
    function testFuzz_neverExceedsFunding(uint256 deposit, uint256 r1, uint256 r2, uint32 dt) public {
        deposit = bound(deposit, 1, 1e15);
        r1 = bound(r1, 1, MAX_RATE);
        r2 = bound(r2, 1, MAX_RATE);
        fund(deposit);
        uint256 a = stream(alice, r1);
        uint256 b = stream(bob, r2);
        vm.warp(block.timestamp + dt);
        uint256 ea = payroll.earned(a);
        uint256 eb = payroll.earned(b);
        assertLe(ea + eb, deposit);
        assertLe(ea + eb + payroll.unallocated(), usd.balanceOf(address(payroll)));
        if (ea > 0) {
            vm.prank(alice);
            assertEq(payroll.withdraw(a), ea);
        }
        if (eb > 0) {
            vm.prank(bob);
            assertEq(payroll.withdraw(b), eb);
        }
    }

    /// top-ups after running dry resume streaming without paying for the dry period
    function testFuzz_dryThenTopUp(uint256 deposit, uint256 rateX, uint32 dry, uint32 later) public {
        rateX = bound(rateX, 1e15, MAX_RATE);
        deposit = bound(deposit, 1, 1e12);
        fund(deposit);
        uint256 id = stream(alice, rateX);
        uint256 runway = (deposit * SCALE) / rateX;
        vm.warp(block.timestamp + runway + 1 + dry);
        uint256 e = payroll.earned(id);
        assertLe(e, deposit);
        fund(1e24);
        later = uint32(bound(later, 0, 365 days));
        vm.warp(block.timestamp + later);
        uint256 expected = e + (rateX * later) / SCALE;
        assertApproxEqAbs(payroll.earned(id), expected, 1);
    }
}

contract BatchFuzzTest is BaseTest {
    address[5] internal workers;

    function setUp() public override {
        super.setUp();
        address[] memory assets = new address[](1);
        assets[0] = address(aapl);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        for (uint256 i; i < 5; ++i) {
            workers[i] = address(uint160(0x1000 + i));
            vm.prank(workers[i]);
            slice.setSlice(10_000, assets, w);
        }
    }

    /// batch conversion credits each worker exactly floor(in_i * out / in); total never exceeds output
    function testFuzz_batchExactShares(uint256[5] memory amounts, uint256 skim, uint256 chunk) public {
        skim = bound(skim, 0, 99); // within max slippage of 1%
        router.setSkim(skim);
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            amounts[i] = bound(amounts[i], 0, 1e12);
            if (amounts[i] == 0) continue;
            usd.mint(address(this), amounts[i]);
            usd.approve(address(converter), amounts[i]);
            converter.deposit(workers[i], amounts[i]);
            total += amounts[i];
        }
        vm.assume(total > 0);
        vm.warp(block.timestamp + 7 days);
        usdFeed.set(1e8, block.timestamp);
        aaplFeed.set(250e8, block.timestamp);
        chunk = chunk % 2 == 0 ? 0 : bound(chunk, total / 8 + 1, total); // 0 = all at once
        vm.startPrank(keeper);
        while (true) {
            (,,,,, bool fin,) = converter.batches(0, address(aapl));
            if (fin) break;
            converter.executeBatch(0, address(aapl), chunk, 0, block.timestamp);
        }
        vm.stopPrank();
        (uint256 totalIn,,, uint256 totalOut,,,) = converter.batches(0, address(aapl));
        assertEq(totalIn, total);
        uint256 paid;
        for (uint256 i; i < 5; ++i) {
            if (amounts[i] == 0) continue;
            uint256 expected = (amounts[i] * totalOut) / totalIn;
            uint256 got = converter.claim(0, address(aapl), workers[i]);
            assertEq(got, expected);
            assertEq(aapl.balanceOf(workers[i]), expected);
            paid += got;
        }
        assertLe(paid, totalOut);
        assertLt(totalOut - paid, 5); // dust < number of workers
    }
}
