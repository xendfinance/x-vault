// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IProxyWalletRegistry {
  function build() external returns (address payable _proxy);
}

interface IProxyWallet {
  function execute(address target, bytes memory _data) external payable returns (address _target, bytes memory _response);
}

interface IPositionManager {
  function ownerFirstPositionId(address owner) external view returns (uint256);
}
