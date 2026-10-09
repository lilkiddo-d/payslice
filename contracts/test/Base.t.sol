// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PayrollFactory} from "../src/PayrollFactory.sol";
import {Payroll} from "../src/Payroll.sol";
import {SliceRouter} from "../src/SliceRouter.sol";
import {BatchConverter} from "../src/BatchConverter.sol";
import {DexAdapter} from "../src/adapters/DexAdapter.sol";
import {BonusVesting} from "../src/BonusVesting.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";

import {MockERC20, MockAggregator, MockSwapRouter} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    // Monday 2026-10-05 14:00 UTC = 10:00 New York (market open)
    uint256 internal constant T0 = 1_791_208_800;
    uint256 internal constant SCALE = 1e18;

    address internal admin = makeAddr("admin"); // stands in for the Timelock in unit tests
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal employer = makeAddr("employer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockERC20 internal usd; // 6 decimals, like USDG
    MockERC20 internal aapl; // 18 decimals stock tokens
    MockERC20 internal spy;
    MockAggregator internal usdFeed;
    MockAggregator internal aaplFeed;
    MockAggregator internal spyFeed;
    MockSwapRouter internal router;

    PayrollFactory internal factory;
    SliceRouter internal slice;
    BatchConverter internal converter;
    DexAdapter internal dex;
    BonusVesting internal bonus;
    MarketClock internal clock;
    OracleAdapter internal oracle;
    FeeCollector internal fees;
    ProjectTokenHooks internal hooks;
    ComplianceRegistry internal compliance;

    Payroll internal payroll;

    function setUp() public virtual {
        vm.warp(T0);
        usd = new MockERC20("Test Dollar", "tUSD", 6);
        aapl = new MockERC20("Test AAPL", "tAAPL", 18);
        spy = new MockERC20("Test SPY", "tSPY", 18);
        usdFeed = new MockAggregator(8, 1e8);
        aaplFeed = new MockAggregator(8, 250e8);
        spyFeed = new MockAggregator(8, 500e8);
        router = new MockSwapRouter();
        // 1 tUSD (1e6) -> 1/250 AAPL (4e15)
        router.setRate(address(usd), address(aapl), 1e18, 250e6);
        router.setRate(address(usd), address(spy), 1e18, 500e6);

        fees = new FeeCollector(admin, treasury, 5000);
        hooks = new ProjectTokenHooks(admin, guardian);
        compliance = new ComplianceRegistry(admin, admin);
        oracle = new OracleAdapter(admin, guardian);
        clock = new MarketClock(admin, guardian);
        slice = new SliceRouter(admin, guardian);
        dex = new DexAdapter(admin, address(router));
        converter = new BatchConverter(
            admin, guardian, address(usd), address(slice), address(dex), address(oracle), address(clock), address(fees), 30, 100
        );
        factory = new PayrollFactory(admin, guardian, address(fees), 50);
        bonus = new BonusVesting(admin, guardian, address(slice));

        vm.startPrank(admin);
        fees.setHooks(address(hooks));
        oracle.setFeed(address(usd), address(usdFeed), 1 days + 1 hours, 100);
        oracle.setFeed(address(aapl), address(aaplFeed), 1 days + 1 hours, 0);
        oracle.setFeed(address(spy), address(spyFeed), 1 days + 1 hours, 0);
        dex.setRoute(address(usd), address(aapl), abi.encodePacked(address(usd), uint24(500), address(aapl)));
        dex.setRoute(address(usd), address(spy), abi.encodePacked(address(usd), uint24(3000), address(spy)));
        slice.setAssetSupport(address(aapl), true);
        slice.setAssetSupport(address(spy), true);
        converter.grantRole(converter.KEEPER_ROLE(), keeper);
        factory.setAllowedToken(address(usd), true);
        factory.setSliceRouter(address(slice));
        factory.setBatchConverter(address(converter));
        factory.setCompliance(address(compliance));
        factory.setProjectHooks(address(hooks));
        hooks.addRewardToken(address(usd));
        vm.stopPrank();

        vm.prank(employer);
        payroll = Payroll(factory.createPayroll(address(usd), "Acme Inc"));

        usd.mint(employer, 10_000_000e6);
        vm.prank(employer);
        usd.approve(address(payroll), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev rateX for `amount` tokens (base units) per `period` seconds
    function rateFor(uint256 amount, uint256 period) internal pure returns (uint256) {
        return (amount * SCALE) / period;
    }

    function fund(uint256 amount) internal {
        vm.prank(employer);
        payroll.deposit(amount);
    }

    function stream(address worker, uint256 rateX) internal returns (uint256 id) {
        vm.prank(employer);
        id = payroll.createStream(worker, rateX, 0, 0, 0);
    }

    function netOf(uint256 gross) internal view returns (uint256) {
        return gross - (gross * factory.effectiveFeeBps(employer)) / 10_000;
    }
}
