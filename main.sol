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
    error EWdefi_TransferFailed();
    error EWdefi_Reentrancy();
    error EWdefi_InvalidConfig();
    error EWdefi_NoPrice();
    error EWdefi_UserHealthy();
    error EWdefi_ExceedsCollateral();

    event ReserveListed(address indexed asset, uint256 collateralFactorWad, uint256 liquidationThresholdWad);
    event SupplyDeposited(address indexed user, address indexed asset, uint256 amount);
    event SupplyWithdrawn(address indexed user, address indexed asset, uint256 amount);
    event BorrowDrawn(address indexed user, address indexed asset, uint256 amount, uint256 rateRay);
    event BorrowRepaid(address indexed user, address indexed asset, uint256 amount);
    event PositionLiquidated(address indexed liquidator, address indexed user, address collateralAsset, address debtAsset, uint256 debtCovered, uint256 collateralSeized);
    event PriceUpdated(address indexed asset, uint256 priceWad);
    event ReserveFrozenToggled(address indexed asset, bool frozen);

    constructor() {
        poolGuardian = address(0x6E3f8a1B2c4D5e6F7a8B9c0D1e2F3a4B5c6D7e8F9);
        protocolTreasury = address(0x7F4a9B0c1D2e3F4a5B6c7D8e9F0a1B2c3D4e5F6);
        rateAdmin = address(0x801b2C3d4E5f6A7b8C9d0E1f2A3b4C5d6E7f8A9);

        address seedAsset = address(0x912c3D4e5F6a7B8c9D0e1F2a3B4c5D6e7F8a9B0);
        reserveParams[seedAsset] = ReserveParams({
            active: true,
            frozen: false,
            collateralFactorWad: 0.78e18,
            liquidationThresholdWad: 0.82e18,
            liquidationBonusWad: 1.07e18
        });
        reserveState[seedAsset] = ReserveState({
            totalSupply: 0,
            totalBorrow: 0,
            supplyIndexRay: RAY,
            borrowIndexRay: RAY,
            lastUpdateBlock: block.number
        });
        reserveList.push(seedAsset);
        reserveListIndex[seedAsset] = 1;
        priceWad[seedAsset] = 1e18;
    }

    modifier onlyGuardian() {
        if (msg.sender != poolGuardian) revert EWdefi_NotGuardian();
        _;
    }

    modifier onlyRateAdmin() {
        if (msg.sender != rateAdmin) revert EWdefi_NotRateAdmin();
        _;
    }

    modifier whenReserveActive(address asset) {
        if (!reserveParams[asset].active) revert EWdefi_ReserveInactive();
        if (reserveParams[asset].frozen) revert EWdefi_ReserveFrozen();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert EWdefi_Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    function listReserve(
        address asset,
        uint256 collateralFactorWad,
        uint256 liquidationThresholdWad,
        uint256 liquidationBonusWad
    ) external onlyGuardian {
        if (asset == address(0)) revert EWdefi_InvalidAsset();
        if (reserveListIndex[asset] != 0) revert EWdefi_AlreadyListed();
        if (collateralFactorWad > liquidationThresholdWad || liquidationBonusWad < WAD) revert EWdefi_InvalidConfig();

        reserveParams[asset] = ReserveParams({
            active: true,
            frozen: false,
            collateralFactorWad: collateralFactorWad,
            liquidationThresholdWad: liquidationThresholdWad,
            liquidationBonusWad: liquidationBonusWad
        });
        reserveState[asset] = ReserveState({
            totalSupply: 0,
            totalBorrow: 0,
            supplyIndexRay: RAY,
            borrowIndexRay: RAY,
            lastUpdateBlock: block.number
        });
        reserveList.push(asset);
        reserveListIndex[asset] = reserveList.length;
        emit ReserveListed(asset, collateralFactorWad, liquidationThresholdWad);
    }

    function setPrice(address asset, uint256 priceWad_) external onlyRateAdmin {
        if (asset == address(0)) revert EWdefi_InvalidAsset();
        priceWad[asset] = priceWad_;
        emit PriceUpdated(asset, priceWad_);
    }

    function setReserveFrozen(address asset, bool frozen) external onlyGuardian {
        if (reserveListIndex[asset] == 0) revert EWdefi_NotListed();
        reserveParams[asset].frozen = frozen;
        emit ReserveFrozenToggled(asset, frozen);
    }

    function _accrueReserve(address asset) internal {
        ReserveState storage rs = reserveState[asset];
        if (rs.lastUpdateBlock == block.number) return;
        uint256 totalSupply = rs.totalSupply;
        uint256 totalBorrow = rs.totalBorrow;
        if (totalSupply > 0 && totalBorrow > 0) {
            uint256 utilRay = (totalBorrow * RAY) / totalSupply;
            uint256 borrowRate = _borrowRateRay(utilRay);
            uint256 blocksElapsed = block.number - rs.lastUpdateBlock;
            rs.borrowIndexRay += (rs.borrowIndexRay * borrowRate * blocksElapsed) / (RAY * RAY);
            uint256 supplyRate = (borrowRate * totalBorrow) / totalSupply;
            rs.supplyIndexRay += (rs.supplyIndexRay * supplyRate * blocksElapsed) / (RAY * RAY);
        }
        rs.lastUpdateBlock = block.number;
    }

    function _borrowRateRay(uint256 utilRay) internal pure returns (uint256) {
        if (utilRay <= OPTIMAL_UTIL_RAY) {
            return BASE_RATE_RAY + (utilRay * RATE_SLOPE_1_RAY) / OPTIMAL_UTIL_RAY;
        }
        uint256 excess = utilRay - OPTIMAL_UTIL_RAY;
