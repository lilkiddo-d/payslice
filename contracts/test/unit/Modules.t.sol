// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {DexAdapter} from "../../src/adapters/DexAdapter.sol";
import {BonusVesting} from "../../src/BonusVesting.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {PayrollFactory} from "../../src/PayrollFactory.sol";
import {Timelock} from "../../src/Timelock.sol";
import {IFeeCollector} from "../../src/interfaces/IPayslice.sol";
import {DateTimeLib} from "../../src/libraries/DateTimeLib.sol";
import {MockERC20, MockAggregator} from "../mocks/Mocks.sol";

contract MarketClockTest is BaseTest {
    function test_regularSession_edt() public view {
        // Monday 2026-10-05 (EDT, UTC-4): open 13:30-20:00 UTC
        assertFalse(clock.isOpenAt(1_791_206_940)); // 13:29
        assertTrue(clock.isOpenAt(1_791_207_000)); // 13:30
        assertTrue(clock.isOpenAt(1_791_230_399)); // 19:59:59
        assertFalse(clock.isOpenAt(1_791_230_400)); // 20:00
        assertTrue(clock.isMarketOpen()); // T0 = 14:00 UTC
    }

    function test_weekend_closed() public view {
        assertFalse(clock.isOpenAt(T0 + 5 days)); // Saturday
        assertFalse(clock.isOpenAt(T0 + 6 days)); // Sunday
        assertTrue(clock.isOpenAt(T0 + 7 days)); // Monday
    }

    function test_est_winter() public view {
        // Monday 2026-01-05 15:00 UTC = 10:00 EST
        assertTrue(clock.isOpenAt(1_767_625_200));
        assertFalse(clock.isOpenAt(1_767_625_200 - 1 hours - 1)); // 08:59:59 EST
    }

    function test_dstBoundaries() public pure {
        assertFalse(DateTimeLib.isUsEasternDst(1_772_953_140)); // 2026-03-08 06:59 UTC
        assertTrue(DateTimeLib.isUsEasternDst(1_772_953_200)); // 07:00 UTC
        assertTrue(DateTimeLib.isUsEasternDst(1_793_512_740)); // 2026-11-01 05:59 UTC
        assertFalse(DateTimeLib.isUsEasternDst(1_793_512_800)); // 06:00 UTC
    }

    function test_dateLib() public pure {
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.daysToDate(uint256(1_709_208_000) / 86_400);
        assertEq(y, 2024);
        assertEq(m, 2);
        assertEq(d, 29);
        assertEq(DateTimeLib.monthStart(1_793_491_199), 1_790_812_800);
        assertEq(DateTimeLib.nextMonthStart(1_793_491_199), 1_793_491_200);
        // December -> January rollover
        assertEq(DateTimeLib.nextMonthStart(1_798_210_800), DateTimeLib.daysFromDate(2027, 1, 1) * 86_400);
        assertEq(DateTimeLib.dayOfWeek(T0), 1); // Monday
    }

    function test_holidays_and_modes() public {
        uint256[] memory days_ = new uint256[](1);
        days_[0] = clock.dayIndex(2026, 12, 25);
        vm.prank(guardian);
        clock.setHolidays(days_, true);
        assertFalse(clock.isOpenAt(1_798_210_800)); // Fri 2026-12-25 10:00 EST
        vm.prank(guardian);
        vm.expectRevert();
        clock.setHolidays(days_, false); // guardian can't reopen
        vm.prank(admin);
        clock.setHolidays(days_, false);
        assertTrue(clock.isOpenAt(1_798_210_800));
        vm.prank(admin);
        vm.expectRevert(MarketClock.BatchTooLarge.selector);
        clock.setHolidays(new uint256[](31), true);

        vm.prank(guardian);
        clock.setMode(MarketClock.Mode.ForceClosed);
        assertFalse(clock.isMarketOpen());
        vm.prank(guardian);
        vm.expectRevert();
        clock.setMode(MarketClock.Mode.ForceOpen);
        vm.prank(admin);
        clock.setMode(MarketClock.Mode.ForceOpen);
        assertTrue(clock.isOpenAt(T0 + 5 days));
        vm.prank(admin);
        clock.setMode(MarketClock.Mode.Auto);
        assertTrue(clock.isMarketOpen());
    }

    function test_constructor() public {
        vm.expectRevert(MarketClock.ZeroAddress.selector);
        new MarketClock(address(0), guardian);
    }
}

contract OracleAdapterTest is BaseTest {
    function test_price_scaling() public view {
        assertEq(oracle.getPrice(address(aapl)), 250e18);
        assertEq(oracle.getPrice(address(usd)), 1e18);
        assertTrue(oracle.hasFeed(address(aapl)));
        assertFalse(oracle.hasFeed(address(bob)));
    }

    function test_stale() public {
        vm.warp(block.timestamp + 1 days + 1 hours + 1);
        vm.expectRevert();
        oracle.getPrice(address(aapl));
    }

    function test_futureTimestamp() public {
        aaplFeed.set(250e8, block.timestamp + 10);
        vm.expectRevert();
        oracle.getPrice(address(aapl));
    }

    function test_invalidAnswers() public {
        aaplFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(aapl)));
        oracle.getPrice(address(aapl));
        aaplFeed.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(aapl)));
        oracle.getPrice(address(aapl));
        aaplFeed.set(1e8, block.timestamp);
        aaplFeed.setRounds(5, 4);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(aapl)));
        oracle.getPrice(address(aapl));
    }

    function test_depeg() public {
        usdFeed.set(0.98e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.Depegged.selector, address(usd), 0.98e18));
        oracle.getPrice(address(usd));
        usdFeed.set(1.005e8, block.timestamp);
        assertEq(oracle.getPrice(address(usd)), 1.005e18);
    }

    function test_noFeed_disabled() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, bob));
        oracle.getPrice(bob);
        vm.prank(guardian);
        oracle.setFeedDisabled(address(aapl), true);
        assertFalse(oracle.hasFeed(address(aapl)));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FeedIsDisabled.selector, address(aapl)));
        oracle.getPrice(address(aapl));
        vm.prank(guardian);
        vm.expectRevert();
        oracle.setFeedDisabled(address(aapl), false);
        vm.prank(admin);
        oracle.setFeedDisabled(address(aapl), false);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, bob));
        oracle.setFeedDisabled(bob, true);
    }

    function test_sequencerFeed() public {
        MockAggregator seq = new MockAggregator(0, 0);
        vm.prank(admin);
        oracle.setSequencerFeed(address(seq));
        vm.expectRevert(OracleAdapter.SequencerDown.selector); // within grace period
        oracle.getPrice(address(aapl));
        vm.warp(block.timestamp + 2 hours);
        aaplFeed.set(250e8, block.timestamp);
        assertEq(oracle.getPrice(address(aapl)), 250e18);
        seq.set(1, block.timestamp);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(aapl));
    }

    function test_setFeed_guards() public {
        vm.startPrank(admin);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        oracle.setFeed(address(0), address(aaplFeed), 1, 0);
        vm.expectRevert(OracleAdapter.BadParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), 0, 0);
        vm.expectRevert(OracleAdapter.BadParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), 4 days, 0);
        vm.expectRevert(OracleAdapter.BadParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), 1 days, 1001);
        MockAggregator weird = new MockAggregator(19, 1);
        vm.expectRevert(OracleAdapter.BadParam.selector);
        oracle.setFeed(address(aapl), address(weird), 1 days, 0);
        vm.stopPrank();
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(address(0), guardian);
    }
}

contract DexAdapterTest is BaseTest {
    function test_swap() public {
        usd.mint(address(this), 250e6);
        usd.approve(address(dex), 250e6);
        uint256 out = dex.swapExactIn(address(usd), address(aapl), 250e6, 1e18, block.timestamp, alice);
        assertEq(out, 1e18);
        assertEq(aapl.balanceOf(alice), 1e18);
        assertEq(usd.balanceOf(address(dex)), 0);
        assertTrue(dex.hasRoute(address(usd), address(aapl)));
        assertEq(dex.pathOf(address(usd), address(aapl)).length, 43);
    }

    function test_swap_guards() public {
        vm.expectRevert(DexAdapter.Expired.selector);
        dex.swapExactIn(address(usd), address(aapl), 1, 0, block.timestamp - 1, alice);
        vm.expectRevert(DexAdapter.ZeroAddress.selector);
        dex.swapExactIn(address(usd), address(aapl), 1, 0, block.timestamp, address(0));
        vm.expectRevert(DexAdapter.NoRoute.selector);
        dex.swapExactIn(address(aapl), address(usd), 1, 0, block.timestamp, alice);
        usd.mint(address(this), 250e6);
        usd.approve(address(dex), 250e6);
        vm.expectRevert();
        dex.swapExactIn(address(usd), address(aapl), 250e6, 1e18 + 1, block.timestamp, alice);
    }

    function test_setRoute_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(DexAdapter.BadPath.selector);
        dex.setRoute(address(usd), address(aapl), hex"00");
        vm.expectRevert(DexAdapter.BadPath.selector);
        dex.setRoute(address(usd), address(aapl), abi.encodePacked(address(spy), uint24(500), address(aapl)));
        vm.expectRevert(DexAdapter.BadPath.selector);
        dex.setRoute(address(usd), address(aapl), abi.encodePacked(address(usd), uint24(500), address(spy)));
        vm.expectRevert(DexAdapter.ZeroAddress.selector);
        dex.setRoute(address(0), address(aapl), "");
        // multi-hop is fine
        dex.setRoute(
            address(usd),
            address(aapl),
            abi.encodePacked(address(usd), uint24(500), address(spy), uint24(3000), address(aapl))
        );
        dex.setRoute(address(usd), address(aapl), "");
        assertFalse(dex.hasRoute(address(usd), address(aapl)));
        vm.stopPrank();
        vm.expectRevert(DexAdapter.ZeroAddress.selector);
        new DexAdapter(address(0), address(router));
    }
}

contract BonusVestingTest is BaseTest {
    function setUp() public override {
        super.setUp();
        aapl.mint(employer, 1_000e18);
        vm.prank(employer);
        aapl.approve(address(bonus), type(uint256).max);
    }

    function _grant(bool revocable) internal returns (uint256) {
        vm.prank(employer);
        return bonus.grant(alice, address(aapl), 100e18, 0, 90 days, 360 days, revocable);
    }

    function test_cliff_and_linear() public {
        uint256 id = _grant(true);
        vm.warp(block.timestamp + 89 days);
        assertEq(bonus.vested(id), 0);
        vm.prank(alice);
        vm.expectRevert(BonusVesting.NothingToClaim.selector);
        bonus.claim(id);
        vm.warp(block.timestamp + 1 days); // day 90
        assertEq(bonus.vested(id), 25e18);
        vm.prank(alice);
        assertEq(bonus.claim(id), 25e18);
        vm.warp(block.timestamp + 400 days);
        assertEq(bonus.claimableOf(id), 75e18);
        vm.prank(bob);
        vm.expectRevert(BonusVesting.NotWorker.selector);
        bonus.claim(id);
        vm.prank(alice);
        bonus.claim(id);
        assertEq(aapl.balanceOf(alice), 100e18);
        assertEq(bonus.grantsOfWorker(alice).length, 1);
        assertEq(bonus.grantsOfEmployer(employer).length, 1);
        assertEq(bonus.getGrant(id).claimed, 100e18);
    }

    function test_revoke_keepsVested() public {
        uint256 id = _grant(true);
        vm.warp(block.timestamp + 180 days);
        uint256 before = aapl.balanceOf(employer);
        vm.prank(bob);
        vm.expectRevert(BonusVesting.NotEmployer.selector);
        bonus.revoke(id);
        vm.prank(employer);
        bonus.revoke(id);
        assertEq(aapl.balanceOf(employer) - before, 50e18);
        vm.warp(block.timestamp + 365 days);
        assertEq(bonus.vested(id), 50e18);
        vm.prank(alice);
        assertEq(bonus.claim(id), 50e18);
        vm.prank(employer);
        vm.expectRevert(BonusVesting.AlreadyRevoked.selector);
        bonus.revoke(id);
    }

    function test_nonRevocable() public {
        uint256 id = _grant(false);
        vm.prank(employer);
        vm.expectRevert(BonusVesting.NotRevocable.selector);
        bonus.revoke(id);
    }

    function test_grant_guards() public {
        vm.startPrank(employer);
        vm.expectRevert(BonusVesting.ZeroAddress.selector);
        bonus.grant(address(0), address(aapl), 1, 0, 0, 1, true);
        vm.expectRevert(BonusVesting.ZeroAmount.selector);
        bonus.grant(alice, address(aapl), 0, 0, 0, 1, true);
        vm.expectRevert(abi.encodeWithSelector(BonusVesting.UnsupportedAsset.selector, address(usd)));
        bonus.grant(alice, address(usd), 1, 0, 0, 1, true);
        vm.expectRevert(BonusVesting.InvalidSchedule.selector);
        bonus.grant(alice, address(aapl), 1, 0, 0, 0, true);
        vm.expectRevert(BonusVesting.InvalidSchedule.selector);
        bonus.grant(alice, address(aapl), 1, 0, 2, 1, true);
        vm.expectRevert(BonusVesting.InvalidSchedule.selector);
        bonus.grant(alice, address(aapl), 1, 1, 0, 1, true);
        vm.stopPrank();
        vm.expectRevert(BonusVesting.UnknownGrant.selector);
        bonus.claim(7);
    }

    function test_compliance_and_pause() public {
        vm.startPrank(admin);
        bonus.setCompliance(address(compliance));
        compliance.setEnabled(true);
        vm.stopPrank();
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(BonusVesting.NotAllowed.selector, employer));
        bonus.grant(alice, address(aapl), 1, 0, 0, 1, true);
        address[] memory l = new address[](1);
        l[0] = employer;
        vm.prank(admin);
        compliance.setAllowlist(l, true);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(BonusVesting.NotAllowed.selector, alice));
        bonus.grant(alice, address(aapl), 1, 0, 0, 1, true);
        vm.prank(admin);
        compliance.setEnabled(false);

        vm.prank(guardian);
        bonus.pause();
        vm.prank(employer);
        vm.expectRevert();
        bonus.grant(alice, address(aapl), 1, 0, 0, 1, true);
        vm.prank(guardian);
        bonus.unpause();
        vm.prank(admin);
        bonus.setSliceRouter(address(slice));
        vm.prank(admin);
        vm.expectRevert(BonusVesting.ZeroAddress.selector);
        bonus.setSliceRouter(address(0));
        vm.expectRevert(BonusVesting.ZeroAddress.selector);
        new BonusVesting(address(0), guardian, address(slice));
    }

    function test_claimNotPausable() public {
        uint256 id = _grant(true);
        vm.warp(block.timestamp + 360 days);
        vm.prank(guardian);
        bonus.pause();
        vm.prank(alice);
        assertEq(bonus.claim(id), 100e18);
    }
}

contract ProjectTokenHooksTest is BaseTest {
    MockERC20 internal slce;

    function setUp() public override {
        super.setUp();
        slce = new MockERC20("Mock SLCE", "mSLCE", 18);
    }

    function test_disabledUntilSet() public {
        assertFalse(hooks.isActive());
        assertEq(hooks.feeDiscountBps(employer), 0);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.stake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.unstake(1);
    }

    function test_setProjectToken_onceByAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        hooks.setProjectToken(address(slce));
        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.setProjectToken(address(usd)); // reward token can't be the project token
        hooks.setProjectToken(address(slce));
        vm.expectRevert(ProjectTokenHooks.AlreadySet.selector);
        hooks.setProjectToken(address(aapl));
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.addRewardToken(address(slce));
        vm.stopPrank();
        assertTrue(hooks.isActive());
        vm.prank(guardian);
        hooks.pause();
        assertFalse(hooks.isActive());
        vm.prank(guardian);
        hooks.unpause();
    }

    function test_stake_lock_unstake_rewards() public {
        vm.prank(admin);
        hooks.setProjectToken(address(slce));
        slce.mint(alice, 300e18);
        slce.mint(bob, 100e18);
        vm.prank(alice);
        slce.approve(address(hooks), type(uint256).max);
        vm.prank(bob);
        slce.approve(address(hooks), type(uint256).max);

        // reward before anyone stakes is queued
        usd.mint(address(this), 100e6);
        usd.approve(address(hooks), type(uint256).max);
        hooks.notifyReward(address(usd), 40e6);
        assertEq(hooks.queuedRewards(address(usd)), 40e6);

        vm.prank(alice);
        hooks.stake(300e18); // flushes queue to alice
        vm.prank(bob);
        hooks.stake(100e18);
        hooks.notifyReward(address(usd), 40e6);
        hooks.notifyReward(address(usd), 0);
        assertApproxEqAbs(hooks.pendingReward(alice, address(usd)), 70e6, 1);
        assertApproxEqAbs(hooks.pendingReward(bob, address(usd)), 10e6, 1);

        vm.prank(bob);
        vm.expectRevert();
        hooks.unstake(100e18);
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        vm.expectRevert(ProjectTokenHooks.Insufficient.selector);
        hooks.unstake(101e18);
        vm.prank(bob);
        hooks.unstake(100e18);
        assertEq(slce.balanceOf(bob), 100e18);
        vm.prank(bob);
        hooks.claimRewards();
        assertApproxEqAbs(usd.balanceOf(bob), 10e6, 1);
        vm.prank(alice);
        hooks.claimRewards();
        assertApproxEqAbs(usd.balanceOf(alice), 70e6, 1);
        vm.prank(alice);
        hooks.claimRewards(); // nothing left
        vm.expectRevert(abi.encodeWithSelector(ProjectTokenHooks.NotRewardToken.selector, address(aapl)));
        hooks.notifyReward(address(aapl), 1);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.unstake(0);
        assertEq(hooks.rewardTokens().length, 1);
    }

    function test_tiers() public {
        vm.startPrank(admin);
        hooks.setProjectToken(address(slce));
        uint256[] memory th = new uint256[](2);
        uint256[] memory d = new uint256[](2);
        th[0] = 100e18;
        th[1] = 1_000e18;
        d[0] = 2_000;
        d[1] = 10_000;
        hooks.setTiers(th, d);
        (uint256[] memory t2,) = hooks.tiers();
        assertEq(t2.length, 2);
        d[1] = 1_000;
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        hooks.setTiers(th, d);
        d[1] = 10_001;
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        hooks.setTiers(th, d);
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        hooks.setTiers(new uint256[](5), new uint256[](5));
        hooks.setLockPeriod(1 days);
        vm.expectRevert(ProjectTokenHooks.BadParam.selector);
        hooks.setLockPeriod(31 days);
        vm.stopPrank();

        slce.mint(employer, 1_000e18);
        vm.startPrank(employer);
        slce.approve(address(hooks), type(uint256).max);
        hooks.stake(100e18);
        assertEq(hooks.feeDiscountBps(employer), 2_000);
        hooks.stake(900e18);
        assertEq(hooks.feeDiscountBps(employer), 10_000);
        vm.stopPrank();
        assertEq(factory.effectiveFeeBps(employer), 0);
    }

    function test_rewardTokenLimits() public {
        vm.startPrank(admin);
        hooks.addRewardToken(address(usd)); // dup no-op
        hooks.addRewardToken(address(aapl));
        hooks.addRewardToken(address(spy));
        hooks.addRewardToken(address(0xBEEF));
        vm.expectRevert(ProjectTokenHooks.TooMany.selector);
        hooks.addRewardToken(address(0xCAFE));
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        hooks.addRewardToken(address(0));
        vm.stopPrank();
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        new ProjectTokenHooks(address(0), guardian);
    }
}

contract FeeAndComplianceTest is BaseTest {
    function test_feeCollector_admin() public {
        vm.startPrank(admin);
        fees.setTreasury(bob);
        fees.setStakerShareBps(10_000);
        fees.setHooks(address(0));
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fees.setTreasury(address(0));
        vm.expectRevert(FeeCollector.BadParam.selector);
        fees.setStakerShareBps(10_001);
        vm.stopPrank();
        usd.mint(address(this), 10e6);
        usd.approve(address(fees), 10e6);
        fees.receiveFee(address(usd), 10e6, IFeeCollector.FeeKind.Conversion);
        fees.receiveFee(address(usd), 0, IFeeCollector.FeeKind.Conversion);
        assertEq(fees.treasuryBalance(address(usd)), 10e6);
        fees.sweep(address(usd));
        assertEq(usd.balanceOf(bob), 10e6);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(0), treasury, 0);
        vm.expectRevert(FeeCollector.BadParam.selector);
        new FeeCollector(admin, treasury, 10_001);
    }

    function test_compliance() public {
        assertTrue(compliance.isAllowed(alice));
        vm.prank(admin);
        compliance.setEnabled(true);
        assertFalse(compliance.isAllowed(alice));
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        compliance.setAllowlist(new address[](201), true);
        vm.prank(alice);
        vm.expectRevert();
        compliance.setEnabled(false);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0), admin);
    }

    function test_factory_admin() public {
        vm.startPrank(admin);
        vm.expectRevert(PayrollFactory.FeeTooHigh.selector);
        factory.setPayrollFeeBps(101);
        factory.setPayrollFeeBps(0);
        assertEq(factory.effectiveFeeBps(employer), 0);
        vm.expectRevert(PayrollFactory.ZeroAddress.selector);
        factory.setAllowedToken(address(0), true);
        vm.expectRevert(PayrollFactory.ZeroAddress.selector);
        factory.setFeeCollector(address(0));
        factory.setFeeCollector(address(fees));
        factory.setProjectHooks(address(0));
        factory.setPayrollFeeBps(10);
        assertEq(factory.effectiveFeeBps(employer), 10);
        factory.setCompliance(address(0));
        assertTrue(factory.isAllowed(alice));
        vm.stopPrank();
        vm.expectRevert(PayrollFactory.ZeroAddress.selector);
        new PayrollFactory(address(0), guardian, address(fees), 0);
        vm.expectRevert(PayrollFactory.FeeTooHigh.selector);
        new PayrollFactory(admin, guardian, address(fees), 101);
    }

    function test_factory_compliance_and_pause() public {
        vm.prank(admin);
        compliance.setEnabled(true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PayrollFactory.NotAllowed.selector, bob));
        factory.createPayroll(address(usd), "x");
        vm.prank(admin);
        compliance.setEnabled(false);
        vm.prank(guardian);
        factory.pause();
        vm.prank(bob);
        vm.expectRevert();
        factory.createPayroll(address(usd), "x");
    }

    function test_feeDiscount_hooksReverting() public {
        vm.prank(admin);
        factory.setProjectHooks(address(usd)); // not a hooks contract: call reverts -> full fee
        assertEq(factory.effectiveFeeBps(employer), 50);
    }
}

contract TimelockTest is BaseTest {
    function test_minDelay() public {
        address[] memory p = new address[](1);
        p[0] = admin;
        vm.expectRevert(Timelock.DelayTooShort.selector);
        new Timelock(1 days, p, p);
    }

    function test_adminChangesWait48h() public {
        address[] memory p = new address[](1);
        p[0] = admin;
        Timelock tl = new Timelock(48 hours, p, p);
        bytes32 role = factory.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        factory.grantRole(role, address(tl));

        bytes memory data = abi.encodeCall(PayrollFactory.setPayrollFeeBps, (20));
        vm.prank(admin);
        tl.schedule(address(factory), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.prank(admin);
        vm.expectRevert();
        tl.execute(address(factory), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        tl.execute(address(factory), 0, data, bytes32(0), bytes32(0));
        assertEq(factory.payrollFeeBps(), 20);
    }
}
