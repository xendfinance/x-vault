// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./BaseStrategy.sol";
import "../interfaces/alpaca/IVault.sol";
import "../interfaces/autofarm/IAutoFarmV2.sol";

// 96.39229 Thu 07 Oct 2021 03:44:04 AM CST

contract Strategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  IAlpacaVault public alpacaVault;
  IAutoFarmV2 public autofarm;
  uint256 constant private poolId = 489;
  address public constant auto = address(0xa184088a740c695E156F91f5cC086a06bb78b827);
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

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
    // the ibUSDT pool id of autofarm is 489
    uint256 depositBalanceAutoFarm = autofarm.stakedWantTokens(poolId, address(this));
    uint256 claimableAuto = autofarm.pendingAuto(poolId, address(this));
    uint256 currentAuto = IERC(auto).balanceOf(address(this));

    uint256 estimatedWant = priceCheck(auto, address(want), _claimableAuto.add(currentAuto));
    return 0;
  }

  function priceCheck(address start, address end, uint256 _amount) public view returns (uint256) {
    if (_amount == 0) {
      return 0;
    }

    address[] memory path;
    if (start == wbnb) {
      path = new address[](2);
      path[0] = wbnb;
      path[1] = end;
    } else {
      path = new address[](3);
      path[0] = start;
      path[1] = wbnb;
      path[2] = end;
    }

    uint256[] memory amounts = IUniswapV2Router02(uniswapRouter).getAmountsOut(_amount, path);
    return amounts[amounts.length - 1];
  }

}