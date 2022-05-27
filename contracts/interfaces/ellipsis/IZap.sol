// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IZap {
  function calc_withdraw_one_coin(address pool, uint256 token_amount, int128 index) external view returns (uint256);
  function calc_token_amount(address pool, uint256[4] memory amounts, bool is_deposit) external view returns (uint256);
  function add_liquidity(address pool, uint256[4] memory deposit_amounts, uint256 min_mint_amount) external returns (uint256);
  function remove_liquidity_one_coin(address pool, uint256 burn_amount, int128 i, uint256 min_amount) external returns (uint256);
}
