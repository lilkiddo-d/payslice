// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IComplianceRegistry} from "./interfaces/IPayslice.sol";

/// @title SliceRouter
/// @notice Stores each worker's slice rule: what share of every withdrawal is queued for weekly stock
///         conversion, and how that share is weighted across supported stock tokens.
///         e.g. sliceBps = 3000 with [AAPL 50%, SPY 50%] => 70% stays stablecoin, 15% AAPL, 15% SPY.
contract SliceRouter is AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint16 public constant BPS = 10_000;
    uint256 public constant MAX_ASSETS = 5;

    struct Allocation {
        uint16 sliceBps;
        bool autoHarvest;
        address[] assets;
        uint16[] weights; // sum to BPS
    }

    IComplianceRegistry public compliance;
    uint16 public maxSliceBps = BPS;

    mapping(address => bool) public isSupportedAsset;
    address[] internal _assetList;
    mapping(address => bool) internal _listed;
    mapping(address => Allocation) internal _alloc;

    event SliceSet(address indexed worker, uint16 sliceBps, address[] assets, uint16[] weights);
    event AutoHarvestSet(address indexed worker, bool enabled);
    event AssetSupportSet(address indexed asset, bool supported);
    event MaxSliceSet(uint16 maxSliceBps);
    event ComplianceSet(address indexed compliance);

    error ZeroAddress();
    error InvalidSlice();
    error TooManyAssets();
    error LengthMismatch();
    error UnsupportedAsset(address asset);
    error DuplicateAsset(address asset);
    error BadWeights();
    error NotAllowed(address account);

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ----------------------------------------------------------------------------------------------
    // Worker
    // ----------------------------------------------------------------------------------------------

    /// @notice Set the slice rule. Pass sliceBps = 0 and empty arrays to keep 100% in stablecoin.
    function setSlice(uint16 sliceBps, address[] calldata assets, uint16[] calldata weights) external {
        if (sliceBps > maxSliceBps) revert InvalidSlice();
        if (assets.length != weights.length) revert LengthMismatch();
        if (assets.length > MAX_ASSETS) revert TooManyAssets();
        if (sliceBps != 0 && assets.length == 0) revert InvalidSlice();
        if (sliceBps != 0) {
            IComplianceRegistry c = compliance;
            if (address(c) != address(0) && !c.isAllowed(msg.sender)) revert NotAllowed(msg.sender);
        }

        uint256 sum = 0;
        for (uint256 i; i < assets.length; ++i) {
            if (!isSupportedAsset[assets[i]]) revert UnsupportedAsset(assets[i]);
            if (weights[i] == 0) revert BadWeights();
            for (uint256 j; j < i; ++j) {
                if (assets[j] == assets[i]) revert DuplicateAsset(assets[i]);
            }
            sum += weights[i];
        }
        if (assets.length != 0 && sum != BPS) revert BadWeights();

        Allocation storage a = _alloc[msg.sender];
        a.sliceBps = sliceBps;
        a.assets = assets;
        a.weights = weights;
        emit SliceSet(msg.sender, sliceBps, assets, weights);
    }

    /// @notice Allow anyone (e.g. the weekly keeper) to trigger withdrawals on your streams. Funds always go
    ///         to you; this only lets your slice be harvested into the weekly batch without you transacting.
    function setAutoHarvest(bool enabled) external {
        _alloc[msg.sender].autoHarvest = enabled;
        emit AutoHarvestSet(msg.sender, enabled);
    }

    // ----------------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------------

    /// @notice Split a withdrawal into the stablecoin part and the part queued for conversion.
    ///         Assets that have since been de-listed are ignored (their weight stays in stablecoin).
    function split(address worker, uint256 amount) external view returns (uint256 stablePart, uint256 slicePart) {
        Allocation storage a = _alloc[worker];
        uint16 bps = a.sliceBps > maxSliceBps ? maxSliceBps : a.sliceBps;
        if (bps == 0 || a.assets.length == 0) return (amount, 0);
        uint256 supportedWeight = 0;
        for (uint256 i; i < a.assets.length; ++i) {
            if (isSupportedAsset[a.assets[i]]) supportedWeight += a.weights[i];
        }
        slicePart = (amount * bps * supportedWeight) / (uint256(BPS) * BPS);
        stablePart = amount - slicePart;
    }

    /// @notice Effective allocation with de-listed assets removed (weights renormalised by the converter).
    function allocationOf(address worker)
        external
        view
        returns (uint16 sliceBps, address[] memory assets, uint16[] memory weights)
    {
        Allocation storage a = _alloc[worker];
        uint256 len = a.assets.length;
        uint256 n = 0;
        for (uint256 i; i < len; ++i) {
            if (isSupportedAsset[a.assets[i]]) ++n;
        }
        assets = new address[](n);
        weights = new uint16[](n);
        uint256 k = 0;
        for (uint256 i; i < len; ++i) {
            if (isSupportedAsset[a.assets[i]]) {
                assets[k] = a.assets[i];
                weights[k] = a.weights[i];
                ++k;
            }
        }
        sliceBps = n == 0 ? 0 : (a.sliceBps > maxSliceBps ? maxSliceBps : a.sliceBps);
    }

    /// @notice Raw stored rule (for UIs).
    function rawAllocationOf(address worker) external view returns (Allocation memory) {
        return _alloc[worker];
    }

    function autoHarvest(address worker) external view returns (bool) {
        return _alloc[worker].autoHarvest;
    }

    function supportedAssets() external view returns (address[] memory list) {
        uint256 len = _assetList.length;
        uint256 n = 0;
        for (uint256 i; i < len; ++i) {
            if (isSupportedAsset[_assetList[i]]) ++n;
        }
        list = new address[](n);
        uint256 k = 0;
        for (uint256 i; i < len; ++i) {
            if (isSupportedAsset[_assetList[i]]) list[k++] = _assetList[i];
        }
    }

    // ----------------------------------------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------------------------------------

    /// @notice Timelock lists/de-lists an asset. The guardian may only de-list (the safe direction).
    function setAssetSupport(address asset, bool supported) external {
        if (asset == address(0)) revert ZeroAddress();
        if (supported || !hasRole(GUARDIAN_ROLE, msg.sender)) {
            _checkRole(DEFAULT_ADMIN_ROLE);
        }
        isSupportedAsset[asset] = supported;
        if (supported && !_listed[asset]) {
            _listed[asset] = true;
            _assetList.push(asset);
        }
        emit AssetSupportSet(asset, supported);
    }

    function setMaxSliceBps(uint16 maxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxBps > BPS) revert InvalidSlice();
        maxSliceBps = maxBps;
        emit MaxSliceSet(maxBps);
    }

    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ComplianceSet(registry);
    }
}
