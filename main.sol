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
