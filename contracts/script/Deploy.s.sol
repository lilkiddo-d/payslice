// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Timelock} from "../src/Timelock.sol";
import {PayrollFactory} from "../src/PayrollFactory.sol";
import {SliceRouter} from "../src/SliceRouter.sol";
import {BatchConverter} from "../src/BatchConverter.sol";
import {DexAdapter} from "../src/adapters/DexAdapter.sol";
import {BonusVesting} from "../src/BonusVesting.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {DateTimeLib} from "../src/libraries/DateTimeLib.sol";
import {RobinhoodChain as RH} from "./RobinhoodChain.sol";

interface IUniV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IUniV3Pool {
    function liquidity() external view returns (uint128);
}

/// @title Deploy
/// @notice Deploys and wires the whole Payslice protocol, then hands every admin role to the 48h Timelock.
///
/// Signing: this script never touches a private key. It calls `vm.startBroadcast(msg.sender)`, so the signer
/// is the `--sender` / `--account` forge was given on the command line — in production the Foundry keystore
/// account `--account payslice-deployer`.
///
/// Optional env (all default to the deployer address):
///   PAYSLICE_ADMIN       Timelock proposer + executor (use a multisig)
///   PAYSLICE_GUARDIAN    pause / safe-direction switches
///   PAYSLICE_TREASURY    receives protocol fees
///   PAYSLICE_KEEPER      KEEPER_ROLE on BatchConverter (cast wallet address --account payslice-keeper)
///   PAYSLICE_COMPLIANCE  allowlist operator for ComplianceRegistry
///   TIMELOCK_DELAY       seconds, >= 172800 (48h)
///
/// Outputs (broadcast only): deployments/<chainId>.json and ../app/src/config/generated/<chainId>.json.
/// A simulation (no --broadcast) writes deployments/dryrun-<chainId>.json instead.
contract Deploy is Script {
    uint256 internal constant LOCAL_FORK_CHAIN_ID = 31_337;
    uint16 internal constant PAYROLL_FEE_BPS = 25; // 0.25% of deposits
    uint16 internal constant CONVERSION_FEE_BPS = 30; // 0.30% of converted volume
    uint16 internal constant MAX_SLIPPAGE_BPS = 100; // 1% vs Chainlink
    uint16 internal constant STAKER_SHARE_BPS = 5_000; // 50% of conversion fees to $SLCE stakers (once set)
    uint32 internal constant FEED_STALENESS = 25 hours; // Chainlink heartbeat is 24h
    uint16 internal constant USDG_MAX_DEPEG_BPS = 100; // 1%

    struct Roles {
        address deployer;
        address admin;
        address guardian;
        address treasury;
        address keeper;
        address complianceOperator;
        uint256 delay;
    }

    struct Asset {
        string symbol;
        address token;
        address feed;
        uint24 fee;
        address pool;
    }

    Roles internal r;
    Timelock public timelock;
    PayrollFactory public factory;
    SliceRouter public slice;
    BatchConverter public converter;
    DexAdapter public dex;
    BonusVesting public bonus;
    MarketClock public clock;
    OracleAdapter public oracle;
    FeeCollector public fees;
    ProjectTokenHooks public hooks;
    ComplianceRegistry public compliance;
    Asset[] internal listed;
    uint256 internal startBlock;

    function run() external {
        require(block.chainid == RH.CHAIN_ID || block.chainid == LOCAL_FORK_CHAIN_ID, "Deploy: unsupported chain");
        require(RH.USDG.code.length != 0, "Deploy: USDG not found (local runs must fork Robinhood Chain mainnet)");

        r.deployer = msg.sender;
        r.admin = vm.envOr("PAYSLICE_ADMIN", msg.sender);
        r.guardian = vm.envOr("PAYSLICE_GUARDIAN", msg.sender);
        r.treasury = vm.envOr("PAYSLICE_TREASURY", msg.sender);
        r.keeper = vm.envOr("PAYSLICE_KEEPER", msg.sender);
        r.complianceOperator = vm.envOr("PAYSLICE_COMPLIANCE", r.admin);
        r.delay = vm.envOr("TIMELOCK_DELAY", uint256(48 hours));
        startBlock = block.number;

        console2.log("Deployer :", r.deployer);
        console2.log("Admin    :", r.admin);
        console2.log("Guardian :", r.guardian);
        console2.log("Keeper   :", r.keeper);

        vm.startBroadcast(r.deployer);
        _deployCore();
        _wireOracleAndRoutes();
        _wireProtocol();
        _setHolidays();
        _handOverToTimelock();
        vm.stopBroadcast();

        _assertHandover();
        _writeOutputs();
    }

    // ------------------------------------------------------------------------------------------------

    function _deployCore() internal {
        address[] memory ops = new address[](1);
        ops[0] = r.admin;
        timelock = new Timelock(r.delay, ops, ops);

        address d = r.deployer; // temporary admin while wiring; renounced at the end
        fees = new FeeCollector(d, r.treasury, STAKER_SHARE_BPS);
        hooks = new ProjectTokenHooks(d, r.guardian);
        compliance = new ComplianceRegistry(d, d);
        oracle = new OracleAdapter(d, r.guardian);
        clock = new MarketClock(d, r.guardian);
        slice = new SliceRouter(d, r.guardian);
        dex = new DexAdapter(d, RH.UNIV3_SWAP_ROUTER02);
        converter = new BatchConverter(
            d,
            r.guardian,
            RH.USDG,
            address(slice),
            address(dex),
            address(oracle),
            address(clock),
            address(fees),
            CONVERSION_FEE_BPS,
            MAX_SLIPPAGE_BPS
        );
        factory = new PayrollFactory(d, r.guardian, address(fees), PAYROLL_FEE_BPS);
        bonus = new BonusVesting(d, r.guardian, address(slice));
    }

    function _wireOracleAndRoutes() internal {
        oracle.setFeed(RH.USDG, RH.USDG_USD_FEED, FEED_STALENESS, USDG_MAX_DEPEG_BPS);
        RH.Stock[] memory s = RH.stocks();
        for (uint256 i; i < s.length; ++i) {
            (uint24 fee, address pool) = _deepestPool(RH.USDG, s[i].token);
            if (pool == address(0)) {
                console2.log("No USDG pool with liquidity, not listed:", s[i].symbol);
                continue;
            }
            oracle.setFeed(s[i].token, s[i].feed, FEED_STALENESS, 0);
            dex.setRoute(RH.USDG, s[i].token, abi.encodePacked(RH.USDG, fee, s[i].token));
            slice.setAssetSupport(s[i].token, true);
            listed.push(Asset(s[i].symbol, s[i].token, s[i].feed, fee, pool));
            console2.log("Listed", s[i].symbol, "fee tier", fee);
        }
    }

    /// @dev Pick the direct USDG/stock Uniswap v3 pool with the most in-range liquidity (read on-chain).
    function _deepestPool(address a, address b) internal view returns (uint24 bestFee, address bestPool) {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10_000];
        uint128 best;
        for (uint256 i; i < tiers.length; ++i) {
            address pool = IUniV3Factory(RH.UNIV3_FACTORY).getPool(a, b, tiers[i]);
            if (pool == address(0)) continue;
            uint128 liq = IUniV3Pool(pool).liquidity();
            if (liq > best) {
                best = liq;
                bestFee = tiers[i];
                bestPool = pool;
            }
        }
    }

    function _wireProtocol() internal {
        fees.setHooks(address(hooks));
        hooks.addRewardToken(RH.USDG);
        // Fee-discount tiers assume an 18-decimal $SLCE; adjustable later through the Timelock.
        uint256[] memory th = new uint256[](3);
        uint256[] memory disc = new uint256[](3);
        (th[0], th[1], th[2]) = (10_000e18, 100_000e18, 1_000_000e18);
        (disc[0], disc[1], disc[2]) = (2_500, 5_000, 10_000);
        hooks.setTiers(th, disc);

        factory.setAllowedToken(RH.USDG, true);
        factory.setSliceRouter(address(slice));
        factory.setBatchConverter(address(converter));
        factory.setCompliance(address(compliance)); // registry is disabled by default => everyone allowed
        factory.setProjectHooks(address(hooks));
        slice.setCompliance(address(compliance));
        converter.setCompliance(address(compliance));
        bonus.setCompliance(address(compliance));

        converter.grantRole(converter.KEEPER_ROLE(), r.keeper);
        compliance.grantRole(compliance.COMPLIANCE_ROLE(), r.complianceOperator);
    }

    function _setHolidays() internal {
        uint16[3][] memory h = RH.nyseHolidays();
        uint256[] memory idx = new uint256[](h.length);
        for (uint256 i; i < h.length; ++i) {
            idx[i] = DateTimeLib.daysFromDate(h[i][0], h[i][1], h[i][2]);
        }
        clock.setHolidays(idx, true);
    }

    function _handOverToTimelock() internal {
        address[] memory targets = _accessControlled();
        bytes32 adminRole = 0x00;
        for (uint256 i; i < targets.length; ++i) {
            IAccessControl(targets[i]).grantRole(adminRole, address(timelock));
            IAccessControl(targets[i]).renounceRole(adminRole, r.deployer);
        }
        if (r.complianceOperator != r.deployer) {
            compliance.renounceRole(compliance.COMPLIANCE_ROLE(), r.deployer);
        }
    }

    function _assertHandover() internal view {
        address[] memory targets = _accessControlled();
        for (uint256 i; i < targets.length; ++i) {
            require(IAccessControl(targets[i]).hasRole(0x00, address(timelock)), "Deploy: timelock not admin");
            require(!IAccessControl(targets[i]).hasRole(0x00, r.deployer), "Deploy: deployer still admin");
        }
        require(timelock.getMinDelay() >= 48 hours, "Deploy: delay");
        require(!hooks.isActive(), "Deploy: token features must start disabled");
        require(!compliance.enabled(), "Deploy: compliance must start disabled");
    }

    function _accessControlled() internal view returns (address[] memory t) {
        t = new address[](10);
        t[0] = address(fees);
        t[1] = address(hooks);
        t[2] = address(compliance);
        t[3] = address(oracle);
        t[4] = address(clock);
        t[5] = address(slice);
        t[6] = address(dex);
        t[7] = address(converter);
        t[8] = address(factory);
        t[9] = address(bonus);
    }

    // ------------------------------------------------------------------------------------------------
    // Output
    // ------------------------------------------------------------------------------------------------

    function _writeOutputs() internal {
        string memory json = _json();
        string memory id = vm.toString(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (broadcasting) {
            vm.writeFile(string.concat("deployments/", id, ".json"), json);
            vm.writeFile(string.concat("../app/src/config/generated/", id, ".json"), json);
            console2.log("Wrote deployments and frontend config for chain", id);
        } else {
            vm.writeFile(string.concat("deployments/dryrun-", id, ".json"), json);
            console2.log("Simulation only: wrote deployments/dryrun-<chainId>.json");
        }
    }

    function _kv(string memory k, address v) internal pure returns (string memory) {
        return string.concat('"', k, '":"', vm.toString(v), '"');
    }

    function _json() internal view returns (string memory) {
        string memory core = string.concat(
            "{",
            '"chainId":',
            vm.toString(block.chainid),
            ',"startBlock":',
            vm.toString(startBlock),
            ",",
            _kv("timelock", address(timelock)),
            ",",
            _kv("payrollFactory", address(factory)),
            ",",
            _kv("payrollImplementation", factory.implementation()),
            ",",
            _kv("sliceRouter", address(slice)),
            ",",
            _kv("batchConverter", address(converter)),
            ",",
            _kv("dexAdapter", address(dex))
        );
        core = string.concat(
            core,
            ",",
            _kv("bonusVesting", address(bonus)),
            ",",
            _kv("marketClock", address(clock)),
            ",",
            _kv("oracleAdapter", address(oracle)),
            ",",
            _kv("feeCollector", address(fees)),
            ",",
            _kv("projectTokenHooks", address(hooks)),
            ",",
            _kv("complianceRegistry", address(compliance)),
            ",",
            _kv("stablecoin", RH.USDG)
        );
        core = string.concat(
            core,
            ",",
            _kv("admin", r.admin),
            ",",
            _kv("guardian", r.guardian),
            ",",
            _kv("keeper", r.keeper),
            ",",
            _kv("treasury", r.treasury),
            ',"assets":['
        );
        for (uint256 i; i < listed.length; ++i) {
            Asset memory a = listed[i];
            core = string.concat(
                core,
                i == 0 ? "" : ",",
                '{"symbol":"',
                a.symbol,
                '",',
                _kv("token", a.token),
                ",",
                _kv("feed", a.feed),
                ",",
                _kv("pool", a.pool),
                ',"fee":',
                vm.toString(uint256(a.fee)),
                "}"
            );
        }
        return string.concat(core, "]}");
    }
}
