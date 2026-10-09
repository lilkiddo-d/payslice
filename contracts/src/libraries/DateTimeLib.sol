// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DateTimeLib
/// @notice Gregorian calendar helpers (UTC) based on the Fliegel & Van Flandern civil-date algorithm.
///         Valid for timestamps from 1970-01-01 onwards.
library DateTimeLib {
    uint256 internal constant SECONDS_PER_DAY = 86_400;
    int256 internal constant OFFSET19700101 = 2_440_588;

    // slither-disable-next-line divide-before-multiply
    function daysFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        int256 y = int256(year);
        int256 m = int256(month);
        int256 d = int256(day);
        int256 days_ = d - 32_075 + (1461 * (y + 4800 + (m - 14) / 12)) / 4
            + (367 * (m - 2 - ((m - 14) / 12) * 12)) / 12 - (3 * ((y + 4900 + (m - 14) / 12) / 100)) / 4
            - OFFSET19700101;
        return uint256(days_);
    }

    /// @dev Integer division is the algorithm (calendar arithmetic), not a precision bug.
    // slither-disable-start divide-before-multiply
    function daysToDate(uint256 days_) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 l0 = int256(days_) + 68_569 + OFFSET19700101;
        int256 n = (4 * l0) / 146_097;
        int256 l1 = l0 - (146_097 * n + 3) / 4;
        int256 y0 = (4000 * (l1 + 1)) / 1_461_001;
        int256 l2 = l1 - (1461 * y0) / 4 + 31;
        int256 m0 = (80 * l2) / 2447;
        int256 d = l2 - (2447 * m0) / 80;
        int256 l3 = m0 / 11;
        int256 m = m0 + 2 - 12 * l3;
        int256 y = 100 * (n - 49) + y0 + l3;
        year = uint256(y);
        month = uint256(m);
        day = uint256(d);
    }
    // slither-disable-end divide-before-multiply

    /// @return 1 = Monday ... 7 = Sunday
    function dayOfWeekFromDays(uint256 days_) internal pure returns (uint256) {
        return ((days_ + 3) % 7) + 1;
    }

    function dayOfWeek(uint256 timestamp) internal pure returns (uint256) {
        return dayOfWeekFromDays(timestamp / SECONDS_PER_DAY);
    }

    function yearOf(uint256 timestamp) internal pure returns (uint256 year) {
        (year,,) = daysToDate(timestamp / SECONDS_PER_DAY);
    }

    /// @notice Timestamp of 00:00 UTC on the first day of the month containing `timestamp`.
    function monthStart(uint256 timestamp) internal pure returns (uint256) {
        (uint256 y, uint256 m,) = daysToDate(timestamp / SECONDS_PER_DAY);
        return daysFromDate(y, m, 1) * SECONDS_PER_DAY;
    }

    /// @notice Timestamp of 00:00 UTC on the first day of the month after the one containing `timestamp`.
    function nextMonthStart(uint256 timestamp) internal pure returns (uint256) {
        (uint256 y, uint256 m,) = daysToDate(timestamp / SECONDS_PER_DAY);
        if (m == 12) {
            return daysFromDate(y + 1, 1, 1) * SECONDS_PER_DAY;
        }
        return daysFromDate(y, m + 1, 1) * SECONDS_PER_DAY;
    }

    /// @notice Day index (days since epoch) of the n-th Sunday (1-based) of `month` in `year`.
    function nthSunday(uint256 year, uint256 month, uint256 n) internal pure returns (uint256) {
        uint256 first = daysFromDate(year, month, 1);
        uint256 dow = dayOfWeekFromDays(first); // 7 = Sunday
        uint256 firstSunday = first + ((7 - dow) % 7);
        return firstSunday + (n - 1) * 7;
    }

    /// @notice True if US Eastern daylight saving time is in effect at UTC `timestamp`.
    ///         DST starts the second Sunday of March at 02:00 EST (07:00 UTC) and ends the first
    ///         Sunday of November at 02:00 EDT (06:00 UTC).
    function isUsEasternDst(uint256 timestamp) internal pure returns (bool) {
        uint256 year = yearOf(timestamp);
        uint256 dstStart = nthSunday(year, 3, 2) * SECONDS_PER_DAY + 7 hours;
        uint256 dstEnd = nthSunday(year, 11, 1) * SECONDS_PER_DAY + 6 hours;
        return timestamp >= dstStart && timestamp < dstEnd;
    }
}
