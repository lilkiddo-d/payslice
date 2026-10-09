// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IMarketClock} from "./interfaces/IPayslice.sol";
import {DateTimeLib} from "./libraries/DateTimeLib.sol";

/// @title MarketClock
/// @notice Regular US equity session gate: Monday-Friday 09:30-16:00 America/New_York, with US daylight
///         saving computed on-chain and an admin-maintained holiday calendar.
///         The guardian can force the market closed or add a holiday instantly (safe direction);
///         only the Timelock can remove holidays or force it open.
contract MarketClock is IMarketClock, AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant OPEN_SECONDS = 9 hours + 30 minutes;
    uint256 public constant CLOSE_SECONDS = 16 hours;
    uint256 public constant MAX_HOLIDAY_BATCH = 30;

    enum Mode {
        Auto,
        ForceClosed,
        ForceOpen
    }

    Mode public mode;
    /// @notice New York local day index (days since 1970-01-01) => closed
    mapping(uint256 => bool) public isHoliday;

    event ModeSet(Mode mode);
    event HolidaySet(uint256 indexed localDay, bool closed);

    error BatchTooLarge();
    error ZeroAddress();

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function isMarketOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

    function isOpenAt(uint256 timestamp) public view returns (bool) {
        Mode m = mode;
        if (m == Mode.ForceClosed) return false;
        if (m == Mode.ForceOpen) return true;
        uint256 local = toNewYork(timestamp);
        uint256 day = local / DateTimeLib.SECONDS_PER_DAY;
        uint256 dow = DateTimeLib.dayOfWeekFromDays(day);
        if (dow > 5) return false; // Sat/Sun
        if (isHoliday[day]) return false;
        // Time-of-day arithmetic, not randomness.
        // slither-disable-next-line weak-prng
        uint256 secs = local % DateTimeLib.SECONDS_PER_DAY;
        return secs >= OPEN_SECONDS && secs < CLOSE_SECONDS;
    }

    /// @notice Convert a UTC timestamp into New York wall-clock seconds.
    function toNewYork(uint256 timestamp) public pure returns (uint256) {
        return timestamp - (DateTimeLib.isUsEasternDst(timestamp) ? 4 hours : 5 hours);
    }

    /// @notice Helper for off-chain tooling: local NY day index of a calendar date.
    function dayIndex(uint256 year, uint256 month, uint256 day) external pure returns (uint256) {
        return DateTimeLib.daysFromDate(year, month, day);
    }

    function setMode(Mode m) external {
        if (m != Mode.ForceClosed || !hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(DEFAULT_ADMIN_ROLE);
        mode = m;
        emit ModeSet(m);
    }

    /// @notice Add (guardian or Timelock) or remove (Timelock only) holidays, by NY-local day index.
    function setHolidays(uint256[] calldata localDays, bool closed) external {
        if (!closed || !hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(DEFAULT_ADMIN_ROLE);
        if (localDays.length > MAX_HOLIDAY_BATCH) revert BatchTooLarge();
        for (uint256 i; i < localDays.length; ++i) {
            isHoliday[localDays[i]] = closed;
            emit HolidaySet(localDays[i], closed);
        }
    }
}
