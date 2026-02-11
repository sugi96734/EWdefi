// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EWdefi — Reserve accrual and utilization-based rates; liquidation via discount collateral seizure.
/// @notice Money market with supply, variable borrow, and liquidation; oracle-set prices and in-contract rate curve.
contract EWdefi {
    uint256 public constant WAD = 1e18;
    uint256 public constant RAY = 1e27;
    uint256 public constant PROTOCOL_FEE_BP = 120;
    uint256 public constant BP_DENOM = 10_000;
    uint256 public constant MIN_HEALTH_WAD = 1e18;
    uint256 public constant RATE_SLOPE_1_RAY = 0.04e27;
    uint256 public constant RATE_SLOPE_2_RAY = 0.60e27;
    uint256 public constant OPTIMAL_UTIL_RAY = 0.80e27;
    uint256 public constant BASE_RATE_RAY = 1e25;

    address public immutable poolGuardian;
    address public immutable protocolTreasury;
    address public immutable rateAdmin;

    struct ReserveParams {
        bool active;
        bool frozen;
        uint256 collateralFactorWad;
        uint256 liquidationThresholdWad;
        uint256 liquidationBonusWad;
    }

    struct ReserveState {
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 supplyIndexRay;
        uint256 borrowIndexRay;
        uint256 lastUpdateBlock;
    }

    struct UserPosition {
        uint256 supplyBalance;
        uint256 borrowBalance;
        uint256 supplyIndexSnapshot;
        uint256 borrowIndexSnapshot;
        bool useAsCollateral;
    }

    mapping(address => ReserveParams) public reserveParams;
    mapping(address => ReserveState) public reserveState;
    mapping(address => mapping(address => UserPosition)) public userPosition;
    mapping(address => uint256) public reserveListIndex;
    address[] public reserveList;
    mapping(address => uint256) public priceWad;
    uint256 private _reentrancyLock;

    error EWdefi_NotGuardian();
    error EWdefi_NotRateAdmin();
    error EWdefi_ReserveInactive();
    error EWdefi_ReserveFrozen();
    error EWdefi_ZeroAmount();
    error EWdefi_InvalidAsset();
    error EWdefi_AlreadyListed();
    error EWdefi_NotListed();
    error EWdefi_HealthBelowOne();
    error EWdefi_InsufficientSupply();
    error EWdefi_InsufficientDebt();
