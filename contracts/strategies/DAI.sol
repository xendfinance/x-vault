// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

contract Strategy is BaseStrategy, FlashLoanBase, ICallee {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  address private constant SOLO = 0x00;     // Flash Loan Provider Address

  UnitrollerI public constant venus = UnitrollerI(venus_address);

  address public constant xvs = address();

}