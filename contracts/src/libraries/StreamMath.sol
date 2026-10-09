// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StreamMath
/// @notice Per-second accrual math for Payslice streams.
/// @dev Rates are stored as `rateX` = token base units per second scaled by 1e18. Accrued amounts are kept
///      in the same scaled unit and only floored to token units when paid out, so editing a stream any
///      number of times never loses value to rounding (total drift < 1 base unit per stream).
///
///      A payroll that runs dry stops accruing ("auto-pause"). Each dry period is recorded as a gap; time
///      inside a gap is never earned. Gaps are stored sorted with prefix sums so the paused seconds inside
///      any interval are found with an O(log n) binary search (no unbounded loops).
library StreamMath {
    uint256 internal constant SCALE = 1e18;

    struct Gaps {
        uint64[] starts;
        uint64[] ends;
        uint256[] cumulative; // cumulative[i] = sum of gap lengths 0..i
    }

    error GapOutOfOrder();

    function toTokens(uint256 amountX) internal pure returns (uint256) {
        return amountX / SCALE;
    }

    function min64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }

    function max64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a > b ? a : b;
    }

    function count(Gaps storage g) internal view returns (uint256) {
        return g.starts.length;
    }

    /// @notice Append a gap [start, end). Gaps must be appended in chronological order.
    function record(Gaps storage g, uint64 start, uint64 end) internal {
        if (end <= start) return;
        uint256 n = g.starts.length;
        uint256 prev = 0;
        if (n != 0) {
            if (start < g.ends[n - 1]) revert GapOutOfOrder();
            prev = g.cumulative[n - 1];
        }
        g.starts.push(start);
        g.ends.push(end);
        g.cumulative.push(prev + (end - start));
    }

    /// @notice Total gap seconds strictly before `t`.
    function gapSecondsBefore(Gaps storage g, uint64 t) internal view returns (uint256) {
        uint256 n = g.starts.length;
        if (n == 0 || t <= g.starts[0]) return 0;
        // Find the number of gaps whose start is < t (binary search, O(log n)).
        uint256 lo = 0;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (g.starts[mid] < t) lo = mid + 1;
            else hi = mid;
        }
        uint256 i = lo - 1;
        uint256 before = i == 0 ? 0 : g.cumulative[i - 1];
        uint64 e = min64(g.ends[i], t);
        return before + (e - g.starts[i]);
    }

    /// @notice Seconds in [a, b) that are not inside a gap.
    function activeSeconds(Gaps storage g, uint64 a, uint64 b) internal view returns (uint256) {
        if (b <= a) return 0;
        return uint256(b - a) - (gapSecondsBefore(g, b) - gapSecondsBefore(g, a));
    }

    /// @notice Amount earned by a stream over [a, b) (clipped to [start, end), minus gaps).
    function earnedOver(Gaps storage g, uint256 rateX, uint64 start, uint64 end, uint64 a, uint64 b)
        internal
        view
        returns (uint256)
    {
        uint64 lo = max64(a, start);
        uint64 hi = end == 0 ? b : min64(b, end);
        if (hi <= lo) return 0;
        return rateX * activeSeconds(g, lo, hi);
    }

    /// @notice Accrual of a stream over the payroll-funded interval [a, b).
    /// @param rateX scaled rate per second
    /// @param start stream start
    /// @param end stream end (0 = open ended)
    /// @return reservedX amount the payroll reserved for this stream over [a, b) (rate x active seconds)
    /// @return earnedX amount the worker actually earned (clipped to [start, end))
    function accrue(Gaps storage g, uint256 rateX, uint64 start, uint64 end, uint64 a, uint64 b)
        internal
        view
        returns (uint256 reservedX, uint256 earnedX)
    {
        if (b <= a) return (0, 0);
        reservedX = rateX * activeSeconds(g, a, b);
        earnedX = earnedOver(g, rateX, start, end, a, b);
    }
}
