// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IProxyWalletRegistry {
  function build() external returns (address payable _proxy);
}

interface IProxyWallet {
  function execute(address target, bytes memory _data) external payable returns (address _target, bytes memory _response);
}

interface IPositionManager {
  function positions(uint256 positionId) external view returns (address positionHandler);
  function ownerFirstPositionId(address owner) external view returns (uint256);
}

interface IBookKeeper {
  function positions(bytes32 collateralPoolId, address positinHandler) external view returns (uint256 lockedCollateral, uint256 debtShare);
}

interface IIbTokenAdapter {
  function netPendingRewards(address positionHandler) external view returns (uint256);
}

interface IStableSwapModule {
  function swapTokenToStablecoin(address _usr,uint256 _tokenAmount) external;
}
