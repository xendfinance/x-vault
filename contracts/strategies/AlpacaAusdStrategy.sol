// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./BaseStrategy.sol";
import "../interfaces/flashloan/ERC3156FlashBorrowerInterface.sol";
import "../interfaces/flashloan/ERC3156FlashLenderInterface.sol";
import "../interfaces/alpaca/IAlpacaVault.sol";
import "../interfaces/alpaca/IProxyWalletRegistry.sol";
import "../interfaces/alpaca/IAlpacaFarm.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";
import "../interfaces/ellipsis/IStableSwap.sol";

contract StrategyAlpacaAUSDFarm is BaseStrategy, ERC3156FlashBorrowerInterface {
  using Address for address;

  IProxyWalletRegistry public constant proxyWalletRegistry = IProxyWalletRegistry(0x13e3Bc3c6A96aE3beaDD1B08531Fde979Dd30aEa);

  address public proxyActions = 0x1391FB5efc2394f33930A0CfFb9d407aBdbf1481;
  address positionManager = 0xABA0b03eaA3684EB84b51984add918290B41Ee19;
  address stabilityFeeCollector = 0x45040e48C00b52D9C0bd11b8F577f188991129e6;
  address tokenAdapter = 0x4f56a92cA885bE50E705006876261e839b080E36;
  address stablecoinAdapter = 0xD409DA25D32473EFB0A1714Ab3D0a6763bCe4749;
  address bookKeeper = 0xD0AEcee1520B5F9925D952405F9A06Dcd8fd6e6C;
  address stableSwapModule = 0xd16004424b9C3f0A7C74C4c8dcDa0D8C4D513fAC;
  bytes32 collateralPoolId = 0x6962425553440000000000000000000000000000000000000000000000000000;

  address public constant alpacaToken = address(0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F);
  IAlpacaFarm public constant alpacaFarm = IAlpacaFarm(0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F);
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
  address public constant ausd = address(0xDCEcf0664C33321CECA2effcE701E710A2D28A3F);
  address[] public path;              // disposal path for alpaca token on uniswap
  IAlpacaVault public ibToken;
  IProxyWallet public proxyWallet;
  uint256 private poolId;             // the ibToken pool id of alpaca farm contract

  address public constant uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
  address public constant curveRouter = address(0xa74077EB97778F4E94D79eA60092D0F4831d05A6);
  address public constant crWant = address(0x2Bc4eb013DDee29D37920938B96d353171289B7C);

  uint256 public collateralTarget;
  uint256 public minAlpacaToSell;
  uint256 public minWant;
  bool public flashLoanActive;
  bool public forceMigrate;
  bool private adjusted;              // flag whether position adjusting was done in prepareReturn 

  event Leverage(uint256 amountRequested, uint256 amountGiven, bool deficit, address flashLoan);

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

    collateralTarget = 0.83 ether; // 83%
    minAlpacaToSell = 1e10;
    minWant = 1 ether;
    flashLoanActive = true;
    
    proxyWallet = IProxyWallet(proxyWalletRegistry.build());
    
    IERC20(want).safeApprove(address(proxyWallet), uint256(-1));
    IERC20(_ibToken).safeApprove(address(proxyWallet), uint256(-1));
    IERC20(alpacaToken).safeApprove(address(uniswapRouter), uint256(-1));
    IERC20(ausd).safeApprove(address(curveRouter), uint256(-1));
  }

  function name() external override view returns (string memory) {
    return "StrategyAlpacaAUSDFarm";
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
   *  The strategy don't need `tend` action, so just returns `false`.
   */
  function tendTrigger(uint256 gasCost) external override view returns (bool) {
    return false;
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

    uint256 _claimableAlpaca = _getPendingReward();

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

  //////////////////////////////
  ////    View Functions    ////
  //////////////////////////////

  /**
   *  An accurate estimate for the total amount of assets (principle + return)
   *  that this strategy is currently managing, denominated in terms of want tokens.
   */
  function estimatedTotalAssets() external override view returns (uint256) {
    return _estimatedTotalAssets();
  }

  function getCurrentPosition() external view returns (uint256 lockedCollateral, uint256 debtShare, uint256 claimable) {
    return _getCurrentPosition();
  }

  /**
   * View how much the vault expect this strategy to return at the current block, based on its present performance (since its last report)
   */
  function expectedReturn() external view returns (uint256) {
    return _expectedReturn();
  }
  

  //////////////////////////////////
  ////    Internal Functions    ////
  //////////////////////////////////

  function _estimatedTotalAssets() internal override view returns (uint256) {
    // debt asset is AUSD. so needs to be converted to underlying assets. 
    // currently, suppose to AUSD and BUSD have the same value(1:1) because 
    // we can mint 1 AUSD by depositing 1 BUSD in alpaca protocol
    (uint256 collateral, uint256 debt, uint256 claimable) = _getCurrentPosition();
    uint256 assets = ibToken.balanceOf(address(this)).add(collateral).mul(ibToken.totalToken()).div(ibToken.totalSupply());
    
    uint256 claimableAlpaca = claimable.add(IERC20(alpacaToken).balanceOf(address(proxyWallet)));
    uint256 currentAlpaca = IERC20(alpacaToken).balanceOf(address(this));

    uint256 estimatedWant = _priceCheck(alpacaToken, address(want), claimableAlpaca.add(currentAlpaca));
    uint256 conservativeWant = estimatedWant.mul(9).div(10);      // remaining 10% will be used for compensate offset

    return want.balanceOf(address(this)).add(assets).add(conservativeWant).sub(debt);
  }

  function _getCurrentPosition() internal view returns (uint256 lockedCollateral, uint256 debtShare, uint256 claimable) {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));
    address positionHandler = IPositionManager(positionManager).positions(positionId);
    (lockedCollateral, debtShare) = IBookKeeper(bookKeeper).positions(collateralPoolId, positionHandler);
    claimable = IIbTokenAdapter(tokenAdapter).netPendingRewards(positionHandler);
  }

  function _expectedReturn() internal view returns (uint256) {
    uint256 estimatedAssets = _estimatedTotalAssets();

    uint256 debt = vault.strategies(address(this)).totalDebt;
    if (debt >= estimatedAssets) {
      return 0;
    } else {
      return estimatedAssets - debt;
    }
  }

  function _getPendingReward() internal view returns (uint256) {
    (, , uint256 claimable) = _getCurrentPosition();
    uint256 claimableAlpaca = claimable.add(IERC20(alpacaToken).balanceOf(address(proxyWallet)));
    return claimableAlpaca;
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

    (uint256 collateral, uint256 debt, uint256 claimable) = _getCurrentPosition();
    
    // if there is some claimable alpaca token, claim it
    uint256 claimableAlpaca = claimable.add(IERC20(alpacaToken).balanceOf(address(proxyWallet)));
    if (claimableAlpaca > 0) {
      _claimAlpaca();
      _disposeAlpaca();
    }

    uint256 _wantBalance = want.balanceOf(address(this));
    
    if (collateral == 0) {
      _debtPayment = _min(_wantBalance, _debtOutstanding);
      return (_profit, _loss, _debtPayment);
    }

    uint256 _investBalance = collateral.sub(debt);
    uint256 _assets = _investBalance.add(_wantBalance);
    uint256 vaultDebt = vault.strategies(address(this)).totalDebt;

    if (_assets > vaultDebt) {
      _profit = _assets.sub(vaultDebt);
    } else {
      _loss = vaultDebt.sub(_assets);
    }

    if (_wantBalance < _profit.add(_debtOutstanding)) {
      liquidatePosition(_profit.add(_debtOutstanding));
      adjusted = true;
      _wantBalance = want.balanceOf(address(this));
      if (_wantBalance >= _profit.add(_debtOutstanding)) {
        _debtPayment = _debtOutstanding;
        if (_profit.add(_debtOutstanding).sub(_debtPayment) < _profit) {
          _profit = _profit.add(_debtOutstanding).sub(_debtPayment);
        }
      } else {
        if (_wantBalance < _debtOutstanding) {
          _debtPayment = _wantBalance;
          _profit = 0;
        } else {
          _debtPayment = _debtOutstanding;
          _profit = _wantBalance.sub(_debtPayment);
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

    uint256 _wantBalance = want.balanceOf(address(this));
    if (_wantBalance < _debtOutstanding) {
      uint256 _needed = _debtOutstanding.sub(_wantBalance);
      _withdrawSome(_needed);
      return;
    }

    (uint256 position, bool deficit) = _calculateDesiredPosition(_wantBalance - _debtOutstanding, true);

    if (position > minWant) {
      if (!flashLoanActive) {
        uint i = 0;
        while (position > 0) {
          position = position.sub(_noFlashLoan(position, deficit));
          if (i >= 6) {
            break;
          }
          i++;
        }
      } else {
        if (position > want.balanceOf(crWant)) {
          position = position.sub(_noFlashLoan(position, deficit));
        }

        if (position > minWant) {
          _doFlashLoan(deficit, position);
        }
      }
    }
  }

  function _doFlashLoan(bool deficit, uint256 amountDesired) internal returns (uint256) {
    if (amountDesired == 0) {
      return 0;
    }

    uint256 amount = amountDesired;
    bytes memory data = abi.encode(deficit, amount);
    ERC3156FlashLenderInterface(crWant).flashLoan(this, address(want), amount, data);
    emit Leverage(amountDesired, amount, deficit, crWant);

    return amount;
  }

  function onFlashLoan(
    address initiator,
    address token,
    uint256 amount,
    uint256 fee,
    bytes calldata data
  ) external override returns (bytes32) {
    require(initiator == address(this), "caller is not this contract");
    (bool deficit, uint256 borrowAmount) = abi.decode(data, (bool, uint256));
    require(borrowAmount == amount, "encoded data (borrowAmount) does not match");
    require(msg.sender == crWant, "Not Flash Loan Provider");
    
    _loanLogic(deficit, amount, amount + fee);

    IERC20(token).approve(msg.sender, amount + fee);
    return keccak256("ERC3156FlashBorrowerInterface.onFlashLoan");
  }

  function _loanLogic(bool deficit, uint256 amount, uint256 repayAmount) internal returns (uint256) {
    uint256 bal = want.balanceOf(address(this));
    require(bal >= amount, "Invalid balance, was the flashloan successful?");

    if (deficit) {
      IStableSwapModule(stableSwapModule).swapTokenToStablecoin(address(this), amount);
      _repayBorrow(amount);
      _withdrawIbToken(repayAmount.mul(ibToken.totalSupply()).div(ibToken.totalToken()));
    } else {
      _investWant(bal);
      _drawAusd(repayAmount.mul(100).div(95));
      IStableSwap(curveRouter).exchange_underlying(0, 1, IERC20(ausd).balanceOf(address(this)), repayAmount);
      _repayBorrow(IERC20(ausd).balanceOf(address(this)).sub(repayAmount));
    }
  }

  /**
   * @notice
   *  Three functions covering normal leverage and deleverage situations
   * @param max the max amount we want to increase our borrowed balance
   * @param deficit True if we are reducing the position size
   * @return amount actually did
   */
  function _noFlashLoan(uint256 max, bool deficit) internal returns (uint256 amount) {
    (uint256 collateral, uint256 debt, ) = _getCurrentPosition();
    
    // if we have nothing borrowed, can't deleverage any more(can't reduce borrow size)
    if (debt == 0 && deficit) {
      return 0;
    }

    uint256 collateralFactor = 0.9 ether;

    if (deficit) {
      amount = _normalDeleverage(max, collateral, debt, collateralFactor);
    } else {
      amount = _normalLeverage(max, collateral, debt, collateralFactor);
    }

  }

  /**
   * @param maxDeleverage how much we want to reduce by
   * @param lent the amount we lent to the venus
   * @param borrowed the amount we borrowed from the venus
   * @param collatRatio collateral ratio of token in venus
   */
  function _normalDeleverage(
    uint256 maxDeleverage,
    uint256 lent,
    uint256 borrowed,
    uint256 collatRatio
  ) internal returns (uint256 deleveragedAmount) {
    uint256 theoreticalLent = 0;
    if (collatRatio > 0) {
      theoreticalLent = borrowed.mul(1e18).div(collatRatio);
    }
    deleveragedAmount = lent.sub(theoreticalLent);
    if (deleveragedAmount > borrowed) {
      deleveragedAmount = borrowed;
    }
    if (deleveragedAmount > maxDeleverage) {
      deleveragedAmount = maxDeleverage;
    }

    uint256 ibTokenAmount = deleveragedAmount.mul(ibToken.totalSupply()).div(ibToken.totalToken());
    if (ibTokenAmount > 0 && ibTokenAmount > 10) {
      _withdrawIbToken(ibTokenAmount - 10);
      ibToken.withdraw(ibToken.balanceOf(address(this)));
      IStableSwapModule(stableSwapModule).swapTokenToStablecoin(address(this), want.balanceOf(address(this)));
      _repayBorrow(IERC20(ausd).balanceOf(address(this)));
    }

  }

  /**
   * @param maxLeverage how much we want to increase by
   * @param lent the amount we lent to the venus
   * @param borrowed the amount we borrowed from the venus
   * @param collatRatio collateral ratio of token in venus
   */
  function _normalLeverage(
    uint256 maxLeverage,
    uint256 lent,
    uint256 borrowed,
    uint256 collatRatio
  ) internal returns (uint256 leveragedAmount) {
    uint256 theoreticalBorrow = lent.mul(collatRatio).div(1e18);
    leveragedAmount = theoreticalBorrow.sub(borrowed);

    if (leveragedAmount > maxLeverage) {
      leveragedAmount = maxLeverage;
    }

    if (leveragedAmount > 10) {
      leveragedAmount = leveragedAmount - 10;
      // need to revise
      _drawAusd(leveragedAmount);
      _disposeAusd();
      _investWant(want.balanceOf(address(this)));
    }
  }

  /**
   * @notice
   *  This function calculate the borrow position(the amount to add or remove) based on lending balance.
   * @param balance. the amount we're going to deposit or withdraw to venus platform
   * @param dep. flag(True/False) to deposit or withdraw
   * @return position the amount we want to change current borrow position
   * @return deficit flag(True/False). if reducing the borrow size, true
   */
  function _calculateDesiredPosition(uint256 balance, bool dep) internal view returns (uint256 position, bool deficit) {
    (uint256 collateral, uint256 debt, ) = _getCurrentPosition();
    uint256 unwoundDeposit = collateral.mul(ibToken.totalToken()).div(ibToken.totalSupply()).sub(debt);

    uint256 desiredSupply = 0;
    if (dep) {
      desiredSupply = unwoundDeposit.add(balance);
    } else {
      if (balance > unwoundDeposit) balance = unwoundDeposit;
      desiredSupply = unwoundDeposit.sub(balance);
    }

    uint256 num = desiredSupply.mul(collateralTarget);
    uint256 den = uint256(1e18).sub(collateralTarget);

    uint256 desiredBorrow = num.div(den);
    if (desiredBorrow > 1e5) {
      //stop us going right up to the wire
      desiredBorrow = desiredBorrow - 1e5;
    }

    if (desiredBorrow < debt) {
      deficit = true;
      position = debt - desiredBorrow;
    } else {
      deficit = false;
      position = desiredBorrow - debt;
    }

  }

  function _drawAusd(uint256 amount) internal {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));

    bytes memory _data = abi.encodeWithSignature(
      "draw(address,address,address,address,uint256,uint256,bytes)", 
      positionManager,
      stabilityFeeCollector,
      tokenAdapter,
      stablecoinAdapter,
      positionId,
      amount,
      abi.encode(address(this))
    );
    proxyWallet.execute(proxyActions, _data);
  }

  function _investWant(uint256 amount) internal {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));

    bytes memory _data = abi.encodeWithSignature(
      "convertAndLockToken(address,address,address,uint256,uint256,bytes)",
      ibToken,
      positionManager,
      tokenAdapter,
      positionId,
      amount,
      abi.encode(address(this))
    );
    proxyWallet.execute(proxyActions, _data);
  }

  function _withdrawIbToken(uint256 amount) internal {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));

    // withdraw ibusd
    bytes memory _data = abi.encodeWithSignature(
      "unlockToken(address,address,uint256,uint256,bytes)", 
      positionManager,
      tokenAdapter,
      positionId,
      amount,
      abi.encode(address(this))
    );

    proxyWallet.execute(proxyActions, _data);
  }

  function _repayBorrow(uint256 amount) internal {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));

    bytes memory _data = abi.encodeWithSignature(
      "wipe(address,address,address,uint256,uint256,bytes)",
      positionManager,
      tokenAdapter,
      stablecoinAdapter,
      positionId,
      amount,
      abi.encode(address(this))
    );
    proxyWallet.execute(proxyActions, _data);
  }

  function _openInvestBusd(uint256 amount, uint256 borrowAmount) external {
    

    // invest busd and lend ausd
    bytes memory _data = abi.encodeWithSignature(
      "convertOpenLockTokenAndDraw(address,address,address,address,address,bytes32,uint256,uint256,bytes)", 
      vault, 
      positionManager,
      stabilityFeeCollector,
      tokenAdapter,
      stablecoinAdapter,
      collateralPoolId,
      amount,
      borrowAmount,
      abi.encode(address(this))
    );
    proxyWallet.execute(proxyActions, _data);

  }
  
  function _investIbToken(uint256 amount) internal {

    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));

    bytes memory _data = abi.encodeWithSignature(
      "lockToken(address,address,uint256,uint256,bool,bytes)",
      positionManager,
      tokenAdapter,
      positionId,
      amount,
      true,
      abi.encode(address(this))
    );

    proxyWallet.execute(proxyActions, _data);
  }

  function investIbusdAndLendAusd(uint256 _collateralAmount, uint256 _stablecoinAmount) external {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxyWallet));

    bytes memory _data = abi.encodeWithSignature(
      "lockTokenAndDraw(address,address,address,address,uint256,uint256,uint256,bool,bytes)",
      positionManager,
      stabilityFeeCollector,
      tokenAdapter,
      stablecoinAdapter,
      positionId,
      _collateralAmount,
      _stablecoinAmount,
      true,
      abi.encode(address(this))
    );

    proxyWallet.execute(proxyActions, _data);
  }

  function _withdrawSome(uint256 _amount) internal {
    uint256 _amountShare = _amount.mul(ibToken.totalSupply()).div(ibToken.totalToken());
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

  function _disposeAusd() internal {
    uint256 _ausd = IERC20(ausd).balanceOf(address(this));
    uint256 _minReceiveAmount = _ausd.mul(95).div(100);
    IStableSwap(curveRouter).exchange_underlying(0, 1, IERC20(ausd).balanceOf(address(this)), _minReceiveAmount);
  }

  function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
    // get current asset amount
    uint256 _balance = want.balanceOf(address(this));
    (uint256 _collateral, uint256 _debt, ) = _getCurrentPosition();
    uint256 _assets = ibToken.balanceOf(address(this)).add(_collateral).mul(ibToken.totalToken()).div(ibToken.totalSupply());
    _assets = _balance.add(_assets).sub(_debt);

    uint256 debtOutstanding = vault.debtOutstanding(address(this));
    if (debtOutstanding > _assets) {
      _loss = debtOutstanding - _assets;
    }

    if (_assets < _amountNeeded) {
      _withdrawSome(uint256(-1));
      _amountFreed = _min(_amountNeeded, want.balanceOf(address(this)));
    } else {
      if (_balance < _amountNeeded) {
        _withdrawSome(_amountNeeded.sub(_balance));
        _amountFreed = _min(_amountNeeded, want.balanceOf(address(this)));
      } else {
        _amountFreed = _amountNeeded;
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
