// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAlpacaVault is IERC20 {
  function deposit(uint256 amountToken) external payable;
  function withdraw(uint256 share) external;
  function debtValToShare(uint256 debtVal) external view returns (uint256);
  function debtShareToVal(uint256 debtShare) external view returns (uint256);
}