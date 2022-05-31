// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./BaseStrategy.sol";
import "../interfaces/alpaca/IAlpacaVault.sol";
import "../interfaces/alpaca/IProxyWalletRegistry.sol";
import "../interfaces/alpaca/IAlpacaFarm.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";
import "../interfaces/ellipsis/IZap.sol";
import "../interfaces/ellipsis/IStableSwap.sol";

contract StrategyAlpacaAUSDEPSFarm is BaseStrategy {
  using Address for address;

  uint256 constant MAX_BPS = 10_000;
  address constant zap = 0xB15bb89ed07D2949dfee504523a6A12F90117d18;
  address constant proxyWalletRegistry = 0x13e3Bc3c6A96aE3beaDD1B08531Fde979Dd30aEa;
  address constant proxyActions = 0x1391FB5efc2394f33930A0CfFb9d407aBdbf1481;
  address constant positionManager = 0xABA0b03eaA3684EB84b51984add918290B41Ee19;
  address constant stabilityFeeCollector = 0x45040e48C00b52D9C0bd11b8F577f188991129e6;
  address constant tokenAdapter = 0x4f56a92cA885bE50E705006876261e839b080E36;
  address constant stablecoinAdapter = 0xD409DA25D32473EFB0A1714Ab3D0a6763bCe4749;
  address constant bookKeeper = 0xD0AEcee1520B5F9925D952405F9A06Dcd8fd6e6C;
  bytes32 constant collateralPoolId = 0x6962425553440000000000000000000000000000000000000000000000000000;

  address public constant alpacaToken = address(0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F);
  IAlpacaFarm public constant alpacaFarm = IAlpacaFarm(0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F);
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
  address public constant ausd = address(0xDCEcf0664C33321CECA2effcE701E710A2D28A3F);
  address public constant ausd3eps = address(0xae70E3f6050d6AB05E03A50c655309C2148615bE);
  uint256 public constant poolId = 25;        // AUSD-3EPS pool id of alpaca farm contract
  address public constant pool = 0xa74077EB97778F4E94D79eA60092D0F4831d05A6;    // AUSD-3EPS pool address on Ellipsis
  uint256 public collateralFactor;
  IAlpacaVault public ibToken;
  IProxyWallet public proxyWallet;
  address[] public path;              // disposal path for alpaca token on uniswap

  address public constant uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
  address public constant curveRouter = address(0xa74077EB97778F4E94D79eA60092D0F4831d05A6);

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
    address[] memory _path
  ) public initializer {
    
    super.initialize(_vault);

    ibToken = IAlpacaVault(_ibToken);
    path = _path;

    minAlpacaToSell = 1e10;
    collateralFactor = 8750;

    proxyWallet = IProxyWallet(IProxyWalletRegistry(proxyWalletRegistry).build());

    want.safeApprove(address(ibToken), uint256(-1));
    want.safeApprove(address(curveRouter), uint256(-1));
    want.safeApprove(address(proxyWallet), uint256(-1));
    IERC20(alpacaToken).safeApprove(address(uniswapRouter), uint256(-1));
    IERC20(ausd).safeApprove(address(zap), uint256(-1));
    IERC20(ausd).safeApprove(address(proxyWallet), uint256(-1));
    IERC20(ibToken).safeApprove(address(proxyWallet), uint256(-1));
    IERC20(ausd3eps).safeApprove(address(zap), uint256(-1));
    IERC20(ausd3eps).safeApprove(address(alpacaFarm), uint256(-1));
  }

  function name() external override view returns (string memory) {
    return "StrategyAlpacaAUSDEPSFarm";
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
   * View how much the vault expect this strategy to return at the current block, based on its present performance (since its last report)
   */
  function expectedReturn() external view returns (uint256) {
    uint256 estimatedAssets = _estimatedTotalAssets();

    uint256 debt = vault.strategies(address(this)).totalDebt;
    if (debt >= estimatedAssets) {
      return 0;
    } else {
      return estimatedAssets - debt;
    }
  }

  /**
   * @notice
   *  Provide a signal to the keeper that harvest should be called.
   *  The keeper will provide the estimated gas cost that they would pay to call
   *  harvest() function.
   */
  function harvestTrigger(uint256 gasCost) external override view returns (bool) {
    StrategyParams memory params = vault.strategies(address(this));
    
    if (params.activation == 0) return false;

    // trigger if hadn't been called in a while
    if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

    uint256 wantGasCost = _priceCheck(wbnb, address(want), gasCost);
    uint256 alpacaGasCost = _priceCheck(wbnb, alpacaToken, gasCost);

    (, , uint256 claimable) = _getCurrentPosition();
    uint256 _claimableAlpaca = claimable.add(IERC20(alpacaToken).balanceOf(address(proxyWallet))).add(alpacaFarm.pendingAlpaca(poolId, address(this)));

    if (_claimableAlpaca > minAlpacaToSell) {
      // trigger harvest if AUTO token balance is worth to do swap
      if (_claimableAlpaca.add(IERC20(alpacaToken).balanceOf(address(this))) > alpacaGasCost.mul(profitFactor)) {
        return true;
      }
    }

    uint256 outstanding = vault.debtOutstanding(address(this));
    if (outstanding > wantGasCost.mul(profitFactor)) return true;

    uint256 total = _estimatedTotalAssets();
    uint256 profit = 0;
    if (total > params.totalDebt) profit = total.sub(params.totalDebt);

    uint256 credit = vault.creditAvailable(address(this)).add(profit);
    return (wantGasCost.mul(profitFactor) < credit);
  }

  function setCollateralFactor(uint256 _collateralFactor) external management {
    require(_collateralFactor > 0, "!zero");
    collateralFactor = _collateralFactor;
    
  }

  //////////////////////////////////
  ////    Internal Functions    ////
  //////////////////////////////////

  function _estimatedTotalAssets() internal override view returns (uint256 _assets) {
    (uint256 collateral, uint256 debt, uint256 claimable) = _getCurrentPosition();
    
    // add up alpaca rewards from alpaca farm and ausd farm
    // alpaca rewards of ausd farm distributed in two places, one is proxyWallet and the other is reward generation
    uint256 claimableAlpaca = claimable.add(IERC20(alpacaToken).balanceOf(address(proxyWallet))).add(alpacaFarm.pendingAlpaca(poolId, address(this)));
    uint256 currentAlpaca = IERC20(alpacaToken).balanceOf(address(this));
    uint256 claimableValue = _priceCheck(alpacaToken, address(want), claimableAlpaca.add(currentAlpaca));
    claimableValue = claimableValue.mul(9).div(10);      // remaining 10% will be used for compensate offset

    (uint256 stakedBalance, , , ) = alpacaFarm.userInfo(poolId, address(this));
    uint256 lpValue = IZap(zap).calc_withdraw_one_coin(pool, stakedBalance, 0);

    if (lpValue > debt) {
      uint256 est = IStableSwap(curveRouter).get_dy_underlying(0, 1, lpValue.sub(debt));
      _assets = collateral.add(claimableValue).add(est);
    } else {
      uint256 est = debt.sub(lpValue);
      _assets = collateral.add(claimableValue).sub(est);
    }

    return _assets;
  }

  function _getCurrentPosition() internal view returns (uint256 lockedCollateralValue, uint256 debt, uint256 claimable) {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));
    address positionHandler = IPositionManager(positionManager).positions(positionId);
    (uint256 lockedCollateral, uint256 debtShare) = IBookKeeper(bookKeeper).positions(collateralPoolId, positionHandler);
    lockedCollateralValue = lockedCollateral.mul(ibToken.totalToken()).div(ibToken.totalSupply());
    uint256 _debtAccumulatedRate = ICollateralPoolConfig(IBookKeeper(bookKeeper).collateralPoolConfig()).getDebtAccumulatedRate(collateralPoolId);
    debt = debtShare.mul(_debtAccumulatedRate).div(1e27);
    claimable = IIbTokenAdapter(tokenAdapter).netPendingRewards(positionHandler);
  }

  function prepareReturn(uint256 _debtOutstanding) internal override returns (
    uint256 _profit,
    uint256 _loss,
    uint256 _debtPayment
  ) {

    (uint256 collateral, uint256 debt, ) = _getCurrentPosition();
    if (collateral < minAlpacaToSell) {
      uint256 wantBalance = want.balanceOf(address(this));
      _debtPayment = _min(wantBalance, _debtOutstanding);
      return (_profit, _loss, _debtPayment);
    }

    _claimAlpaca();
    _disposeAlpaca();

    // match debt to staked amount of ausd of ausd3eps
    (uint256 stakedBalance, , , ) = alpacaFarm.userInfo(poolId, address(this));
    uint256 lpValue = IZap(zap).calc_withdraw_one_coin(pool, stakedBalance, 0);
    if (debt > lpValue) {
      _mintAndStakeAusd(debt.sub(lpValue), true);
    } else if (debt < lpValue && lpValue.sub(debt) > minAlpacaToSell) {
      uint256 lpToWithdraw = IZap(zap).calc_token_amount(pool, [lpValue.sub(debt), 0, 0, 0], true);
      alpacaFarm.withdraw(address(this), poolId, lpToWithdraw);
      IZap(zap).remove_liquidity_one_coin(pool, lpToWithdraw, 1, 0);
    }

    uint256 wantBalance = want.balanceOf(address(this));
    
    uint256 assetBalance = collateral.add(wantBalance);
    uint256 totalDebt = vault.strategies(address(this)).totalDebt;

    if (assetBalance > totalDebt) {
      _profit = assetBalance.sub(totalDebt);
    } else {
      _loss = totalDebt.sub(assetBalance);
    }

    if (wantBalance < _profit.add(_debtOutstanding)) {
      liquidatePosition(_profit.add(_debtOutstanding));
      adjusted = true;
      wantBalance = want.balanceOf(address(this));
      if (wantBalance >= _profit.add(_debtOutstanding)) {
        _debtPayment = _debtOutstanding;
        if (_profit.add(_debtOutstanding).sub(_debtPayment) < _profit) {
          _profit = _profit.add(_debtOutstanding).sub(_debtPayment);
        }
      } else {
        if (wantBalance < _debtOutstanding) {
          _debtPayment = wantBalance;
          _profit = 0;
        } else {
          _debtPayment = _debtOutstanding;
          _profit = wantBalance.sub(_debtPayment);
        }
      }
    } else {
      _debtPayment = _debtOutstanding;
      if (_profit.add(_debtOutstanding).sub(_debtPayment) < _profit) {
        _profit = _profit.add(_debtOutstanding).sub(_debtPayment);
      }
    }
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

    _farm(_wantBal - _debtOutstanding);
  }

  function _farm(uint256 amount) internal {
    if (amount == 0) return;

    (uint256 collateral, uint256 debt, ) = _getCurrentPosition();
    
    uint256 desiredCollateralValue = collateral.add(amount);
    uint256 desiredDebt = desiredCollateralValue.mul(collateralFactor).div(MAX_BPS);
    uint256 borrow = desiredDebt.sub(debt);
    convertLockTokenAndDraw(amount, borrow, true);
    
    uint256 depositAmount = IERC20(ausd).balanceOf(address(this));
    IZap(zap).add_liquidity(pool, [depositAmount, 0, 0, 0], 0);
    
    alpacaFarm.deposit(address(this), poolId, IERC20(ausd3eps).balanceOf(address(this)));
  }

  function _withdrawSome(uint256 _amount) internal {
    (uint256 collateral, uint256 debt, ) = _getCurrentPosition();
    if (_amount > collateral) {
      _amount = collateral;
    }
    uint256 desiredCollateralValue = collateral.sub(_amount);
    uint256 desiredDebt = desiredCollateralValue.mul(collateralFactor).div(MAX_BPS);
    if (desiredDebt <= 500e18) {
      (uint256 stakedLp, , , ) = alpacaFarm.userInfo(poolId, address(this));
      alpacaFarm.withdraw(address(this), poolId, stakedLp);
      IZap(zap).remove_liquidity_one_coin(pool, stakedLp, 0, 0);
      uint256 ausdBal = IERC20(ausd).balanceOf(address(this));
      if (ausdBal < debt) {
        _claimAlpaca();
        _disposeAlpaca();
        _mintAndStakeAusd(debt.sub(ausdBal), false);
      }
      convertLockTokenAndDraw(collateral.mul(ibToken.totalSupply()).div(ibToken.totalToken()).add(1), uint256(-1), false);
    } else {
      uint256 repay = debt.sub(desiredDebt);

      uint256 lpToWithdraw = IZap(zap).calc_token_amount(pool, [repay, 0, 0, 0], true);
      (uint256 stakedLp, , , ) = alpacaFarm.userInfo(poolId, address(this));
      if (lpToWithdraw > stakedLp) {
        lpToWithdraw = stakedLp;
      }
      
      alpacaFarm.withdraw(address(this), poolId, lpToWithdraw);
      IZap(zap).remove_liquidity_one_coin(pool, lpToWithdraw, 0, 0);
      convertLockTokenAndDraw(_amount.mul(ibToken.totalSupply()).div(ibToken.totalToken()), _min(IERC20(ausd).balanceOf(address(this)), repay), false);
    }
  }


  function convertLockTokenAndDraw(uint256 amount, uint256 stablecoinAmount, bool flag) internal {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));
    bytes memory _data;
    if (flag) {
      if (positionId == 0) {
        _data = abi.encodeWithSignature(
          "convertOpenLockTokenAndDraw(address,address,address,address,address,bytes32,uint256,uint256,bytes)", 
          ibToken, 
          positionManager,
          stabilityFeeCollector,
          tokenAdapter,
          stablecoinAdapter,
          collateralPoolId,
          amount,
          stablecoinAmount,
          abi.encode(address(this))
        );
      } else {
        _data = abi.encodeWithSignature(
          "convertLockTokenAndDraw(address,address,address,address,address,uint256,uint256,uint256,bytes)",
          ibToken,
          positionManager,
          stabilityFeeCollector,
          tokenAdapter,
          stablecoinAdapter,
          positionId,
          amount,
          stablecoinAmount,
          abi.encode(address(this))
        );
      }
    } else {
      if (stablecoinAmount == uint256(-1)) {
        _data = abi.encodeWithSignature(
          "wipeAllUnlockTokenAndConvert(address,address,address,address,uint256,uint256,bytes)", 
          ibToken, 
          positionManager,
          tokenAdapter,
          stablecoinAdapter,
          positionId,
          amount,
          abi.encode(address(this))
        );
      } else {
        _data = abi.encodeWithSignature(
          "wipeUnlockTokenAndConvert(address,address,address,address,uint256,uint256,uint256,bytes)",
          ibToken,
          positionManager,
          tokenAdapter,
          stablecoinAdapter,
          positionId,
          amount,
          stablecoinAmount,
          abi.encode(address(this))
        );
      }
    }
    
    proxyWallet.execute(proxyActions, _data);
  }

  function _mintAndStakeAusd(uint256 amount, bool flag) internal {
    uint256 wantBal = IERC20(want).balanceOf(address(this));
    amount = _min(wantBal, amount);
    if (amount < minAlpacaToSell) {
      return;
    }
    
    IStableSwap(curveRouter).exchange_underlying(1, 0, amount, 0);

    if (flag) {
      uint256 depositAmount = IERC20(ausd).balanceOf(address(this));
      IZap(zap).add_liquidity(pool, [depositAmount, 0, 0, 0], 0);
      alpacaFarm.deposit(address(this), poolId, IERC20(ausd3eps).balanceOf(address(this)));
    }
  }

  // claims Alpaca reward token
  function _claimAlpaca() internal {
    alpacaFarm.harvest(poolId);

    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));
    address[] memory _tokenAdapters = new address[](1);
    uint256[] memory _positionIds = new uint256[](1);
    _tokenAdapters[0] = tokenAdapter;
    _positionIds[0] = positionId;
    bytes memory _data = abi.encodeWithSignature(
      "harvestMultiple(address,address[],uint256[],address)",
      positionManager,
      _tokenAdapters,
      _positionIds,
      alpacaToken
    );
    proxyWallet.execute(proxyActions, _data);
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
    uint256 balance = want.balanceOf(address(this));
    (uint256 collateral, , ) = _getCurrentPosition();
    uint256 assets = collateral.add(balance);

    uint256 debtOutstanding = vault.debtOutstanding(address(this));
    if (debtOutstanding > assets) {
      _loss = debtOutstanding - assets;
    }
    
    if (balance < _amountNeeded) {
      _withdrawSome(_amountNeeded.sub(balance));
      _amountFreed = _min(_amountNeeded, want.balanceOf(address(this)));
    } else {
      _amountFreed = _amountNeeded;
    }
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
      IZap(zap).remove_liquidity_one_coin(pool, IERC20(ausd3eps).balanceOf(address(this)), 0, 0);
      
      uint256 _alpacaBalance = IERC20(alpacaToken).balanceOf(address(this));
      if (_alpacaBalance > 0) {
        IERC20(alpacaToken).safeTransfer(_newStrategy, _alpacaBalance);
      }
    }
  }
  

  function _priceCheck(address start, address end, uint256 _amount) internal view returns (uint256) {
    if (_amount < minAlpacaToSell) {
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
