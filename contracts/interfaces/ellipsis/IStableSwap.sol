// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IStableSwap {
  function exchange_underlying(uint128 i, uint128 j, uint256 dx, uint256 dy) external returns (uint256);
}
