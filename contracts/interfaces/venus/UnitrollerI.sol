// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./VTokenI.sol";

interface UnitrollerI {
  function enterMarkets(address [] calldata vTokens) external returns (uint[] memory);
  function exitMarket(address vToken) external returns (uint);

  function mintAllowed(address vToken, address minter, uint256 mintAmount) external returns (uint256);
  function mintVerify(address vToken, address minter, uint256 mintAmount, uint256 mintTokens) external;

  function redeemAllowed(address vToken, address redeemer, uint256 redeemTokens) external returns (uint256);
  function redeemVerify(address vToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external;

  function borrowAllowed(address vToken, address borrower, uint256 borrowAmount) external returns (uint256);
  function borrowVerify(address vToken, address borrower, uint256 borrowAmount) external;

  function repayBorrowAllowed(address vToken, address payer, address borrower, uint256 repayAmount) external returns (uint256);
  function repayBorrowVerify(address vToken, address payer, address borrower, uint256 repayAmount, uint256 borrowerIndex) external;

  function liquidateBorrowAllowed(
    address vTokenBorrowed,
    address vTokenCollateral,
    address liquidator,
    address borrower,
    uint256 repayAmount
  ) external returns (uint256);

  function liquidateBorrowVerify(
    address vTokenBorrowed,
    address vTokenCollateral,
    address liquidator,
    address borrower,
    uint256 repayAmount,
    uint256 seizeTokens
  ) external;

  function seizeAllowed(
    address vTokenCollateral,
    address vTokenBorrowed,
    address liquidator,
    address borrower,
    uint256 seizeTokens
  ) external returns (uint256);

  function seizeVerify(
    address vTokenCollateral,
    address vTokenBorrowed,
    address liquidator,
    address borrower,
    uint256 seizeTokens
  ) external;

  function transferAllowed(
    address vToken,
    address src,
    address dst,
    uint256 transferTokens
  ) external returns (uint256);

  function transferVerify(
    address vToken,
    address src,
    address dst,
    uint256 transferTokens
  ) external;

  function liquidateCalculateSeizeTokens(
    address vTokenBorrowed,
    address vTokenCollateral,
    uint256 repayAmount
  ) external view returns (uint256, uint256);

  function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);

  function claimVenus(address holder) external;
  function claimVenus(address holder, VTokenI[] memory vTokens) external;

  function markets(address vToken) external view returns (bool, uint256, bool);

  function venusSpeeds(address vtoken) external view returns (uint256);
}
