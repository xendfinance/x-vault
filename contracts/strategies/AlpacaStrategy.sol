// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./BaseStrategy.sol";
import "../interfaces/alpaca/IAlpacaVault.sol";
import "../interfaces/alpaca/IAlpacaFarm.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";

contract StrategyAlpacaFarm is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  IAlpacaVault public ibToken;
  address public constant alpacaToken = address(0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F);
  IAlpacaFarm public constant alpacaFarm = IAlpacaFarm(0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F);
  uint256 private poolId;             // the ibToken pool id of alpaca farm contract
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
  address[] public path;              // disposal path for alpaca token on uniswap

  address public constant uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);

  uint256 public minAlpacaToSell;
  bool public forceMigrate;
  bool private adjusted;              // flag whether position adjusting was done in prepareReturn 

  modifier management(){
    require(msg.sender == governance() || msg.sender == strategist, "!management");
    _;
  }

  function initialize(
    address _vault, 
    address _ibToken, 
    uint256 _poolId, 
    address[] memory _path
  ) public initializer {
    
    super.initialize(_vault);

    ibToken = IAlpacaVault(_ibToken);
    poolId = _poolId;
    path = _path;

    maxReportDelay = 24 * 3600;           // a day
    minAlpacaToSell = 1e10;

    want.safeApprove(address(ibToken), uint256(-1));
    IERC20(alpacaToken).safeApprove(address(uniswapRouter), uint256(-1));
    ibToken.approve(address(alpacaFarm), uint256(-1));
  }

  function name() external override view returns (string memory) {
    return "StrategyAlpacaFarm";
  }

  function setForceMigrate(bool _force) external onlyGovernance {
    forceMigrate = _force;
  }

  function setMinAutoToSell(uint256 _minAlpacaToSell) external management {
    minAlpacaToSell = _minAlpacaToSell;
  }

  function setDisposalPath(address[] memory _path) external management {
    path = _path;
  }

  /**
   *  An accurate estimate for the total amount of assets (principle + return)
   *  that this strategy is currently managing, denominated in terms of want tokens.
   */
  function estimatedTotalAssets() public override view returns (uint256) {
    (uint256 stakedBalance, , , ) = alpacaFarm.userInfo(poolId, address(this));
    uint256 assets = ibToken.debtShareToVal(ibToken.balanceOf(address(this)).add(stakedBalance));
    uint256 claimableAlpaca = alpacaFarm.pendingAlpaca(poolId, address(this));
    uint256 currentAlpaca = IERC20(alpacaToken).balanceOf(address(this));

    uint256 estimatedWant = priceCheck(alpacaToken, address(want), claimableAlpaca.add(currentAlpaca));
    uint256 conservativeWant = estimatedWant.mul(9).div(10);      // remaining 10% will be used for compensate offset

    return want.balanceOf(address(this)).add(assets).add(conservativeWant);
  }

  /**
   * View how much the vault expect this strategy to return at the current block, based on its present performance (since its last report)
   */
  function expectedReturn() public view returns (uint256) {
    uint256 estimatedAssets = estimatedTotalAssets();

    uint256 debt = vault.strategies(address(this)).totalDebt;
    if (debt >= estimatedAssets) {
      return 0;
    } else {
      return estimatedAssets - debt;
    }
  }

  /**
   *  The strategy don't need `tend` action, so just returns `false`.
   */
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
    uint256 alpacaGasCost = priceCheck(wbnb, alpacaToken, gasCost);

    uint256 _claimableAlpaca = alpacaFarm.pendingAlpaca(poolId, address(this));

    if (_claimableAlpaca > minAlpacaToSell) {
      // trigger harvest if AUTO token balance is worth to do swap
      if (_claimableAlpaca.add(IERC20(alpacaToken).balanceOf(address(this))) > alpacaGasCost.mul(profitFactor)) {
        return true;
      }
    }

    uint256 outstanding = vault.debtOutstanding(address(this));
    if (outstanding > wantGasCost.mul(profitFactor)) return true;

    uint256 total = estimatedTotalAssets();
    uint256 profit = 0;
    if (total > params.totalDebt) profit = total.sub(params.totalDebt);

    uint256 credit = vault.creditAvailable(address(this)).add(profit);
    return (wantGasCost.mul(profitFactor) < credit);
  }

  function farm() external {
    _farm();
  }

  /**
   * Do anything necessary to prepare this Strategy for migration, such as transferring any reserve.
   * This is used to migrate and withdraw assets from alpaca protocol under the ordinary condition.
   * Generally, `forceMigrate` is false so it forces to withdraw all assets from alpaca protocol and do migration.
   * but when facing issue with alpaca protocol so can't withdraw assets, then set forceMigrate true, so do migration without withdrawing assets from alpaca protocol
   */
  function prepareMigration(address _newStrategy) internal override {
    if (!forceMigrate) {
      alpacaFarm.withdrawAll(address(this), poolId);
      ibToken.withdraw(IERC20(ibToken).balanceOf(address(this)));
      
      IERC20 _alpaca = IERC20(alpacaToken);
      uint _alpacaBalance = _alpaca.balanceOf(address(this));
      if (_alpacaBalance > 0) {
        _alpaca.safeTransfer(_newStrategy, _alpacaBalance);
      }
    }
  }

  function prepareReturn(uint256 _debtOutstanding) internal override returns (
    uint256 _profit,
    uint256 _loss,
    uint256 _debtPayment
  ) {
    _profit = 0;
    _loss = 0;

    (uint256 stakedBalance, , , ) = alpacaFarm.userInfo(poolId, address(this));
    if (stakedBalance == 0) {
      uint256 wantBalance = want.balanceOf(address(this));
      _debtPayment = _min(wantBalance, _debtOutstanding);
      return (_profit, _loss, _debtPayment);
    }

    _claimAlpaca();
    _disposeAlpaca();

    uint256 wantBalance = want.balanceOf(address(this));

    uint256 assetBalance = ibToken.debtShareToVal(stakedBalance).add(wantBalance);
    uint256 debt = vault.strategies(address(this)).totalDebt;

    if (assetBalance > debt) {
      _profit = assetBalance - debt;
      if (wantBalance < _profit) {
        liquidatePosition(_profit.sub(wantBalance));
        adjusted = true;
        uint256 _wantBalance = want.balanceOf(address(this));
        if (_wantBalance < _profit) {
          // reserve is profit in case `profit` is greater than `_wantBalance`
          _profit = _wantBalance;
        }
      } else if (wantBalance > _profit.add(_debtOutstanding)) {
        _debtPayment = _debtOutstanding;
      } else {
        _debtPayment = wantBalance - _profit;
      }
    } else {
      _loss = debt - assetBalance;
    }
    _debtPayment = _min(_debtOutstanding, _profit);
  }

  function adjustPosition(uint256 _debtOutstanding) internal override {
    if (adjusted) {
      adjusted = false;
      return;
    }

    if (emergencyExit) {
      return;
    }

    uint256 _wantBal = want.balanceOf(address(this));
    if (_wantBal < _debtOutstanding) {
      uint256 _needed = _debtOutstanding.sub(_wantBal);
      _withdrawSome(_needed);
      return;
    }

    _farm();
  }

  function _farm() internal {
    uint256 _wantBal = want.balanceOf(address(this));
    ibToken.deposit(_wantBal);
    uint256 bal = ibToken.balanceOf(address(this));
    alpacaFarm.deposit(address(this), poolId, bal);
  }

  function _withdrawSome(uint256 _amount) internal {
    uint256 _amountShare = ibToken.debtValToShare(_amount);
    alpacaFarm.withdraw(address(this), poolId, _amountShare);
    ibToken.withdraw(IERC20(ibToken).balanceOf(address(this)));
    _disposeAlpaca();
  }

  // claims Alpaca reward token
  function _claimAlpaca() internal {
    alpacaFarm.harvest(poolId);
  }

  // sell harvested Alpaca token
  function _disposeAlpaca() internal {
    uint256 _alpaca = IERC20(alpacaToken).balanceOf(address(this));

    if (_alpaca > minAlpacaToSell) {

      uint256[] memory amounts = IUniswapV2Router02(uniswapRouter).getAmountsOut(_alpaca, path);
      uint256 estimatedWant = amounts[amounts.length - 1];
      uint256 conservativeWant = estimatedWant.mul(9).div(10);      // remaining 10% will be used for compensate offset

      IUniswapV2Router02(uniswapRouter).swapExactTokensForTokens(_alpaca, conservativeWant, path, address(this), now);
    }
  }

  function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
    (uint256 stakedBalance, , , ) = alpacaFarm.userInfo(poolId, address(this));
    uint256 assets = ibToken.debtShareToVal(stakedBalance);

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

    address[] memory _path;
    if (start == wbnb) {
      _path = new address[](2);
      _path[0] = wbnb;
      _path[1] = end;
    } else {
      _path = new address[](3);
      _path[0] = start;
      _path[1] = wbnb;
      _path[2] = end;
    }

    uint256[] memory amounts = IUniswapV2Router02(uniswapRouter).getAmountsOut(_amount, _path);
    return amounts[amounts.length - 1];
  }

  function setProtectedTokens() internal override {
    protected[alpacaToken] = true;
  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

}