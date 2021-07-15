// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./InterestRateModel.sol";

interface VTokenI {
  event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);
  
  event Mint(address minter, uint mintAmount, uint mintTokens);
  
  event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);
  
  event Borrow(address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);
  
  event RepayBorrow(address payer, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);
  
  event LiquidateBorrow(address liquidator, address borrower, uint repayAmount, address vTokenCollateral, uint seizeTokens);
  
  event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
  
  event NewAdmin(address oldAdmin, address newAdmin);
  
  event NewReserveFactor(uint oldReserveFactorMantissa, uint newReserveFactorMantissa);
  
  event ReservesAdded(address benefactor, uint addAmount, uint newTotalReserves);
  
  event ReservesReduced(address admin, uint reduceAmount, uint newTotalReserves);
  
  event Transfer(address indexed from, address indexed to, uint amount);
  
  event Approval(address indexed owner, address indexed spender, uint amount);
  
  event Failure(uint error, uint info, uint detail);

  
  function transfer(address dst, uint amount) external returns (bool);
  
  function transferFrom(address src, address dst, uint amount) external returns (bool);
  
  function approve(address spender, uint amount) external returns (bool);
  
  function allowance(address owner, address spender) external view returns (uint);
  
  function balanceOf(address owner) external view returns (uint);
  
  function balanceOfUnderlying(address owner) external returns (uint);
  
  function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint);
  
  function borrowRatePerBlock() external view returns (uint);
  
  function supplyRatePerBlock() external view returns (uint);
  
  function totalBorrowsCurrent() external returns (uint);
  
  function borrowBalanceCurrent(address account) external returns (uint);
  
  function borrowBalanceStored(address account) external view returns (uint);

  function exchangeRateCurrent() external returns (uint);
  
  function exchangeRateStored() external view returns (uint);

  function getCash() external view returns (uint);

  function accrueInterest() external returns (uint);

  function totalReserves() external view returns (uint);

  function accrualBlockNumber() external view returns (uint);

  function interestRateModel() external view returns (InterestRateModel);

  function reserveFactorMantissa() external view returns (uint);

  function seize(address liquidator, address borrower, uint seizeTokens) external returns (uint);

  function totalBorrows() external view returns (uint);

  function totalSupply() external view returns (uint);
}