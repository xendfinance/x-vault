// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IFlashLoanReceiver {
  function executeOperation(address sender, address underlying, uint amount, uint fee, bytes calldata params) external;
}

interface ICTokenFlashloan {
  function flashLoan(address receiver, uint amount, bytes calldata params) external;
}