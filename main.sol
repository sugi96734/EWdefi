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
        return BASE_RATE_RAY + RATE_SLOPE_1_RAY + (excess * RATE_SLOPE_2_RAY) / (RAY - OPTIMAL_UTIL_RAY);
    }

    function _scaleBalance(uint256 balance, uint256 indexSnapshot, uint256 indexCurrent) internal pure returns (uint256) {
        return (balance * indexCurrent) / indexSnapshot;
    }

    function supply(address asset, uint256 amount, bool useAsCollateral) external nonReentrant whenReserveActive(asset) {
        if (amount == 0) revert EWdefi_ZeroAmount();
        _accrueReserve(asset);

        ReserveState storage rs = reserveState[asset];
        UserPosition storage pos = userPosition[msg.sender][asset];
        if (pos.supplyIndexSnapshot == 0) pos.supplyIndexSnapshot = rs.supplyIndexRay;
        uint256 scaled = (amount * RAY) / rs.supplyIndexRay;
        pos.supplyBalance += scaled;
        pos.supplyIndexSnapshot = rs.supplyIndexRay;
        if (useAsCollateral) pos.useAsCollateral = true;
        rs.totalSupply += amount;

        _pull(asset, msg.sender, amount);
        emit SupplyDeposited(msg.sender, asset, amount);
    }

    function withdraw(address asset, uint256 amount) external nonReentrant whenReserveActive(asset) {
        if (amount == 0) revert EWdefi_ZeroAmount();
        _accrueReserve(asset);

        ReserveState storage rs = reserveState[asset];
        UserPosition storage pos = userPosition[msg.sender][asset];
        uint256 scaledDebt = (amount * RAY) / rs.supplyIndexRay;
        if (pos.supplyBalance < scaledDebt) revert EWdefi_InsufficientSupply();
        pos.supplyBalance -= scaledDebt;
        pos.supplyIndexSnapshot = rs.supplyIndexRay;
        rs.totalSupply -= amount;

        _ensureHealthy(msg.sender);
        _push(asset, msg.sender, amount);
        emit SupplyWithdrawn(msg.sender, asset, amount);
    }

    function borrow(address asset, uint256 amount) external nonReentrant whenReserveActive(asset) {
        if (amount == 0) revert EWdefi_ZeroAmount();
        if (priceWad[asset] == 0) revert EWdefi_NoPrice();
        _accrueReserve(asset);

        ReserveState storage rs = reserveState[asset];
        uint256 rateRay = _borrowRateRay((rs.totalBorrow * RAY) / (rs.totalSupply == 0 ? 1 : rs.totalSupply));
        UserPosition storage pos = userPosition[msg.sender][asset];
        if (pos.borrowIndexSnapshot == 0) pos.borrowIndexSnapshot = rs.borrowIndexRay;
        uint256 scaled = (amount * RAY) / rs.borrowIndexRay;
        pos.borrowBalance += scaled;
        pos.borrowIndexSnapshot = rs.borrowIndexRay;
        rs.totalBorrow += amount;

        _ensureHealthy(msg.sender);
        _push(asset, msg.sender, amount);
        emit BorrowDrawn(msg.sender, asset, amount, rateRay);
    }

    function repay(address asset, uint256 amount) external nonReentrant whenReserveActive(asset) {
        if (amount == 0) revert EWdefi_ZeroAmount();
        _accrueReserve(asset);

        ReserveState storage rs = reserveState[asset];
        UserPosition storage pos = userPosition[msg.sender][asset];
        uint256 debtScaled = pos.borrowBalance;
        uint256 debtRaw = (debtScaled * rs.borrowIndexRay) / RAY;
        if (debtRaw == 0) revert EWdefi_InsufficientDebt();
        uint256 pay = amount > debtRaw ? debtRaw : amount;
        uint256 payScaled = (pay * RAY) / rs.borrowIndexRay;
        pos.borrowBalance -= payScaled;
        pos.borrowIndexSnapshot = rs.borrowIndexRay;
        rs.totalBorrow -= pay;

        _pull(asset, msg.sender, pay);
        emit BorrowRepaid(msg.sender, asset, pay);
    }

    function liquidate(address collateralAsset, address debtAsset, address user, uint256 debtToCover) external nonReentrant whenReserveActive(collateralAsset) whenReserveActive(debtAsset) {
        if (debtToCover == 0) revert EWdefi_ZeroAmount();
        if (_healthFactorWad(user) >= MIN_HEALTH_WAD) revert EWdefi_UserHealthy();
        if (priceWad[collateralAsset] == 0 || priceWad[debtAsset] == 0) revert EWdefi_NoPrice();

        _accrueReserve(collateralAsset);
        _accrueReserve(debtAsset);

        ReserveState storage rsDebt = reserveState[debtAsset];
        UserPosition storage debtPos = userPosition[user][debtAsset];
        uint256 userDebtRaw = (debtPos.borrowBalance * rsDebt.borrowIndexRay) / RAY;
        if (userDebtRaw == 0) revert EWdefi_InsufficientDebt();
        uint256 cover = debtToCover > userDebtRaw ? userDebtRaw : debtToCover;

        _pull(debtAsset, msg.sender, cover);
        debtPos.borrowBalance -= (cover * RAY) / rsDebt.borrowIndexRay;
        debtPos.borrowIndexSnapshot = rsDebt.borrowIndexRay;
        rsDebt.totalBorrow -= cover;

        ReserveParams storage rpCol = reserveParams[collateralAsset];
        uint256 collateralSeized = (cover * priceWad[debtAsset] * rpCol.liquidationBonusWad) / (priceWad[collateralAsset] * WAD);
        UserPosition storage colPos = userPosition[user][collateralAsset];
        ReserveState storage rsCol = reserveState[collateralAsset];
        uint256 colRaw = (colPos.supplyBalance * rsCol.supplyIndexRay) / RAY;
        if (collateralSeized > colRaw) revert EWdefi_ExceedsCollateral();
        colPos.supplyBalance -= (collateralSeized * RAY) / rsCol.supplyIndexRay;
        colPos.supplyIndexSnapshot = rsCol.supplyIndexRay;
        rsCol.totalSupply -= collateralSeized;

        _push(collateralAsset, msg.sender, collateralSeized);
        emit PositionLiquidated(msg.sender, user, collateralAsset, debtAsset, cover, collateralSeized);
    }

    function _ensureHealthy(address user) internal view {
        if (_healthFactorWad(user) < MIN_HEALTH_WAD) revert EWdefi_HealthBelowOne();
    }

    function _healthFactorWad(address user) internal view returns (uint256) {
        (uint256 collateralEth, uint256 debtEth) = _accountData(user);
        if (debtEth == 0) return type(uint256).max;
        return (collateralEth * WAD) / debtEth;
    }

    function _accountData(address user) internal view returns (uint256 collateralEth, uint256 debtEth) {
        for (uint256 i = 0; i < reserveList.length; i++) {
            address asset = reserveList[i];
            ReserveParams storage rp = reserveParams[asset];
