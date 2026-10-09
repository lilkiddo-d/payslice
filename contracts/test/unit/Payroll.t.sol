// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {Payroll} from "../../src/Payroll.sol";
import {PayrollFactory} from "../../src/PayrollFactory.sol";
import {RevertingConverter, FeeOnTransferERC20} from "../mocks/Mocks.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract PayrollTest is BaseTest {
    uint256 internal constant MONTH = 30 days;
    uint256 internal salaryRate; // 3,000 tUSD / 30 days

    event Payslip(
        uint256 indexed streamId,
        address indexed worker,
        uint64 periodStart,
        uint64 periodEnd,
        uint256 earned,
        uint256 cumulativeEarned,
        uint256 cumulativeWithdrawn
    );
    event LowRunway(uint256 runwaySeconds, uint256 thresholdSeconds);
    event RanDry(uint64 depletedAt);

    function setUp() public override {
        super.setUp();
        salaryRate = rateFor(3_000e6, MONTH);
    }

    // ------------------------------------------------------------------ init & factory

    function test_init() public view {
        assertEq(payroll.employer(), employer);
        assertEq(address(payroll.token()), address(usd));
        assertEq(payroll.name(), "Acme Inc");
        assertEq(payroll.warnDays(), 14);
        assertEq(address(payroll.factory()), address(factory));
        assertTrue(factory.isPayroll(address(payroll)));
        assertEq(factory.payrollCount(), 1);
        assertEq(factory.payrollsOf(employer)[0], address(payroll));
        assertEq(factory.payrolls(0, 10).length, 1);
        assertEq(factory.payrolls(5, 10).length, 0);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        payroll.initialize(alice, address(usd), "x");
    }

    function test_implementationLocked() public {
        Payroll impl = Payroll(factory.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(alice, address(usd), "x");
    }

    function test_createPayroll_tokenNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(PayrollFactory.TokenNotAllowed.selector, address(aapl)));
        factory.createPayroll(address(aapl), "x");
    }

    // ------------------------------------------------------------------ funding

    function test_deposit_takesFeeToCollector() public {
        fund(100_000e6);
        uint256 fee = (100_000e6 * 50) / 10_000;
        assertEq(usd.balanceOf(address(fees)), fee);
        assertEq(fees.treasuryBalance(address(usd)), fee);
        assertEq(payroll.unallocated(), 100_000e6 - fee);
        assertEq(payroll.totalDeposited(), 100_000e6 - fee);
        assertEq(payroll.totalFeesPaid(), fee);
        fees.sweep(address(usd));
        assertEq(usd.balanceOf(treasury), fee);
        fees.sweep(address(usd)); // no-op
    }

    function test_deposit_zeroReverts() public {
        vm.prank(employer);
        vm.expectRevert(Payroll.ZeroAmount.selector);
        payroll.deposit(0);
    }

    function test_deposit_anyoneCanFund() public {
        usd.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usd.approve(address(payroll), 1_000e6);
        payroll.deposit(1_000e6);
        vm.stopPrank();
        assertEq(payroll.unallocated(), netOf(1_000e6));
    }

    function test_withdrawUnallocated() public {
        fund(10_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 10 days);
        uint256 free = payroll.unallocated();
        vm.prank(employer);
        vm.expectRevert(Payroll.InsufficientUnallocated.selector);
        payroll.withdrawUnallocated(free + 1, employer);

        uint256 before = usd.balanceOf(employer);
        vm.prank(employer);
        payroll.withdrawUnallocated(free, employer);
        assertEq(usd.balanceOf(employer) - before, free);
        // worker's 10 days of pay is untouched
        assertApproxEqAbs(payroll.earned(id), 1_000e6, 1);
        vm.prank(alice);
        payroll.withdraw(id);
        assertApproxEqAbs(usd.balanceOf(alice), 1_000e6, 1);
    }

    function test_withdrawUnallocated_guards() public {
        fund(1_000e6);
        vm.startPrank(employer);
        vm.expectRevert(Payroll.ZeroAddress.selector);
        payroll.withdrawUnallocated(1, address(0));
        vm.expectRevert(Payroll.ZeroAmount.selector);
        payroll.withdrawUnallocated(0, employer);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(Payroll.NotEmployer.selector);
        payroll.withdrawUnallocated(1, alice);
    }

    // ------------------------------------------------------------------ streaming

    function test_accruesPerSecond() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 1);
        assertEq(payroll.earned(id), salaryRate / SCALE);
        vm.warp(block.timestamp + MONTH - 1);
        assertApproxEqAbs(payroll.earned(id), 3_000e6, 1);
        assertEq(payroll.withdrawable(id), payroll.earned(id));
    }

    function test_withdraw_paysWorker() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        uint256 amt = payroll.withdraw(id);
        assertApproxEqAbs(amt, 1_500e6, 1);
        assertEq(usd.balanceOf(alice), amt);
        assertEq(payroll.withdrawable(id), 0);
        vm.prank(alice);
        vm.expectRevert(Payroll.NothingToWithdraw.selector);
        payroll.withdraw(id);
        assertEq(payroll.totalWithdrawnByWorkers(), amt);
    }

    function test_withdraw_onlyWorker() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vm.expectRevert(Payroll.NotWorker.selector);
        payroll.withdraw(id);
    }

    function test_withdraw_autoHarvestByAnyone() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.prank(alice);
        slice.setAutoHarvest(true);
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        uint256 amt = payroll.withdraw(id);
        assertEq(usd.balanceOf(alice), amt); // funds always go to the worker
        assertEq(usd.balanceOf(keeper), 0);
    }

    function test_withdraw_withSlice_queuesConversion() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(spy);
        uint16[] memory w = new uint16[](2);
        w[0] = 5000;
        w[1] = 5000;
        vm.prank(alice);
        slice.setSlice(3000, assets, w);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        uint256 amt = payroll.withdraw(id);
        uint256 slicePart = (amt * 3000) / 10_000;
        assertEq(usd.balanceOf(alice), amt - slicePart);
        assertEq(usd.balanceOf(address(converter)), slicePart);
        uint256 e = converter.currentEpoch();
        assertEq(converter.userIn(e, address(aapl), alice) + converter.userIn(e, address(spy), alice), slicePart);
    }

    function test_withdraw_sliceFallbackWhenConverterReverts() public {
        RevertingConverter bad = new RevertingConverter(address(usd));
        vm.prank(admin);
        factory.setBatchConverter(address(bad));
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        address[] memory assets = new address[](1);
        assets[0] = address(aapl);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        vm.prank(alice);
        slice.setSlice(10_000, assets, w);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 amt = payroll.withdraw(id);
        assertEq(usd.balanceOf(alice), amt); // all paid in stablecoin
    }

    function test_withdraw_noSliceWhenConverterInputDiffers() public {
        address other = address(new RevertingConverter(address(aapl)));
        vm.prank(admin);
        factory.setBatchConverter(other);
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        address[] memory assets = new address[](1);
        assets[0] = address(aapl);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        vm.prank(alice);
        slice.setSlice(5_000, assets, w);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 amt = payroll.withdraw(id);
        assertEq(usd.balanceOf(alice), amt);
    }

    function test_withdraw_noRouterConfigured() public {
        vm.startPrank(admin);
        factory.setSliceRouter(address(0));
        vm.stopPrank();
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vm.expectRevert(Payroll.NotWorker.selector);
        payroll.withdraw(id);
        vm.prank(alice);
        uint256 amt = payroll.withdraw(id);
        assertEq(usd.balanceOf(alice), amt);
    }

    function test_withdraw_notBlockedByProtocolPause() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        factory.pause();
        vm.prank(alice);
        uint256 amt = payroll.withdraw(id);
        assertGt(amt, 0);
        // but funding / stream creation are blocked
        vm.prank(employer);
        vm.expectRevert(Payroll.ProtocolPaused.selector);
        payroll.deposit(1e6);
        vm.prank(employer);
        vm.expectRevert(Payroll.ProtocolPaused.selector);
        payroll.createStream(bob, salaryRate, 0, 0, 0);
        vm.prank(guardian);
        factory.unpause();
        fund(1e6);
    }

    function test_createStream_validation() public {
        vm.startPrank(employer);
        vm.expectRevert(Payroll.ZeroAddress.selector);
        payroll.createStream(address(0), 1, 0, 0, 0);
        vm.expectRevert(Payroll.InvalidRate.selector);
        payroll.createStream(alice, 0, 0, 0, 0);
        vm.expectRevert(Payroll.InvalidRate.selector);
        payroll.createStream(alice, 1e45 + 1, 0, 0, 0);
        uint64 nowT = uint64(block.timestamp);
        vm.expectRevert(Payroll.InvalidSchedule.selector);
        payroll.createStream(alice, 1, nowT - 1, 0, 0);
        vm.expectRevert(Payroll.InvalidSchedule.selector);
        payroll.createStream(alice, 1, nowT + 10, nowT + 10, 0);
        vm.expectRevert(Payroll.InvalidSchedule.selector);
        payroll.createStream(alice, 1, nowT + 10, 0, nowT + 5);
        vm.expectRevert(Payroll.InvalidSchedule.selector);
        payroll.createStream(alice, 1, nowT + 10, nowT + 20, nowT + 30);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(Payroll.NotEmployer.selector);
        payroll.createStream(alice, 1, 0, 0, 0);
    }

    function test_createStream_compliance() public {
        vm.prank(admin);
        compliance.setEnabled(true);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Payroll.NotAllowed.selector, alice));
        payroll.createStream(alice, 1, 0, 0, 0);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(admin);
        compliance.setAllowlist(list, true);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Payroll.NotAllowed.selector, employer));
        payroll.createStream(alice, 1, 0, 0, 0);
        list[0] = employer;
        vm.prank(admin);
        compliance.setAllowlist(list, true);
        vm.prank(employer);
        payroll.createStream(alice, 1, 0, 0, 0);
        assertEq(factory.workerPayrolls(alice)[0], address(payroll));
    }

    function test_futureStart_and_end() public {
        fund(100_000e6);
        uint64 start = uint64(block.timestamp + 5 days);
        uint64 end = start + 10 days;
        vm.prank(employer);
        uint256 id = payroll.createStream(alice, salaryRate, start, end, 0);
        vm.warp(start);
        assertEq(payroll.earned(id), 0);
        vm.warp(end + 20 days);
        assertApproxEqAbs(payroll.earned(id), 1_000e6, 1);
        // syncing releases the over-reservation and uncounts the stream
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        payroll.syncStreams(ids);
        assertEq(payroll.totalRateX(), 0);
        assertApproxEqAbs(payroll.unallocated(), netOf(100_000e6) - 1_000e6, 1);
    }

    function test_cliff() public {
        fund(100_000e6);
        uint64 cliff = uint64(block.timestamp + 10 days);
        vm.prank(employer);
        uint256 id = payroll.createStream(alice, salaryRate, 0, 0, cliff);
        vm.warp(block.timestamp + 5 days);
        assertEq(payroll.withdrawable(id), 0);
        assertGt(payroll.earned(id), 0);
        vm.prank(alice);
        vm.expectRevert(Payroll.CliffNotReached.selector);
        payroll.withdraw(id);
        vm.warp(cliff);
        vm.prank(alice);
        uint256 amt = payroll.withdraw(id);
        assertApproxEqAbs(amt, 1_000e6, 1);
    }

    function test_reduceCliff() public {
        uint64 cliff = uint64(block.timestamp + 10 days);
        vm.startPrank(employer);
        uint256 id = payroll.createStream(alice, salaryRate, 0, 0, cliff);
        vm.expectRevert(Payroll.InvalidSchedule.selector);
        payroll.reduceCliff(id, cliff + 1);
        payroll.reduceCliff(id, cliff - 1 days);
        assertEq(payroll.getStream(id).cliff, cliff - 1 days);
        payroll.reduceCliff(id, 0);
        vm.expectRevert(Payroll.InvalidSchedule.selector);
        payroll.reduceCliff(id, 0);
        vm.stopPrank();
    }

    function test_cancel_waivesCliff_keepsEarned() public {
        fund(100_000e6);
        uint64 cliff = uint64(block.timestamp + 30 days);
        vm.prank(employer);
        uint256 id = payroll.createStream(alice, salaryRate, 0, 0, cliff);
        vm.warp(block.timestamp + 10 days);
        uint256 earnedBefore = payroll.earned(id);
        vm.prank(employer);
        payroll.cancelStream(id);
        assertEq(payroll.earned(id), earnedBefore);
        vm.warp(block.timestamp + 10 days);
        assertEq(payroll.earned(id), earnedBefore); // no further accrual
        vm.prank(alice);
        assertEq(payroll.withdraw(id), earnedBefore);
        vm.prank(employer);
        vm.expectRevert(Payroll.StreamIsCancelled.selector);
        payroll.cancelStream(id);
        vm.prank(employer);
        vm.expectRevert(Payroll.StreamIsCancelled.selector);
        payroll.updateStream(id, 1, 0);
        // released funds are back with the employer
        assertApproxEqAbs(payroll.unallocated(), netOf(100_000e6) - earnedBefore, 1);
    }

    function test_pause_resume() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 10 days);
        vm.prank(employer);
        payroll.pauseStream(id);
        uint256 e = payroll.earned(id);
        vm.warp(block.timestamp + 10 days);
        assertEq(payroll.earned(id), e);
        vm.prank(employer);
        vm.expectRevert(Payroll.StreamNotActive.selector);
        payroll.pauseStream(id);
        vm.prank(employer);
        payroll.resumeStream(id);
        vm.prank(employer);
        vm.expectRevert(Payroll.StreamNotPaused.selector);
        payroll.resumeStream(id);
        vm.warp(block.timestamp + 10 days);
        assertApproxEqAbs(payroll.earned(id), 2_000e6, 2);
    }

    function test_resume_afterEndDoesNotRecount() public {
        fund(100_000e6);
        uint64 end = uint64(block.timestamp + 5 days);
        vm.prank(employer);
        uint256 id = payroll.createStream(alice, salaryRate, 0, end, 0);
        vm.prank(employer);
        payroll.pauseStream(id);
        vm.warp(end + 1);
        vm.prank(employer);
        payroll.resumeStream(id);
        assertEq(payroll.totalRateX(), 0);
    }

    function test_update_rate_preservesEarned() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 10 days);
        uint256 e = payroll.earned(id);
        vm.prank(employer);
        payroll.updateStream(id, salaryRate * 2, 0);
        assertEq(payroll.earned(id), e);
        vm.warp(block.timestamp + 10 days);
        assertApproxEqAbs(payroll.earned(id), e + 2_000e6, 2);
        assertEq(payroll.totalRateX(), salaryRate * 2);
    }

    function test_update_validation() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(employer);
        vm.expectRevert(Payroll.InvalidRate.selector);
        payroll.updateStream(id, 0, 0);
        vm.expectRevert(Payroll.InvalidSchedule.selector);
        payroll.updateStream(id, salaryRate, uint64(block.timestamp - 1));
        vm.expectRevert(Payroll.UnknownStream.selector);
        payroll.updateStream(99, salaryRate, 0);
        vm.stopPrank();
    }

    function test_update_extendEndedStream() public {
        fund(100_000e6);
        uint64 end = uint64(block.timestamp + 5 days);
        vm.prank(employer);
        uint256 id = payroll.createStream(alice, salaryRate, 0, end, 0);
        vm.warp(end + 5 days);
        vm.prank(employer);
        payroll.updateStream(id, salaryRate, uint64(block.timestamp + 10 days));
        assertApproxEqAbs(payroll.earned(id), 500e6, 1); // nothing for the gap after the old end
        vm.warp(block.timestamp + 10 days);
        assertApproxEqAbs(payroll.earned(id), 1_500e6, 2);
    }

    function test_update_pausedStreamStaysUncounted() public {
        fund(100_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.startPrank(employer);
        payroll.pauseStream(id);
        payroll.updateStream(id, salaryRate * 3, 0);
        vm.stopPrank();
        assertEq(payroll.totalRateX(), 0);
    }

    // ------------------------------------------------------------------ solvency

    function test_runsDry_autoPauses_noNegativeBalance() public {
        fund(1_000e6);
        uint256 net = netOf(1_000e6);
        uint256 id = stream(alice, salaryRate); // 100/day
        vm.warp(block.timestamp + 30 days);
        assertTrue(payroll.isInsolvent());
        assertEq(payroll.runwaySeconds(), 0);
        uint256 e = payroll.earned(id);
        assertLe(e, net);
        assertApproxEqAbs(e, net, 1);
        vm.prank(alice);
        payroll.withdraw(id);
        assertTrue(payroll.insolvent());
        assertLe(usd.balanceOf(alice), net);
    }

    function test_insolvency_gapIsNotBackfilled() public {
        fund(1_000e6); // ~9.95 days at 100/day
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 20 days);
        uint256 atDry = payroll.earned(id);
        fund(10_000e6); // resume now
        assertFalse(payroll.insolvent());
        assertEq(payroll.gapCount(), 1);
        assertEq(payroll.earned(id), atDry);
        vm.warp(block.timestamp + 10 days);
        assertApproxEqAbs(payroll.earned(id), atDry + 1_000e6, 2);
        // second dry spell -> second gap
        vm.warp(block.timestamp + 200 days);
        fund(1_000e6);
        assertEq(payroll.gapCount(), 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        payroll.syncStreams(ids);
    }

    function test_insolvency_resumeByCancellingRelease() public {
        fund(1_000e6);
        uint256 id1 = stream(alice, salaryRate);
        uint256 id2 = stream(bob, salaryRate);
        vm.warp(block.timestamp + 20 days);
        vm.prank(employer);
        payroll.cancelStream(id2);

        vm.prank(employer);
        payroll.pauseStream(id1);
        assertFalse(payroll.insolvent()); // rate is 0 -> resumes
    }

    function test_lowRunwayEvent() public {
        fund(1_000e6);
        vm.expectEmit(false, false, false, false, address(payroll));
        emit LowRunway(0, 0);
        stream(alice, salaryRate);
        assertTrue(payroll.isLowRunway());
        vm.prank(employer);
        payroll.setWarnDays(0);
        assertFalse(payroll.isLowRunway());
        vm.prank(employer);
        vm.expectRevert(Payroll.InvalidWarnDays.selector);
        payroll.setWarnDays(366);
        assertEq(payroll.burnRateX(), salaryRate);
    }

    function test_runway_noStreams() public {
        fund(1_000e6);
        assertEq(payroll.runwaySeconds(), type(uint256).max);
    }

    // ------------------------------------------------------------------ payslips

    function test_payslip_emittedPerMonth() public {
        fund(1_000_000e6);
        uint256 id = stream(alice, salaryRate);
        // T0 is 2026-10-05; Nov 1 2026 00:00 UTC = 1793491200
        uint64 nov1 = 1_793_491_200;
        vm.warp(nov1 + 1 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 expectedOct = ((nov1 - T0) * salaryRate) / SCALE;
        vm.expectEmit(true, true, false, true, address(payroll));
        emit Payslip(id, alice, uint64(1_790_812_800), nov1, expectedOct, expectedOct, 0);
        payroll.syncStreams(ids);
    }

    function test_payslip_catchUpAfterLongIdle() public {
        fund(5_000_000e6);
        uint256 id = stream(alice, salaryRate);
        vm.warp(block.timestamp + 3 * 365 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        payroll.syncStreams(ids);
        assertApproxEqAbs(payroll.earned(id), (3 * 365 days * salaryRate) / SCALE, 1);
        Payroll.Stream memory s = payroll.getStream(id);
        assertEq(s.checkpoint, block.timestamp);
    }

    function test_syncStreams_batchLimit() public {
        uint256[] memory ids = new uint256[](51);
        vm.expectRevert(Payroll.BatchTooLarge.selector);
        payroll.syncStreams(ids);
    }

    // ------------------------------------------------------------------ admin bits

    function test_transferEmployer() public {
        vm.prank(employer);
        vm.expectRevert(Payroll.ZeroAddress.selector);
        payroll.transferEmployer(address(0));
        vm.prank(employer);
        payroll.transferEmployer(bob);
        vm.prank(carol);
        vm.expectRevert(Payroll.NotPendingEmployer.selector);
        payroll.acceptEmployer();
        vm.prank(bob);
        payroll.acceptEmployer();
        assertEq(payroll.employer(), bob);
        assertEq(factory.payrollsOf(bob)[0], address(payroll));
    }

    function test_factoryHooksOnlyFromPayroll() public {
        vm.expectRevert(PayrollFactory.NotPayroll.selector);
        factory.onStreamCreated(alice);
        vm.expectRevert(PayrollFactory.NotPayroll.selector);
        factory.onEmployerTransferred(alice, bob);
    }

    function test_feeDiscountForStakers() public {
        MockERC20Like slce = MockERC20Like(address(new SlceMock()));
        vm.startPrank(admin);
        hooks.setProjectToken(address(slce));
        uint256[] memory th = new uint256[](1);
        th[0] = 1_000e18;
        uint256[] memory d = new uint256[](1);
        d[0] = 5_000;
        hooks.setTiers(th, d);
        vm.stopPrank();
        SlceMock(address(slce)).mint(employer, 1_000e18);
        vm.startPrank(employer);
        SlceMock(address(slce)).approve(address(hooks), 1_000e18);
        hooks.stake(1_000e18);
        vm.stopPrank();
        assertEq(factory.effectiveFeeBps(employer), 25);
        assertEq(factory.effectiveFeeBps(alice), 50);
    }

    function test_feeOnTransferToken() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        vm.prank(admin);
        factory.setAllowedToken(address(fot), true);
        vm.prank(employer);
        Payroll p = Payroll(factory.createPayroll(address(fot), "FOT"));
        fot.mint(employer, 1_000e6);
        vm.startPrank(employer);
        fot.approve(address(p), 1_000e6);
        p.deposit(1_000e6);
        vm.stopPrank();
        // accounting uses the received amount, never more than the real balance
        assertLe(p.unallocated(), fot.balanceOf(address(p)));
    }

    function test_unknownStreamViews() public view {
        assertEq(payroll.withdrawable(42), 0);
        assertEq(payroll.earned(42), 0);
        assertEq(payroll.streamsOf(alice).length, 0);
    }
}

interface MockERC20Like {
    function mint(address, uint256) external;
}

import {MockERC20} from "../mocks/Mocks.sol";

contract SlceMock is MockERC20 {
    constructor() MockERC20("Mock SLCE", "mSLCE", 18) {}
}
