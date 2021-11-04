// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IAutoFarmV2 {
  function deposit(address user, uint256 pid, uint256 amount) external;
  function withdraw(uint256 pid, uint256 amount) external;
  function withdrawAll(uint256 pid) external;
  function stakedWantTokens(uint256 pid, address user) external view returns (uint256);
  function pendingAUTO(uint256 pid, address user) external view returns (uint256);
}