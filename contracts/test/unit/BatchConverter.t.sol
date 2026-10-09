// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {BatchConverter} from "../../src/BatchConverter.sol";
import {SliceRouter} from "../../src/SliceRouter.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract BatchConverterTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _setSlice(alice, 10_000, address(aapl), 10_000, address(0), 0);
        _setSlice(bob, 10_000, address(aapl), 5_000, address(spy), 5_000);
    }

    function _setSlice(address w, uint16 bps, address a1, uint16 w1, address a2, uint16 w2) internal {
        uint256 n = a2 == address(0) ? 1 : 2;
        address[] memory assets = new address[](n);
        uint16[] memory weights = new uint16[](n);
        assets[0] = a1;
        weights[0] = w1;
        if (n == 2) {
            assets[1] = a2;
            weights[1] = w2;
        }
        vm.prank(w);
        slice.setSlice(bps, assets, weights);
    }

    function _deposit(address worker, uint256 amount) internal {
        usd.mint(address(this), amount);
        usd.approve(address(converter), amount);
        converter.deposit(worker, amount);
    }

    function _nextEpochMarketOpen() internal {
        // advance one full epoch, then to the next weekday 10:00 NY
        vm.warp(block.timestamp + 7 days);
        while (!clock.isMarketOpen()) vm.warp(block.timestamp + 1 hours);
        usdFeed.set(1e8, block.timestamp);
        aaplFeed.set(250e8, block.timestamp);
        spyFeed.set(500e8, block.timestamp);
    }

    function test_deposit_splitsByWeight() public {
        _deposit(bob, 1_000e6);
        assertEq(converter.userIn(0, address(aapl), bob), 500e6);
        assertEq(converter.userIn(0, address(spy), bob), 500e6);
        (uint256 totalIn,,,,,,) = converter.batches(0, address(aapl));
        assertEq(totalIn, 500e6);
    }

    function test_deposit_guards() public {
        vm.expectRevert(BatchConverter.ZeroAddress.selector);
        converter.deposit(address(0), 1);
        vm.expectRevert(BatchConverter.ZeroAmount.selector);
        converter.deposit(alice, 0);
        vm.expectRevert(BatchConverter.NoAllocation.selector);
        converter.deposit(carol, 1);
        vm.prank(admin);
        dex.setRoute(address(usd), address(spy), "");
        usd.mint(address(this), 1e6);
        usd.approve(address(converter), 1e6);
        vm.expectRevert(abi.encodeWithSelector(BatchConverter.UnsupportedAsset.selector, address(spy)));
        converter.deposit(bob, 1e6);
        vm.prank(admin);
        compliance.setEnabled(true);
        vm.prank(admin);
        converter.setCompliance(address(compliance));
        vm.expectRevert(abi.encodeWithSelector(BatchConverter.NotAllowed.selector, alice));
        converter.deposit(alice, 1e6);
    }

    function test_fullFlow_exactProRata() public {
        _deposit(alice, 1_000e6);
        _deposit(bob, 3_000e6);
        _nextEpochMarketOpen();
        vm.prank(keeper);
        uint256 out = converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
        (uint256 totalIn, uint256 fee, uint256 executedIn, uint256 totalOut,, bool finalized,) =
            converter.batches(0, address(aapl));
        assertTrue(finalized);
        assertEq(totalIn, 2_500e6);
        assertEq(fee, (2_500e6 * 30) / 10_000);
        assertEq(executedIn, totalIn - fee);
        assertEq(totalOut, out);
        assertEq(out, ((totalIn - fee) * 1e18) / 250e6);

        uint256 aliceExpected = (1_000e6 * totalOut) / totalIn;
        uint256 bobExpected = (1_500e6 * totalOut) / totalIn;
        assertEq(converter.claimable(0, address(aapl), alice), aliceExpected);
        converter.claim(0, address(aapl), alice);
        converter.claim(0, address(aapl), bob);
        assertEq(aapl.balanceOf(alice), aliceExpected);
        assertEq(aapl.balanceOf(bob), bobExpected);
        assertLe(aliceExpected + bobExpected, totalOut);
        assertEq(converter.claimable(0, address(aapl), alice), 0);
        vm.expectRevert(BatchConverter.AlreadySettled.selector);
        converter.claim(0, address(aapl), alice);
        vm.expectRevert(BatchConverter.NothingToClaim.selector);
        converter.claim(0, address(aapl), carol);

        // conversion fee: 100% to treasury while token unset
        assertEq(fees.treasuryBalance(address(usd)), fee);
    }

    function test_execute_guards() public {
        _deposit(alice, 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(BatchConverter.EpochNotClosed.selector);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);

        bytes32 role = converter.KEEPER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);

        vm.warp(block.timestamp + 7 days); // Monday 14:00 UTC -> next Monday 14:00 (open)
        vm.prank(keeper);
        vm.expectRevert(BatchConverter.Expired.selector);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp - 1);

        vm.prank(keeper);
        vm.expectRevert(BatchConverter.NothingToExecute.selector);
        converter.executeBatch(0, address(spy), 0, 0, block.timestamp + 60);

        vm.prank(guardian);
        clock.setMode(MarketClock.Mode.ForceClosed);
        vm.prank(keeper);
        vm.expectRevert(BatchConverter.MarketClosed.selector);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
    }

    function test_execute_oracleFloorBlocksSandwich() public {
        _deposit(alice, 1_000e6);
        _nextEpochMarketOpen();
        router.setSkim(200); // pool gives 2% less than oracle (max slippage is 1%)
        vm.prank(keeper);
        vm.expectRevert(); // router reverts "Too little received"
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
        router.setSkim(50); // 0.5% worse: within bounds
        vm.prank(keeper);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
    }

    function test_execute_keeperMinOutTightens() public {
        _deposit(alice, 1_000e6);
        _nextEpochMarketOpen();
        router.setSkim(50);
        vm.prank(keeper);
        vm.expectRevert();
        converter.executeBatch(0, address(aapl), 0, 4e18, block.timestamp + 60); // demands ~exact oracle price
    }

    function test_execute_chunked() public {
        _deposit(alice, 1_000e6);
        _nextEpochMarketOpen();
        vm.prank(keeper);
        converter.executeBatch(0, address(aapl), 300e6, 0, block.timestamp + 60);
        (,,,,, bool finalized,) = converter.batches(0, address(aapl));
        assertFalse(finalized);
        vm.expectRevert(BatchConverter.NotFinalized.selector);
        converter.claim(0, address(aapl), alice);
        vm.prank(keeper);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
        (,,,,, finalized,) = converter.batches(0, address(aapl));
        assertTrue(finalized);
        vm.prank(keeper);
        vm.expectRevert(BatchConverter.BatchClosed.selector);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
        converter.claim(0, address(aapl), alice);
        assertGt(aapl.balanceOf(alice), 0);
    }

    function test_execute_staleOracleReverts() public {
        _deposit(alice, 1_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        vm.expectRevert();
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
    }

    function test_refund_whenStale() public {
        _deposit(alice, 1_000e6);
        _deposit(bob, 1_000e6);
        _nextEpochMarketOpen();
        vm.prank(keeper);
        converter.executeBatch(0, address(aapl), 500e6, 0, block.timestamp + 60); // partial
        vm.expectRevert(BatchConverter.NotStale.selector);
        converter.openRefunds(0, address(aapl));
        vm.warp(converter.epochEnd(0) + 4 weeks);
        converter.openRefunds(0, address(aapl));
        vm.expectRevert(BatchConverter.BatchClosed.selector);
        converter.openRefunds(0, address(aapl));

        (uint256 totalIn, uint256 fee, uint256 executedIn, uint256 totalOut,,,) = converter.batches(0, address(aapl));
        uint256 leftover = totalIn - fee - executedIn;
        (uint256 back, uint256 outA) = converter.refund(0, address(aapl), alice);
        assertEq(back, (1_000e6 * leftover) / totalIn);
        assertEq(outA, (1_000e6 * totalOut) / totalIn);
        assertEq(usd.balanceOf(alice), back);
        vm.expectRevert(BatchConverter.AlreadySettled.selector);
        converter.refund(0, address(aapl), alice);
        vm.expectRevert(BatchConverter.NothingToClaim.selector);
        converter.refund(0, address(aapl), carol);
        vm.expectRevert(BatchConverter.NotStale.selector);
        converter.refund(0, address(spy), bob);
        vm.prank(keeper);
        vm.expectRevert(BatchConverter.BatchClosed.selector);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
    }

    function test_openRefunds_empty() public {
        vm.expectRevert(BatchConverter.NothingToExecute.selector);
        converter.openRefunds(0, address(aapl));
    }

    function test_claimMany() public {
        _deposit(bob, 1_000e6);
        _nextEpochMarketOpen();
        vm.startPrank(keeper);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
        converter.executeBatch(0, address(spy), 0, 0, block.timestamp + 60);
        vm.stopPrank();
        uint256[] memory e = new uint256[](2);
        address[] memory a = new address[](2);
        a[0] = address(aapl);
        a[1] = address(spy);
        converter.claimMany(e, a, bob);
        assertGt(aapl.balanceOf(bob), 0);
        assertGt(spy.balanceOf(bob), 0);
        vm.expectRevert(BatchConverter.NothingToClaim.selector);
        converter.claimMany(new uint256[](1), a, bob);
        vm.expectRevert(BatchConverter.BatchTooLarge.selector);
        converter.claimMany(new uint256[](51), new address[](51), bob);
    }

    function test_pause_blocksDepositsAndExecution() public {
        vm.prank(guardian);
        converter.pause();
        usd.mint(address(this), 1e6);
        usd.approve(address(converter), 1e6);
        vm.expectRevert();
        converter.deposit(alice, 1e6);
        vm.prank(guardian);
        converter.unpause();
        converter.deposit(alice, 1e6);
    }

    function test_admin_setters() public {
        vm.startPrank(admin);
        converter.setDex(address(dex));
        converter.setOracle(address(oracle));
        converter.setClock(address(clock));
        converter.setSliceRouter(address(slice));
        converter.setFeeCollector(address(fees));
        converter.setParams(10, 200, 2 weeks);
        vm.expectRevert(BatchConverter.ParamTooHigh.selector);
        converter.setParams(101, 200, 2 weeks);
        vm.expectRevert(BatchConverter.ParamTooHigh.selector);
        converter.setParams(10, 501, 2 weeks);
        vm.expectRevert(BatchConverter.ParamTooHigh.selector);
        converter.setParams(10, 100, 1 days);
        vm.expectRevert(BatchConverter.ZeroAddress.selector);
        converter.setDex(address(0));
        vm.expectRevert(BatchConverter.ZeroAddress.selector);
        converter.setOracle(address(0));
        vm.expectRevert(BatchConverter.ZeroAddress.selector);
        converter.setClock(address(0));
        vm.expectRevert(BatchConverter.ZeroAddress.selector);
        converter.setSliceRouter(address(0));
        vm.expectRevert(BatchConverter.ZeroAddress.selector);
        converter.setFeeCollector(address(0));
        vm.stopPrank();
        assertEq(converter.inputToken(), address(usd));
        assertEq(converter.maxSlippageBps(), 200);
    }

    function test_constructor_guards() public {
        vm.expectRevert(BatchConverter.ZeroAddress.selector);
        new BatchConverter(address(0), guardian, address(usd), address(slice), address(dex), address(oracle), address(clock), address(fees), 0, 0);
        vm.expectRevert(BatchConverter.ParamTooHigh.selector);
        new BatchConverter(admin, guardian, address(usd), address(slice), address(dex), address(oracle), address(clock), address(fees), 101, 0);
    }

    function test_stakerShareOfConversionFees() public {
        MockERC20 slce = new MockERC20("Mock SLCE", "mSLCE", 18);
        vm.prank(admin);
        hooks.setProjectToken(address(slce));
        slce.mint(carol, 100e18);
        vm.startPrank(carol);
        slce.approve(address(hooks), 100e18);
        hooks.stake(100e18);
        vm.stopPrank();

        _deposit(alice, 1_000e6);
        _nextEpochMarketOpen();
        vm.prank(keeper);
        converter.executeBatch(0, address(aapl), 0, 0, block.timestamp + 60);
        uint256 fee = (1_000e6 * 30) / 10_000;
        assertEq(fees.treasuryBalance(address(usd)), fee - fee / 2);
        assertApproxEqAbs(hooks.pendingReward(carol, address(usd)), fee / 2, 1);
        vm.prank(carol);
        hooks.claimRewards();
        assertApproxEqAbs(usd.balanceOf(carol), fee / 2, 1);
    }
}

contract SliceRouterTest is BaseTest {
    function test_setSlice_validation() public {
        address[] memory a = new address[](1);
        uint16[] memory w = new uint16[](1);
        a[0] = address(aapl);
        w[0] = 10_000;
        vm.startPrank(alice);
        vm.expectRevert(SliceRouter.InvalidSlice.selector);
        slice.setSlice(10_001, a, w);
        vm.expectRevert(SliceRouter.LengthMismatch.selector);
        slice.setSlice(100, a, new uint16[](2));
        vm.expectRevert(SliceRouter.TooManyAssets.selector);
        slice.setSlice(100, new address[](6), new uint16[](6));
        vm.expectRevert(SliceRouter.InvalidSlice.selector);
        slice.setSlice(100, new address[](0), new uint16[](0));
        w[0] = 9_000;
        vm.expectRevert(SliceRouter.BadWeights.selector);
        slice.setSlice(100, a, w);
        w[0] = 0;
        vm.expectRevert(SliceRouter.BadWeights.selector);
        slice.setSlice(100, a, w);
        a[0] = address(usd);
        w[0] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(SliceRouter.UnsupportedAsset.selector, address(usd)));
        slice.setSlice(100, a, w);
        address[] memory d = new address[](2);
        d[0] = address(aapl);
        d[1] = address(aapl);
        uint16[] memory dw = new uint16[](2);
        dw[0] = 5_000;
        dw[1] = 5_000;
        vm.expectRevert(abi.encodeWithSelector(SliceRouter.DuplicateAsset.selector, address(aapl)));
        slice.setSlice(100, d, dw);
        slice.setSlice(0, new address[](0), new uint16[](0)); // opt-out ok
        vm.stopPrank();
    }

    function test_split_and_delisting() public {
        address[] memory a = new address[](2);
        uint16[] memory w = new uint16[](2);
        a[0] = address(aapl);
        a[1] = address(spy);
        w[0] = 6_000;
        w[1] = 4_000;
        vm.prank(alice);
        slice.setSlice(3_000, a, w);
        (uint256 s, uint256 c) = slice.split(alice, 1_000e6);
        assertEq(c, 300e6);
        assertEq(s, 700e6);
        assertEq(slice.supportedAssets().length, 2);

        vm.prank(guardian); // guardian can de-list
        slice.setAssetSupport(address(spy), false);
        (s, c) = slice.split(alice, 1_000e6);
        assertEq(c, 180e6);
        (uint16 bps, address[] memory assets, uint16[] memory ws) = slice.allocationOf(alice);
        assertEq(bps, 3_000);
        assertEq(assets.length, 1);
        assertEq(ws[0], 6_000);
        assertEq(slice.supportedAssets().length, 1);
        assertEq(slice.rawAllocationOf(alice).assets.length, 2);

        vm.prank(guardian); // but not list
        vm.expectRevert();
        slice.setAssetSupport(address(spy), true);
        vm.prank(admin);
        slice.setAssetSupport(address(spy), true);

        vm.prank(admin);
        slice.setMaxSliceBps(1_000);
        (s, c) = slice.split(alice, 1_000e6);
        assertEq(c, 100e6);
        (bps,,) = slice.allocationOf(alice);
        assertEq(bps, 1_000);
        vm.prank(admin);
        vm.expectRevert(SliceRouter.InvalidSlice.selector);
        slice.setMaxSliceBps(10_001);
        vm.prank(admin);
        vm.expectRevert(SliceRouter.ZeroAddress.selector);
        slice.setAssetSupport(address(0), true);
    }

    function test_noSlice() public view {
        (uint256 s, uint256 c) = slice.split(bob, 123);
        assertEq(s, 123);
        assertEq(c, 0);
        (uint16 bps,,) = slice.allocationOf(bob);
        assertEq(bps, 0);
    }

    function test_compliance() public {
        vm.startPrank(admin);
        slice.setCompliance(address(compliance));
        compliance.setEnabled(true);
        vm.stopPrank();
        address[] memory a = new address[](1);
        uint16[] memory w = new uint16[](1);
        a[0] = address(aapl);
        w[0] = 10_000;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SliceRouter.NotAllowed.selector, alice));
        slice.setSlice(100, a, w);
    }

    function test_constructor() public {
        vm.expectRevert(SliceRouter.ZeroAddress.selector);
        new SliceRouter(address(0), guardian);
    }
}
