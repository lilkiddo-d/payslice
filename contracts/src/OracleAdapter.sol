// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IOracleAdapter} from "./interfaces/IPayslice.sol";
import {IAggregatorV3} from "./interfaces/IExternal.sol";

/// @title OracleAdapter (Chainlink)
/// @notice Swappable USD price source with staleness, sanity and stablecoin-peg deviation checks.
///         Robinhood Chain stock-token feeds already include the corporate-action multiplier, so the
///         returned price is the price of ONE token (not one share).
///
///         Robinhood Chain has no Chainlink L2 sequencer uptime feed today; `sequencerFeed` is optional and
///         checked only when set, so it can be wired in later without redeploying.
contract OracleAdapter is IOracleAdapter, AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_STALENESS = 3 days;
    uint256 public constant SEQUENCER_GRACE = 1 hours;

    struct Feed {
        IAggregatorV3 aggregator;
        uint32 maxStaleness; // seconds
        uint8 decimals;
        uint16 maxPegDeviationBps; // 0 = not a pegged asset; otherwise |price - $1| must be <= this
        bool disabled;
    }

    mapping(address => Feed) public feeds;
    IAggregatorV3 public sequencerFeed;

    event FeedSet(address indexed token, address indexed aggregator, uint32 maxStaleness, uint16 maxPegDeviationBps);
    event FeedDisabled(address indexed token, bool disabled);
    event SequencerFeedSet(address indexed feed);

    error ZeroAddress();
    error NoFeed(address token);
    error FeedIsDisabled(address token);
    error InvalidPrice(address token);
    error StalePrice(address token, uint256 updatedAt);
    error Depegged(address token, uint256 price);
    error SequencerDown();
    error BadParam();

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    /// @inheritdoc IOracleAdapter
    function getPrice(address token) external view returns (uint256) {
        Feed memory f = feeds[token];
        if (address(f.aggregator) == address(0)) revert NoFeed(token);
        if (f.disabled) revert FeedIsDisabled(token);
        _checkSequencer();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            f.aggregator.latestRoundData();
        if (answer <= 0 || roundId == 0 || startedAt == 0 || answeredInRound < roundId) revert InvalidPrice(token);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > f.maxStaleness) {
            revert StalePrice(token, updatedAt);
        }
        uint256 price = uint256(answer) * 10 ** (18 - f.decimals);
        if (f.maxPegDeviationBps != 0) {
            uint256 one = 1e18;
            uint256 diff = price > one ? price - one : one - price;
            if (diff * BPS > one * f.maxPegDeviationBps) revert Depegged(token, price);
        }
        return price;
    }

    function hasFeed(address token) external view returns (bool) {
        Feed memory f = feeds[token];
        return address(f.aggregator) != address(0) && !f.disabled;
    }

    function _checkSequencer() internal view {
        IAggregatorV3 s = sequencerFeed;
        if (address(s) == address(0)) return;
        // slither-disable-next-line unused-return
        (, int256 answer, uint256 startedAt,,) = s.latestRoundData();
        // 0 = up, 1 = down
        if (answer != 0 || block.timestamp - startedAt <= SEQUENCER_GRACE) revert SequencerDown();
    }

    // ----------------------------------------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------------------------------------

    function setFeed(address token, address aggregator, uint32 maxStaleness, uint16 maxPegDeviationBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0) || aggregator == address(0)) revert ZeroAddress();
        if (maxStaleness == 0 || maxStaleness > MAX_STALENESS || maxPegDeviationBps > 1000) revert BadParam();
        uint8 dec = IAggregatorV3(aggregator).decimals();
        if (dec > 18) revert BadParam();
        feeds[token] = Feed({
            aggregator: IAggregatorV3(aggregator),
            maxStaleness: maxStaleness,
            decimals: dec,
            maxPegDeviationBps: maxPegDeviationBps,
            disabled: false
        });
        emit FeedSet(token, aggregator, maxStaleness, maxPegDeviationBps);
    }

    /// @notice The guardian can disable a feed immediately (safe direction); only the Timelock re-enables.
    function setFeedDisabled(address token, bool disabled) external {
        if (!disabled || !hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(DEFAULT_ADMIN_ROLE);
        if (address(feeds[token].aggregator) == address(0)) revert NoFeed(token);
        feeds[token].disabled = disabled;
        emit FeedDisabled(token, disabled);
    }

    function setSequencerFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerFeed = IAggregatorV3(feed);
        emit SequencerFeedSet(feed);
    }
}
