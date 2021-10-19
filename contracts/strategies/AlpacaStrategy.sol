// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./BaseStrategy.sol";
import "../interfaces/alpaca/IVault.sol";
import "../interfaces/autofarm/IAutoFarmV2.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";

contract Strategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  IAlpacaVault public alpacaVault;
  IAutoFarmV2 public autofarm = IAutoFarmV2(0x0895196562C7868C5Be92459FaE7f877ED450452);
  uint256 constant private poolId = 489;  // the ibUSDT pool id of autofarm is 489
  address public constant autoToken = address(0xa184088a740c695E156F91f5cC086a06bb78b827);
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
  address public constant ibUsdt = address(0x158Da805682BdC8ee32d52833aD41E74bb951E59);

  address public constant uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);

  uint256 public minAutoToSell = 1e10;
  bool public forceMigrate = false;

  modifier management(){
    require(msg.sender == governance() || msg.sender == strategist, "!management");
    _;
  }

  constructor(address _vault, address _ibToken) public BaseStrategy(_vault) {
    alpacaVault = IAlpacaVault(_ibToken);
    maxReportDelay = 3600 * 24;
  }

  function name() external override view returns (string memory) {
    return "StrategyAlpacaAutofarm";
  }

  function delegatedAssets() external override pure returns (uint256) {
    return 0;
  }

  function setForceMigrate(bool _force) external onlyGovernance {
    forceMigrate = _force;
  }

  function setMinAutoToSell(uint256 _minAutoToSell) external management {
    minAutoToSell = _minAutoToSell;
  }

  function estimatedTotalAssets() public override view returns (uint256) {
    uint256 depositBalanceAutoFarm = autofarm.stakedWantTokens(poolId, address(this));
    uint256 assets = alpacaVault.debtShareToVal(alpacaVault.balanceOf(address(this)).add(depositBalanceAutoFarm));
    uint256 claimableAuto = autofarm.pendingAuto(poolId, address(this));
    uint256 currentAuto = IERC20(autoToken).balanceOf(address(this));

    uint256 estimatedWant = priceCheck(autoToken, address(want), claimableAuto.add(currentAuto));
    uint256 conservativeWant = estimatedWant.mul(9).div(10);      // remaining 10% will be used for compensate offset

    return want.balanceOf(address(this)).add(assets).add(conservativeWant);
  }

  /**
   * View how much the vault expect this strategy to return at the current block, based on its present performance (since its last report)
   */
  function expectedReturn() public view returns (uint256) {
    uint256 estimatedAssets = estimatedTotalAssets();

    uint256 debt = vault.strategies(address(this)).totalDebt;
    if (debt > estimatedAssets) {
      return 0;
    } else {
      return estimatedAssets - debt;
    }
  }

  function tendTrigger(uint256 gasCost) public override view returns (bool) {
    return false;
  }

  /**
   * @notice
   *  Provide a signal to the keeper that harvest should be called.
   *  The keeper will provide the estimated gas cost that they would pay to call
   *  harvest() function.
   */
  function harvestTrigger(uint256 gasCost) public override view returns (bool) {
    StrategyParams memory params = vault.strategies(address(this));
    
    if (params.activation == 0) return false;

    uint256 wantGasCost = priceCheck(wbnb, address(want), gasCost);
    uint256 autoGasCost = priceCheck(wbnb, autoToken, gasCost);

    uint256 _claimableAuto = autofarm.pendingAuto(poolId, address(this));

    if (_claimableAuto > minAutoToSell) {
      // trigger harvest if AUTO token balance is worth to do swap
      if (_claimableAuto.add(IERC20(autoToken).balanceOf(address(this))) > autoGasCost.mul(profitFactor)) {
        return true;
      }
    }

    uint256 outstanding = vault.debtOutstanding(address(this));
    if (outstanding > wantGasCost.mul(profitFactor)) return true;

    uint256 total = estimatedTotalAssets();
    uint256 profit = 0;
    if (total > params.totalDebt) profit = total.sub(params.totalDebt);

    uint256 credit = vault.creditAvailable().add(profit);
    return (wantGasCost.mul(profitFactor) < credit);
  }

  /**
   * Do anything necessary to prepare this Strategy for migration, such as transferring any reserve.
   */
  function prepareMigration(address _newStrategy) internal override {
    if (!forceMigrate) {
      autofarm.withdrawAll(poolId);
      alpacaVault.withdraw(IERC20(ibUsdt).balanceOf(address(this)));
      
      IERC20 _auto = IERC20(autoToken);
      uint _autoBalance = _auto.balanceOf(address(this));
      if (_autoBalance > 0) {
        _auto.safeTransfer(_newStrategy, _autoBalance);
      }
    }
  }

  function distributeRewards() internal override {}

  function prepareReturn(uint256 _debtOutstanding) internal override returns (
    uint256 _profit,
    uint256 _loss,
    uint256 _debtPayment
  ) {
    _profit = 0;
    _loss = 0;

    if (autofarm.stakedWantTokens(poolId, address(this)) == 0) {
      uint256 wantBalance = want.balanceOf(address(this));
      _debtPayment = _min(wantBalance, _debtOutstanding);
      return (_profit, _loss, _debtPayment);
    }

    _claimAuto();
    _disposeAuto();

    uint256 wantBalance = want.balanceOf(address(this));

    uint256 ibTokenBalance = autofarm.stakedWantTokens(poolId, address(this));
    uint256 assetBalance = alpacaVault.debtShareToVal(ibTokenBalance).add(wantBalance);
    uint256 debt = vault.strategies(address(this)).totalDebt;

    if (assetBalance > debt) {
      _profit = assetBalance - debt;
    } else {
      _loss = debt - assetBalance;
    }
    _debtPayment = _min(_debtOutstanding, _profit);
  }

  function adjustPosition(uint256 _debtOutstanding) internal override {
    if (emergencyExit) {
      return;
    }

    uint256 _wantBal = want.balanceOf(address(this));
    if (_wantBal < _debtOutstanding) {
      uint256 _needed = _debtOutstanding.sub(_wantBal);
      _withdrawSome(_needed);
      return;
    }
  }

  function _withdrawSome(uint256 _amount) internal {
    uint256 _amountShare = alpacaVault.debtValToShare(_amount);
    autofarm.withdraw(poolId, _amountShare);
    alpacaVault.withdraw(IERC20(ibUsdt).balanceOf(address(this)));
    _disposeAuto();
  }

  // claims AUTO reward token
  function _claimAuto() internal {
    autofarm.withdraw(poolId, uint256(0));
  }

  // sell harvested AUTO token
  function _disposeAuto() internal {
    uint256 _auto = IERC20(autoToken).balanceOf(address(this));

    if (_auto > minAutoToSell) {
      address[] memory path = new address[](3);
      path[0] = autoToken;
      path[1] = wbnb;
      path[2] = address(want);

      IUniswapV2Router02(uniswapRouter).swapExactTokensForTokens(_auto, uint256(0), path, address(this), now);
    }
  }

  function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
    uint256 staked = autofarm.stakedWantTokens(poolId, address(this));
    uint256 assets = alpacaVault.debtShareToVal(staked);

    uint256 debtOutstanding = vault.debtOutstanding(address(this));
    if (debtOutstanding > assets) {
      _loss = debtOutstanding - assets;
    }

    _withdrawSome(_min(assets, _amountNeeded));
    _amountFreed = _min(_amountNeeded, want.balanceOf(address(this)));
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

  function setProtectedTokens() internal override {
    protected[autoToken] = true;
  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

}