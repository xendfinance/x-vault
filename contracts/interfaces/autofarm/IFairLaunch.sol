// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IFairLaunch {
  function deposit(address user, uint256 pid, uint256 amount) external;
  function withdraw(address user, uint256 pid, uint256 amount) external;
  function harvest(uint256 pid) external;
}