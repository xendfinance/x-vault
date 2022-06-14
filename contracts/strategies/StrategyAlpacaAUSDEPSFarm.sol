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
  address constant ZAP = 0xB15bb89ed07D2949dfee504523a6A12F90117d18;
  address constant PROXY_WALLET_REGISTRY = 0x13e3Bc3c6A96aE3beaDD1B08531Fde979Dd30aEa;
  address constant PROXY_ACTIONS = 0x1391FB5efc2394f33930A0CfFb9d407aBdbf1481;
  address constant POSITION_MANAGER = 0xABA0b03eaA3684EB84b51984add918290B41Ee19;
  address constant STABILITY_FEE_COLLECTOR = 0x45040e48C00b52D9C0bd11b8F577f188991129e6;
  address constant TOKEN_ADAPTER = 0x4f56a92cA885bE50E705006876261e839b080E36;
  address constant STABLECOIN_ADAPTER = 0xD409DA25D32473EFB0A1714Ab3D0a6763bCe4749;
  address constant BOOK_KEEPER = 0xD0AEcee1520B5F9925D952405F9A06Dcd8fd6e6C;
  bytes32 constant COLLATERAL_POOL_ID = 0x6962425553440000000000000000000000000000000000000000000000000000;

  address public constant ALPACA_TOKEN = address(0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F);
  IAlpacaFarm public constant ALPACA_FARM = IAlpacaFarm(0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F);
  address public constant WBNB = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
  address public constant AUSD = address(0xDCEcf0664C33321CECA2effcE701E710A2D28A3F);
  address public constant AUSD3EPS = address(0xae70E3f6050d6AB05E03A50c655309C2148615bE);
  uint256 public constant POOL_ID = 25;        // AUSD-3EPS pool id of alpaca farm contract
  address public constant POOL = 0xa74077EB97778F4E94D79eA60092D0F4831d05A6;    // AUSD-3EPS pool address on Ellipsis
  uint256 public collateralFactor;
  IAlpacaVault public ibToken;
  IProxyWallet public proxyWallet;
  address[] public path;              // disposal path for alpaca token on uniswap

  address public constant UNISWAP_ROUTER = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
  address public constant CURVE_ROUTER = address(0xa74077EB97778F4E94D79eA60092D0F4831d05A6);

  uint256 public minAlpacaToSell;
  bool public forceMigrate;
  bool private adjusted;              // flag whether position adjusting was done in prepareReturn 

  event MinAlpacaToSellUpdated(uint256 newVal);
  event CollateralFactorUpdated(uint256 newVal);

  modifier management(){
    require(msg.sender == governance() || msg.sender == strategist, "!management");
    _;
  }

  /**
   * @notice initialize the contract
   * @param _vault vault address to what the strategy belongs
   * @param _ibToken Alpaca Interest Bearing token address that would be used
   * @param _path pancakeswap path for converting alpaca to underlying token
   */
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

    proxyWallet = IProxyWallet(IProxyWalletRegistry(PROXY_WALLET_REGISTRY).build());

    want.safeApprove(address(ibToken), uint256(-1));
    want.safeApprove(address(CURVE_ROUTER), uint256(-1));
    want.safeApprove(address(proxyWallet), uint256(-1));
    IERC20(ALPACA_TOKEN).safeApprove(address(UNISWAP_ROUTER), uint256(-1));
    IERC20(AUSD).safeApprove(address(ZAP), uint256(-1));
    IERC20(AUSD).safeApprove(address(proxyWallet), uint256(-1));
    IERC20(ibToken).safeApprove(address(proxyWallet), uint256(-1));
    IERC20(AUSD3EPS).safeApprove(address(ZAP), uint256(-1));
    IERC20(AUSD3EPS).safeApprove(address(ALPACA_FARM), uint256(-1));
  }

  /**
   * @notice strategy contract name
   */
  function name() external override view returns (string memory) {
    return "StrategyAlpacaAUSDEPSFarm";
  }

  /**
   * @notice set flag for forceful migration. For migration, check migrate function
   * @param _force true means forceful migration
   */
  function setForceMigrate(bool _force) external onlyGovernance {
    forceMigrate = _force;
  }

  /**
   * @notice set minimum amount of alpaca token to sell
   * @param _minAlpacaToSell amount of token, wad
   */
  function setMinAlpacaToSell(uint256 _minAlpacaToSell) external management {
    minAlpacaToSell = _minAlpacaToSell;
    emit MinAlpacaToSellUpdated(_minAlpacaToSell);
  }

  /**
   * @notice set pancakeswap path for converting alpaca to underlying token
   * @param _path pancakeswap path
   */
  function setDisposalPath(address[] memory _path) external management {
    path = _path;
  }

  /**
   * @notice View how much the vault expect this strategy to return at the current block, 
   *  based on its present performance (since its last report)
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
   * @param gasCost gas amount. wad
   */
  function harvestTrigger(uint256 gasCost) external override view returns (bool) {
    StrategyParams memory params = vault.strategies(address(this));
    
    if (params.activation == 0) return false;

    // trigger if hadn't been called in a while
    if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

    uint256 wantGasCost = _priceCheck(WBNB, address(want), gasCost);
    uint256 alpacaGasCost = _priceCheck(WBNB, ALPACA_TOKEN, gasCost);

    (, , uint256 claimable) = _getCurrentPosition();
    uint256 _claimableAlpaca = claimable.add(IERC20(ALPACA_TOKEN).balanceOf(address(proxyWallet))).add(ALPACA_FARM.pendingAlpaca(POOL_ID, address(this)));

    if (_claimableAlpaca > minAlpacaToSell) {
      // trigger harvest if AUTO token balance is worth to do swap
      if (_claimableAlpaca.add(IERC20(ALPACA_TOKEN).balanceOf(address(this))) > alpacaGasCost.mul(profitFactor)) {
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

  /**
   * @notice set collateral factor for borrowing assets
   * @param _collateralFactor collateral factor value. base point is `MAX_BPS`
   */
  function setCollateralFactor(uint256 _collateralFactor) external management {
    require(_collateralFactor > 0, "!zero");
    collateralFactor = _collateralFactor;
    emit CollateralFactorUpdated(_collateralFactor);
  }

  //////////////////////////////////
  ////    Internal Functions    ////
  //////////////////////////////////

  function _estimatedTotalAssets() internal override view returns (uint256 _assets) {
    (uint256 collateral, uint256 debt, uint256 claimable) = _getCurrentPosition();
    
    // add up ALPACA rewards from alpaca staking vault and AUSD lending protocol
    // ALPACA reward of AUSD lending protocol is distributed in two places, one is proxyWallet and the other is pending on contract
    uint256 claimableAlpaca = claimable.add(IERC20(ALPACA_TOKEN).balanceOf(address(proxyWallet))).add(ALPACA_FARM.pendingAlpaca(POOL_ID, address(this)));
    uint256 currentAlpaca = IERC20(ALPACA_TOKEN).balanceOf(address(this));
    uint256 claimableValue = _priceCheck(ALPACA_TOKEN, address(want), claimableAlpaca.add(currentAlpaca));
    claimableValue = claimableValue.mul(9).div(10);      // remaining 10% will be used for compensate offset

    // `lpValue` is AUSD amount. get AUSD amount equal to staked liquidity lp.
    (uint256 stakedBalance, , , ) = ALPACA_FARM.userInfo(POOL_ID, address(this));
    uint256 lpValue = IZap(ZAP).calc_withdraw_one_coin(POOL, stakedBalance, 0);

    if (lpValue > debt) {
      uint256 est = IStableSwap(CURVE_ROUTER).get_dy_underlying(0, 1, lpValue.sub(debt));
      _assets = collateral.add(claimableValue).add(est);
    } else {
      uint256 est = debt.sub(lpValue);
      _assets = collateral.add(claimableValue).sub(est);
    }

    _assets = _assets.add(IERC20(want).balanceOf(address(this)));

    return _assets;
  }

  // get the position for alpaca AUSD lending protocol
  function _getCurrentPosition() internal view returns (uint256 lockedCollateralValue, uint256 debt, uint256 claimable) {
    uint256 positionId = IPositionManager(POSITION_MANAGER).ownerFirstPositionId(address(proxyWallet));
    address positionHandler = IPositionManager(POSITION_MANAGER).positions(positionId);
    (uint256 lockedCollateral, uint256 debtShare) = IBookKeeper(BOOK_KEEPER).positions(COLLATERAL_POOL_ID, positionHandler);
    lockedCollateralValue = lockedCollateral.mul(ibToken.totalToken()).div(ibToken.totalSupply());
    uint256 _debtAccumulatedRate = ICollateralPoolConfig(IBookKeeper(BOOK_KEEPER).collateralPoolConfig()).getDebtAccumulatedRate(COLLATERAL_POOL_ID);
    debt = debtShare.mul(_debtAccumulatedRate).div(1e27);
    claimable = IIbTokenAdapter(TOKEN_ADAPTER).netPendingRewards(positionHandler);
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

    (uint256 stakedBalance, , , ) = ALPACA_FARM.userInfo(POOL_ID, address(this));
    uint256 lpValue = IZap(ZAP).calc_withdraw_one_coin(POOL, stakedBalance, 0);
    // if AUSD amount that staked in AUSD3EPS liquidity is over AUSD debt on AUSD lending protocol, adjust them to keep the same amount. vice versa
    uint256 addedLpValue;
    if (debt > lpValue) {
      addedLpValue = _mintAndStakeAusd(debt.sub(lpValue), true);
    } else if (debt < lpValue && lpValue.sub(debt) > minAlpacaToSell) {
      uint256 lpToWithdraw = IZap(ZAP).calc_token_amount(POOL, [lpValue.sub(debt), 0, 0, 0], true);
      ALPACA_FARM.withdraw(address(this), POOL_ID, lpToWithdraw);
      IZap(ZAP).remove_liquidity_one_coin(POOL, lpToWithdraw, 1, 0);
    }

    uint256 wantBalance = want.balanceOf(address(this));
    
    uint256 assetBalance = collateral.add(wantBalance);
    if (addedLpValue > 0) {
      assetBalance = collateral.add(wantBalance).sub(debt).add(lpValue).add(addedLpValue);
    }
    uint256 totalDebt = vault.strategies(address(this)).totalDebt;

    if (assetBalance > totalDebt) {
      _profit = assetBalance.sub(totalDebt);
    } else {
      _loss = totalDebt.sub(assetBalance);
    }

    if (wantBalance < _profit.add(_debtOutstanding)) {
    // if balance of `want` is less than needed, adjust position to get more `want`
      liquidatePosition(_profit.add(_debtOutstanding));
      adjusted = true;    // prevent against adjusting position to be called again as `liquidityPosition` already adjusted position
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

  // adjust position by keeping collateral ratio and stake new AUSD assets to AUSD3EPS liquidity
  function _farm(uint256 amount) internal {
    if (amount == 0) return;

    (uint256 collateral, uint256 debt, ) = _getCurrentPosition();
    
    uint256 desiredCollateralValue = collateral.add(amount);
    uint256 desiredDebt = desiredCollateralValue.mul(collateralFactor).div(MAX_BPS);
    uint256 borrow = desiredDebt.sub(debt);
    convertLockTokenAndDraw(amount, borrow, true);
    
    uint256 depositAmount = IERC20(AUSD).balanceOf(address(this));
    IZap(ZAP).add_liquidity(POOL, [depositAmount, 0, 0, 0], 0);
    
    ALPACA_FARM.deposit(address(this), POOL_ID, IERC20(AUSD3EPS).balanceOf(address(this)));
  }

  // withdraw `_amount` of want from alpaca AUSD lending protocol
  function _withdrawSome(uint256 _amount) internal {
    (uint256 collateral, uint256 debt, ) = _getCurrentPosition();
    if (_amount > collateral) {
      _amount = collateral;
    }
    uint256 desiredCollateralValue = collateral.sub(_amount);
    uint256 desiredDebt = desiredCollateralValue.mul(collateralFactor).div(MAX_BPS);
    if (desiredDebt <= 500e18) {
    // alpaca doesn't allow the AUSD debt size to be lower than 500e18, so in that case, should close position completely
      (uint256 stakedLp, , , ) = ALPACA_FARM.userInfo(POOL_ID, address(this));
      ALPACA_FARM.withdraw(address(this), POOL_ID, stakedLp);
      IZap(ZAP).remove_liquidity_one_coin(POOL, stakedLp, 0, 0);
      uint256 ausdBal = IERC20(AUSD).balanceOf(address(this));
      if (ausdBal < debt) {
        _claimAlpaca();
        _disposeAlpaca();
        _mintAndStakeAusd(debt.sub(ausdBal), false);
      }
      convertLockTokenAndDraw(collateral.mul(ibToken.totalSupply()).div(ibToken.totalToken()).add(1), uint256(-1), false);
    } else {
    // if not lower than 500e18, adjust position normally
      uint256 repay = debt.sub(desiredDebt);

      uint256 lpToWithdraw = IZap(ZAP).calc_token_amount(POOL, [repay, 0, 0, 0], true);
      (uint256 stakedLp, , , ) = ALPACA_FARM.userInfo(POOL_ID, address(this));
      if (lpToWithdraw > stakedLp) {
        lpToWithdraw = stakedLp;
      }
      
      ALPACA_FARM.withdraw(address(this), POOL_ID, lpToWithdraw);
      IZap(ZAP).remove_liquidity_one_coin(POOL, lpToWithdraw, 0, 0);
      convertLockTokenAndDraw(_amount.mul(ibToken.totalSupply()).div(ibToken.totalToken()), _min(IERC20(AUSD).balanceOf(address(this)), repay), false);
    }
  }


  // Alpaca AUSD lending protocol position adjust functions. lends `amount` of want and borrow `stablecoinAmount` of AUSD or vice versa
  function convertLockTokenAndDraw(uint256 amount, uint256 stablecoinAmount, bool flag) internal {
    uint256 positionId = IPositionManager(POSITION_MANAGER).ownerFirstPositionId(address(proxyWallet));
    bytes memory _data;
    if (flag) {
      if (positionId == 0) {
        _data = abi.encodeWithSignature(
          "convertOpenLockTokenAndDraw(address,address,address,address,address,bytes32,uint256,uint256,bytes)", 
          ibToken, 
          POSITION_MANAGER,
          STABILITY_FEE_COLLECTOR,
          TOKEN_ADAPTER,
          STABLECOIN_ADAPTER,
          COLLATERAL_POOL_ID,
          amount,
          stablecoinAmount,
          abi.encode(address(this))
        );
      } else {
        _data = abi.encodeWithSignature(
          "convertLockTokenAndDraw(address,address,address,address,address,uint256,uint256,uint256,bytes)",
          ibToken,
          POSITION_MANAGER,
          STABILITY_FEE_COLLECTOR,
          TOKEN_ADAPTER,
          STABLECOIN_ADAPTER,
          positionId,
          amount,
          stablecoinAmount,
          abi.encode(address(this))
        );
      }
    } else {
      // completely close position
      if (stablecoinAmount == uint256(-1)) {
        _data = abi.encodeWithSignature(
          "wipeAllUnlockTokenAndConvert(address,address,address,address,uint256,uint256,bytes)", 
          ibToken, 
          POSITION_MANAGER,
          TOKEN_ADAPTER,
          STABLECOIN_ADAPTER,
          positionId,
          amount,
          abi.encode(address(this))
        );
      } else {
        _data = abi.encodeWithSignature(
          "wipeUnlockTokenAndConvert(address,address,address,address,uint256,uint256,uint256,bytes)",
          ibToken,
          POSITION_MANAGER,
          TOKEN_ADAPTER,
          STABLECOIN_ADAPTER,
          positionId,
          amount,
          stablecoinAmount,
          abi.encode(address(this))
        );
      }
    }
    
    proxyWallet.execute(PROXY_ACTIONS, _data);
  }

  // swap want balance to AUSD to match debt. if `flag` is true, stake AUSD to AUSD3EPS liquidity
  function _mintAndStakeAusd(uint256 amount, bool flag) internal returns (uint256) {
    uint256 wantBal = IERC20(want).balanceOf(address(this));
    amount = _min(wantBal, amount);
    if (amount < minAlpacaToSell) {
      return 0;
    }
    
    IStableSwap(CURVE_ROUTER).exchange_underlying(1, 0, amount, 0);

    uint256 depositAmount = IERC20(AUSD).balanceOf(address(this));
    if (flag) {
      IZap(ZAP).add_liquidity(POOL, [depositAmount, 0, 0, 0], 0);
      ALPACA_FARM.deposit(address(this), POOL_ID, IERC20(AUSD3EPS).balanceOf(address(this)));
    }

    return depositAmount;
  }

  // claims Alpaca reward token
  function _claimAlpaca() internal {
    ALPACA_FARM.harvest(POOL_ID);

    uint256 positionId = IPositionManager(POSITION_MANAGER).ownerFirstPositionId(address(proxyWallet));
    address[] memory _tokenAdapters = new address[](1);
    uint256[] memory _positionIds = new uint256[](1);
    _tokenAdapters[0] = TOKEN_ADAPTER;
    _positionIds[0] = positionId;
    bytes memory _data = abi.encodeWithSignature(
      "harvestMultiple(address,address[],uint256[],address)",
      POSITION_MANAGER,
      _tokenAdapters,
      _positionIds,
      ALPACA_TOKEN
    );
    proxyWallet.execute(PROXY_ACTIONS, _data);
  }

  // sell harvested Alpaca token
  function _disposeAlpaca() internal {
    uint256 _alpaca = IERC20(ALPACA_TOKEN).balanceOf(address(this));

    if (_alpaca > minAlpacaToSell) {

      uint256[] memory amounts = IUniswapV2Router02(UNISWAP_ROUTER).getAmountsOut(_alpaca, path);
      uint256 estimatedWant = amounts[amounts.length - 1];
      uint256 conservativeWant = estimatedWant.mul(9).div(10);      // remaining 10% will be used for compensate offset

      IUniswapV2Router02(UNISWAP_ROUTER).swapExactTokensForTokens(_alpaca, conservativeWant, path, address(this), now);
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
      ALPACA_FARM.withdrawAll(address(this), POOL_ID);
      IZap(ZAP).remove_liquidity_one_coin(POOL, IERC20(AUSD3EPS).balanceOf(address(this)), 0, 0);
      
      uint256 _alpacaBalance = IERC20(ALPACA_TOKEN).balanceOf(address(this));
      if (_alpacaBalance > 0) {
        IERC20(ALPACA_TOKEN).safeTransfer(_newStrategy, _alpacaBalance);
      }
    }
  }
  

  function _priceCheck(address start, address end, uint256 _amount) internal view returns (uint256) {
    if (_amount < minAlpacaToSell) {
      return 0;
    }

    address[] memory _path;
    if (start == WBNB) {
      _path = new address[](2);
      _path[0] = WBNB;
      _path[1] = end;
    } else {
      _path = new address[](3);
      _path[0] = start;
      _path[1] = WBNB;
      _path[2] = end;
    }

    uint256[] memory amounts = IUniswapV2Router02(UNISWAP_ROUTER).getAmountsOut(_amount, _path);
    return amounts[amounts.length - 1];
  }

  function setProtectedTokens() internal override {
    protected[ALPACA_TOKEN] = true;
  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

}
