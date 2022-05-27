// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IProxyWalletRegistry {
  function build() external returns (address payable _proxy);
}

interface IProxyWallet {
  function execute(address target, bytes memory _data) external payable returns (address _target, bytes memory _response);
}

interface IPositionManager {
  function positions(uint256 positionId) external view returns (address positionHandler);
  function ownerFirstPositionId(address owner) external view returns (uint256);
  function collateralPoolConfig() external view returns (address);
}

interface IBookKeeper {
  function positions(bytes32 collateralPoolId, address positionAddress) external view returns (
    uint256 lockedCollateral, // [wad]
    uint256 debtShare // [wad]
  );

  function collateralPoolConfig() external view returns (address);
}

interface IIbTokenAdapter {
  function netPendingRewards(address positionHandler) external view returns (uint256);
}

interface IStableSwapModule {
  function swapTokenToStablecoin(address _usr,uint256 _tokenAmount) external;
}

interface ICollateralPoolConfig {
  struct CollateralPool {
    uint256 totalDebtShare; // Total debt share of Alpaca Stablecoin of this collateral pool              [wad]
    uint256 debtAccumulatedRate; // Accumulated rates (equivalent to ibToken Price)                       [ray]
    uint256 priceWithSafetyMargin; // Price with safety margin (taken into account the Collateral Ratio)  [ray]
    uint256 debtCeiling; // Debt ceiling of this collateral pool                                          [rad]
    uint256 debtFloor; // Position debt floor of this collateral pool                                     [rad]
    address priceFeed; // Price Feed
    uint256 liquidationRatio; // Liquidation ratio or Collateral ratio                                    [ray]
    uint256 stabilityFeeRate; // Collateral-specific, per-second stability fee debtAccumulatedRate or mint interest debtAccumulatedRate [ray]
    uint256 lastAccumulationTime; // Time of last call to `collect`                                       [unix epoch time]
    address adapter;
    uint256 closeFactorBps; // Percentage (BPS) of how much  of debt could be liquidated in a single liquidation
    uint256 liquidatorIncentiveBps; // Percentage (BPS) of how much additional collateral will be given to the liquidator incentive
    uint256 treasuryFeesBps; // Percentage (BPS) of how much additional collateral will be transferred to the treasury
    address strategy; // Liquidation strategy for this collateral pool
  }

  function collateralPools(bytes32 _collateralPoolId) external view returns (CollateralPool memory);

  function getDebtAccumulatedRate(bytes32 _collateralPoolId) external view returns (uint256);

  function getPriceFeed(bytes32 _collateralPoolId) external view returns (address);

  function getLiquidationRatio(bytes32 _collateralPoolId) external view returns (uint256);

  function getStabilityFeeRate(bytes32 _collateralPoolId) external view returns (uint256);
}
