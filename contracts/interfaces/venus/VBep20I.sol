// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./VTokenI.sol";

interface VBep20I is VTokenI {
  function mint(uint mintAmount) external returns (uint);
  function redeem(uint redeemTokens) external returns (uint);
  function redeemUnderlying(uint redeemAmount) external returns (uint);
  function borrow(uint borrowAmount) external returns (uint);
  function repayBorrow(uint repayAmount) external returns (uint);
  function repayBorrowBehalf(address borrower, uint repayAmount) external returns (uint);
  function liquidateBorrow(address borrower, uint repayAmount, VTokenI vTokenCollateral) external returns (uint);
}