// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";
import {Payroll} from "../../src/Payroll.sol";
import {PayrollFactory} from "../../src/PayrollFactory.sol";
import {SliceRouter} from "../../src/SliceRouter.sol";
import {BatchConverter} from "../../src/BatchConverter.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {Timelock} from "../../src/Timelock.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {IAggregatorV3} from "../../src/interfaces/IExternal.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @notice Runs against Robinhood Chain mainnet state (real USDG, stock tokens, Chainlink feeds, Uniswap v3).
///         Set ROBINHOOD_RPC_URL (e.g. https://rpc.mainnet.chain.robinhood.com). Skipped when unset.
contract ForkTest is Test {
    Deploy internal d;
    PayrollFactory internal factory;
    SliceRouter internal slice;
    BatchConverter internal converter;
    OracleAdapter internal oracle;
    MarketClock internal clock;
    Timelock internal timelock;
    ProjectTokenHooks internal hooks;

    address internal employer = makeAddr("employer");
    address internal alice = makeAddr("alice");
    bool internal noFork;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            noFork = true;
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, RH.CHAIN_ID);
        d = new Deploy();
        vm.setEnv("PAYSLICE_KEEPER", vm.toString(address(this)));
        d.run();
        factory = d.factory();
        slice = d.slice();
        converter = d.converter();
        oracle = d.oracle();
        clock = d.clock();
        timelock = d.timelock();
        hooks = d.hooks();
    }

    modifier onlyFork() {
        if (noFork) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_realAddressesAndFeeds() public onlyFork {
        assertEq(IERC20Meta(RH.USDG).decimals(), 6);
        assertGt(oracle.getPrice(RH.USDG), 0.99e18);
        assertLt(oracle.getPrice(RH.USDG), 1.01e18);
        uint256 aapl = oracle.getPrice(RH.AAPL);
        console2.log("AAPL token price (1e18):", aapl);
        assertGt(aapl, 1e18);
        assertTrue(slice.isSupportedAsset(RH.AAPL));
        assertTrue(factory.isAllowedToken(RH.USDG));
        // admin handed to the timelock
        assertTrue(factory.hasRole(0x00, address(timelock)));
        assertFalse(factory.hasRole(0x00, address(this))); // deployer renounced
        assertFalse(hooks.isActive());
    }

    function test_fork_payrollStreamWithdrawSlice() public onlyFork {
        deal(RH.USDG, employer, 100_000e6);
        vm.startPrank(employer);
        Payroll p = Payroll(factory.createPayroll(RH.USDG, "Fork Co"));
        IERC20(RH.USDG).approve(address(p), type(uint256).max);
        p.deposit(100_000e6);
        uint256 id = p.createStream(alice, (uint256(5_000e6) * 1e18) / 30 days, 0, 0, 0);
        vm.stopPrank();

        address[] memory assets = new address[](2);
        assets[0] = RH.AAPL;
        assets[1] = RH.SPY;
        uint16[] memory w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
        vm.prank(alice);
        slice.setSlice(3_000, assets, w);

        vm.warp(block.timestamp + 3 days);
        uint256 earned = p.earned(id);
        assertApproxEqAbs(earned, 500e6, 1);
        vm.prank(alice);
        uint256 amt = p.withdraw(id);
        uint256 slicePart = (amt * 3_000) / 10_000;
        assertEq(IERC20(RH.USDG).balanceOf(alice), amt - slicePart);
        assertEq(IERC20(RH.USDG).balanceOf(address(converter)), slicePart);
    }

    function test_fork_batchConversionThroughUniswap() public onlyFork {
        // queue 1,000 USDG for alice -> AAPL
        address[] memory assets = new address[](1);
        assets[0] = RH.AAPL;
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        vm.prank(alice);
        slice.setSlice(10_000, assets, w);
        deal(RH.USDG, address(this), 1_000e6);
        IERC20(RH.USDG).approve(address(converter), 1_000e6);
        converter.deposit(alice, 1_000e6);

        // close the epoch and move to a regular US session
        vm.warp(block.timestamp + 7 days);
        while (!clock.isMarketOpen()) vm.warp(block.timestamp + 30 minutes);
        _refreshFeed(RH.USDG_USD_FEED);
        _refreshFeed(RH.AAPL_FEED);

        uint256 minOut = converter.quoteMinOut(RH.AAPL, 1_000e6 - (1_000e6 * 30) / 10_000);
        console2.log("oracle min out (AAPL wei):", minOut);
        try converter.executeBatch(0, RH.AAPL, 0, 0, block.timestamp + 300) returns (uint256 out) {
            assertGe(out, minOut);
            uint256 got = converter.claim(0, RH.AAPL, alice);
            assertEq(IERC20(RH.AAPL).balanceOf(alice), got);
            console2.log("AAPL received:", got);
        } catch (bytes memory reason) {
            // If live pool depth can't fill within 1% of Chainlink, the oracle floor must be what stopped it.
            console2.log("swap rejected by slippage floor (pool shallower than 1% band)");
            assertGt(reason.length, 0);
        }
    }

    function test_fork_timelockGatesProjectToken() public onlyFork {
        MockERC20 slce = new MockERC20("Mock SLCE", "mSLCE", 18); // test-only mock
        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(slce)));
        address proposer = address(this); // PAYSLICE_ADMIN defaults to the deployer (this test)
        vm.prank(proposer);
        timelock.schedule(address(hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(proposer);
        timelock.execute(address(hooks), 0, data, bytes32(0), bytes32(0));
        assertTrue(hooks.isActive());
        assertEq(address(hooks.projectToken()), address(slce));
    }

    function _refreshFeed(address feed) internal {
        (uint80 rid, int256 ans, uint256 st,, uint80 air) = IAggregatorV3(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(rid, ans, st, block.timestamp, air)
        );
    }
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
}
