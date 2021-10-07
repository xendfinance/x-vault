// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./BaseStrategy.sol";
import "../interfaces/alpaca/IVault.sol";

// 96.39229 Thu 07 Oct 2021 03:44:04 AM CST

contract Strategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  IAlpacaVault public alpacaVault;

  constructor(address _vault, address _ibToken) public BaseStrategy(_vault) {
    alpacaVault = IAlpacaVault(_ibToken);
  }

  function name() external override view returns (string memory) {
    return "StrategyAlpacaAutofarm";
  }

  function delegatedAssets() external override pure returns (uint256) {
    return 0;
  }

  function estimatedTotalAssets() public override view returns (uint256) {
    return 0;
  }

}