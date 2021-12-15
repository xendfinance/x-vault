// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BaseStrategy.sol";
import "../interfaces/venus/VBep20I.sol";
import "../interfaces/venus/UnitrollerI.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";
import "../interfaces/flashloan/ERC3156FlashLenderInterface.sol";
import "../interfaces/flashloan/ERC3156FlashBorrowerInterface.sol";


contract StrategyUgoHawkVenusUSDTFarm is BaseStrategy, ERC3156FlashBorrowerInterface {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  UnitrollerI public constant venus = UnitrollerI(0xfD36E2c2a6789Db23113685031d7F16329158384);
  
  address public constant xvs = address(0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63);
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

  address public constant uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
  address public constant crWant = address(0xEF6d459FE81C3Ed53d292c936b2df5a8084975De);

  uint256 public collateralTarget = 0.73 ether; // 73%
  uint256 public minWant = 1 ether;

  bool public flashLoanActive = true;

  bool public forceMigrate = false;

  VBep20I public vToken;
  uint256 secondsPerBlock;     // approx seconds per block
  uint256 public blocksToLiquidationDangerZone; // 7 days =  60*60*24*7/secondsPerBlock
  uint256 public minXvsToSell = 100000000;

  // @notice emitted when trying to do Flash Loan. flashLoan address is 0x00 when no flash loan used
  event Leverage(uint256 amountRequested, uint256 amountGiven, bool deficit, address flashLoan);

  modifier management(){
    require(msg.sender == governance() || msg.sender == strategist, "!management");
    _;
  }

  constructor() public { }

  function initialize(
    address _vault,
    address _vToken,
    uint8 _secondsPerBlock
  ) public initializer {
    
    super.initialize(_vault);

    collateralTarget = 0.73 ether;
    minWant = 1 ether;
    flashLoanActive = true;
    forceMigrate = false;

    vToken = VBep20I(_vToken);
    IERC20(VaultAPI(_vault).token()).safeApprove(address(vToken), uint256(-1));
    IERC20(xvs).safeApprove(uniswapRouter, uint256(-1));

    secondsPerBlock = _secondsPerBlock;
    blocksToLiquidationDangerZone = 60 * 60 * 24 * 7 / _secondsPerBlock;
    maxReportDelay = 3600 * 24;
    profitFactor = 100;
  }

  function name() external override view returns (string memory) {
    return "StrategyUgoHawkVenusUSDTFarm";
  }

  function delegatedAssets() external override pure returns (uint256) {
    return 0;
  }

  function setFlashLoan(bool active) external management {
    flashLoanActive = active;
  }

  function setForceMigrate(bool _force) external onlyGovernance {
    forceMigrate = _force;
  }

  function setMinXvsToSell(uint256 _minXvsToSell) external management {
    minXvsToSell = _minXvsToSell;
  }

  function setMinWant(uint256 _minWant) external management {
    minWant = _minWant;
  }

  function setCollateralTarget(uint256 _collateralTarget) external management {
    (, uint256 collateralFactorMantissa, ) = venus.markets(address(vToken));
    require(collateralFactorMantissa > _collateralTarget, "!danagerous collateral");
    collateralTarget = _collateralTarget;
  }

  /**
   * Provide an accurate estimate for the total number of assets (principle + return) that this strategy 
   * is currently managing.
   */
  function estimatedTotalAssets() public override view returns (uint256) {
    (uint256 deposits, uint256 borrows) = getCurrentPosition();
    uint256 _claimableXVS = predictXvsAccrued();
    uint256 currentXvs = IERC20(xvs).balanceOf(address(this));

    uint256 estimatedWant = priceCheck(xvs, address(want), _claimableXVS.add(currentXvs));
    uint256 conservativeWant = estimatedWant.mul(9).div(10);      // remainig 10% will be used for compensate offset

    return want.balanceOf(address(this)).add(deposits).add(conservativeWant).sub(borrows);
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

  /**
   * Provide a signal to the keeper that 'tend()' should be called.
   */
  function tendTrigger(uint256 gasCost) public override view returns (bool) {
    if (harvestTrigger(gasCost)) {
      return false;
    }

    if (getblocksUntilLiquidation() <= blocksToLiquidationDangerZone) {
      return true;
    }
  }

  /**
   * Calcuate how many blocks until we are in liquidation based on current interest rates
   */
  function getblocksUntilLiquidation() public view returns (uint256) {
    (, uint256 collateralFactorMantissa, ) = venus.markets(address(vToken));
    
    (uint256 deposits, uint256 borrows) = getCurrentPosition();
    
    uint256 borrowRate = vToken.borrowRatePerBlock();
    uint256 supplyRate = vToken.supplyRatePerBlock();

    uint256 collateralisedDeposit1 = deposits.mul(collateralFactorMantissa).div(1e18);
    uint256 collateralisedDeposit = collateralisedDeposit1;

    uint256 denom1 = borrows.mul(borrowRate);
    uint256 denom2 = collateralisedDeposit.mul(supplyRate);

    if (denom2 >= denom1) {
      return uint256(-1);
    } else {
      uint256 numer = collateralisedDeposit.sub(borrows);
      uint256 denom = denom1 - denom2;
      return numer.mul(1e18).div(denom);
    }
  }

  // Return the current position
  function getCurrentPosition() public view returns (uint256 deposits, uint256 borrows) {
    (, uint256 vTokenBalance, uint256 borrowBalance, uint256 exchangeRate) = vToken.getAccountSnapshot(address(this));
    borrows = borrowBalance;

    deposits = vTokenBalance.mul(exchangeRate).div(1e18);
  }

  function netBalanceLent() public view returns (uint256) {
    (uint256 deposits, uint256 borrows) = getCurrentPosition();
    return deposits.sub(borrows);
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
    uint256 venusGasCost = priceCheck(wbnb, xvs, gasCost);

    uint256 _claimableXVS = predictXvsAccrued();

    if (_claimableXVS > minXvsToSell) {
      if (_claimableXVS.add(IERC20(xvs).balanceOf(address(this))) > venusGasCost.mul(profitFactor)) {
        return true;
      }
    }

    // trigger if hadn't been called in a while
    if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

    uint256 outstanding = vault.debtOutstanding(address(this));
    if (outstanding > profitFactor.mul(wantGasCost)) return true;

    uint256 total = estimatedTotalAssets();

    uint256 profit = 0;
    if (total > params.totalDebt) profit = total.sub(params.totalDebt);

    uint256 credit = vault.creditAvailable(address(this)).add(profit);
    return (profitFactor.mul(wantGasCost) < credit);
  }

  /**
   * @notice
   *  This function makes a prediction on how much xvs is accrued
   *  It is not 100% accurate as it uses current balances in Venus to predict into the past
   * @return XVS token amount available to claim
   */
  function predictXvsAccrued() public view returns (uint256) {
    (uint256 deposits, uint256 borrows) = getCurrentPosition();
    if (deposits == 0) {
      return 0;
    }

    uint256 distributionPerBlock = venus.venusSpeeds(address(vToken));
    uint256 totalBorrow = vToken.totalBorrows();
    uint256 totalSupplyVToken = vToken.totalSupply();
    uint256 totalSupply = totalSupplyVToken.mul(vToken.exchangeRateStored()).div(1e18);

    uint256 blockShareSupply = 0;
    if (totalSupply > 0) {
      blockShareSupply = deposits.mul(distributionPerBlock).div(totalSupply);
    }
    uint256 blockShareBorrow = 0;
    if (totalBorrow > 0) {
      blockShareBorrow = borrows.mul(distributionPerBlock).div(totalBorrow);
    }

    uint256 blockShare = blockShareSupply.add(blockShareBorrow);

    uint256 lastReport = vault.strategies(address(this)).lastReport;
    uint256 blocksSinceLast = (block.timestamp.sub(lastReport)).div(secondsPerBlock);

    return blocksSinceLast.mul(blockShare);
  }

  /**
   * Do anything necessary to prepare this Strategy for migration, such as transferring any reserve.
   */
  function prepareMigration(address _newStrategy) internal override {
    
    IERC20 _xvs = IERC20(xvs);
    uint256 _xvsBalance = _xvs.balanceOf(address(this));
    if (_xvsBalance > 0) {
      _xvs.safeTransfer(_newStrategy, _xvsBalance);
    }

    if (!forceMigrate) {
      (uint256 deposits, uint256 borrows) = getLivePosition();
      _withdrawSome(deposits.sub(borrows));

      (, , uint256 borrowBalance, ) = vToken.getAccountSnapshot(address(this));

      require(borrowBalance < 10_000, "DELEVERAGE_FIRST");

    } else {
      uint256 vTokenBalance = vToken.balanceOf(address(this));
      if (vTokenBalance > 0) {
        vToken.transfer(_newStrategy, vTokenBalance);
      }
    }
  }

  function distributeRewards() internal override {
    uint256 balance = vault.balanceOf(address(this));
    if (balance > 0) {
      vault.transfer(rewards, balance);
    }
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

  // debtPayment is token amount to return to vault
  // debtOutstanding is token amount that the vault ask to return
  function prepareReturn(uint256 _debtOutstanding) internal override returns (
    uint256 _profit,
    uint256 _loss,
    uint256 _debtPayment
  ) {
    _profit = 0;
    _loss = 0;

    if (vToken.balanceOf(address(this)) == 0) {
      uint256 wantBalance = want.balanceOf(address(this));
      _debtPayment = _min(wantBalance, _debtOutstanding);
      return (_profit, _loss, _debtPayment);
    }

    (uint256 deposits, uint256 borrows) = getLivePosition();

    _claimXvs();          // claim xvs tokens
    _disposeOfXvs();      // sell xvs tokens

    uint256 wantBalance = want.balanceOf(address(this));

    uint256 investedBalance = deposits.sub(borrows);
    uint256 balance = investedBalance.add(wantBalance);

    uint256 debt = vault.strategies(address(this)).totalDebt; 

    // `balance` - `total debt` is profit
    if (balance > debt) {
      _profit = balance - debt;
      if (wantBalance < _profit) {
        // all reserve is profit in case `profit` is greater than `wantBalance`
        _profit = wantBalance;
      } else if (wantBalance > _profit.add(_debtOutstanding)) {
        _debtPayment = _debtOutstanding;
      } else {
        _debtPayment = wantBalance - _profit;
      }
    } else {
      _loss = debt - balance;
      _debtPayment = _min(wantBalance, _debtOutstanding);
    }
  }

  // adjustPosition is called after report call
  // adjust the position using free available tokens
  /**
   * @notice
   *  adjustPosition is called after report call
   *  adjust the position using free available tokens
   * @param _debtOutstanding the amount to withdraw from strategy to vault
   */
  function adjustPosition(uint256 _debtOutstanding) internal override {
    if (emergencyExit) {
      return;
    }

    uint256 _wantBal = want.balanceOf(address(this));
    if (_wantBal < _debtOutstanding) {
      if (vToken.balanceOf(address(this)) > 1) {
        _withdrawSome(_debtOutstanding - _wantBal);
      }

      return;
    }

    (uint256 position, bool deficit) = _calculateDesiredPosition(_wantBal - _debtOutstanding, true);

    if (position > minWant) {
      if (!flashLoanActive) {
        uint i = 0;
        while(position > 0) {
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
          doFlashLoan(deficit, position);
        }
      }
    }
  }

  /**
   * @notice
   *  withdraw tokens from venus to adjust position
   * @param _amount we wanna withdraw and whether 
   */
  function _withdrawSome(uint256 _amount) internal returns (bool notAll) {
    (uint256 position, bool deficit) = _calculateDesiredPosition(_amount, false);

    if (deficit && position > minWant) {
      position = position.sub(doFlashLoan(deficit, position));
      
      uint8 i = 0;
      while (position > minWant.add(100)) {
        position = position.sub(_noFlashLoan(position, true));
        i++;

        if (i >= 5) {
          notAll = true;
          break;
        }
      }
    }

    (uint256 depositBalance, uint256 borrowBalance) = getCurrentPosition();
    uint256 tempColla = collateralTarget;

    uint256 reservedAmount = 0;
    if (tempColla == 0) {
      tempColla = 1e15;   // 0.001 * 1e18. minimum collateralTarget
    }

    reservedAmount = borrowBalance.mul(1e18).div(tempColla);

    if (depositBalance >= reservedAmount) {
      uint256 redeemable = depositBalance.sub(reservedAmount);

      if (redeemable < _amount) {
        vToken.redeemUnderlying(redeemable);
      } else {
        vToken.redeemUnderlying(_amount);
      }
    }

    if (collateralTarget == 0 && want.balanceOf(address(this)) > borrowBalance) {
      vToken.repayBorrow(borrowBalance);
    }

    _disposeOfXvs();
  }

  /**
   * @notice
   *  This function calculate the borrow position(the amount to add or remove) based on lending balance.
   * @param balance. the amount we're going to deposit or withdraw to venus platform
   * @param dep. flag(True/False) to deposit or withdraw
   * @return position the amount we want to change current borrow position
   * @return deficit flag(True/False). if reducing the borrow size, true
   */
  
  function _calculateDesiredPosition(uint256 balance, bool dep) internal returns(uint256 position, bool deficit) {
    (uint256 deposits, uint256 borrows) = getLivePosition();
    uint256 unwoundDeposit = deposits.sub(borrows);   // available token amount on lending platform. i.e. lended amount - borrowed amount

    uint256 desiredSupply = 0;
    if (dep) {
      desiredSupply = unwoundDeposit.add(balance);
    } else {
      if (balance > unwoundDeposit) balance = unwoundDeposit;
      desiredSupply = unwoundDeposit.sub(balance);
    }

    // db = (ds * c) / (1 - c)
    uint256 num = desiredSupply.mul(collateralTarget);
    uint256 den = uint256(1e18).sub(collateralTarget);

    uint256 desiredBorrow = num.div(den);
    if (desiredBorrow > 1e5) {
      //stop us going right up to the wire
      desiredBorrow = desiredBorrow - 1e5;
    }
    
    if (desiredBorrow < borrows) {
      deficit = true;
      position = borrows - desiredBorrow;
    } else {
      deficit = false;
      position = desiredBorrow - borrows;
    }
  }

  /**
   * do flash loan with desired amount
   */
  function doFlashLoan(bool deficit, uint256 amountDesired) internal returns (uint256) {
    if (amountDesired == 0) {
      return 0;
    }

    uint256 amount = amountDesired;
    bytes memory data = abi.encode(deficit, amount);

    ERC3156FlashLenderInterface(crWant).flashLoan(this, address(this), amount, data);
    emit Leverage(amountDesired, amount, deficit, crWant);

    return amount;
    
  }

  /**
   * @notice
   *  Three functions covering normal leverage and deleverage situations
   * @param max the max amount we want to increase our borrowed balance
   * @param deficit True if we are reducing the position size
   * @return amount actually did
   */
  function _noFlashLoan(uint256 max, bool deficit) internal returns (uint256 amount) {
    (uint256 lent, uint256 borrowed) = getCurrentPosition();
    // if we have nothing borrowed, can't deleverage any more(can't reduce borrow size)
    if (borrowed == 0 && deficit) {
      return 0;
    }
    (, uint256 collateralFactorMantissa, ) = venus.markets(address(vToken));

    if (deficit) {
      amount = _normalDeleverage(max, lent, borrowed, collateralFactorMantissa);
    } else {
      amount = _normalLeverage(max, lent, borrowed, collateralFactorMantissa);
    }

    emit Leverage(max, amount, deficit, address(0));
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
    if (collatRatio != 0) {
      theoreticalLent = borrowed.mul(1e18).div(collatRatio);
    }
    deleveragedAmount = lent.sub(theoreticalLent);

    if (deleveragedAmount >= borrowed) {
      deleveragedAmount = borrowed;
    }
    if (deleveragedAmount >= maxDeleverage) {
      deleveragedAmount = maxDeleverage;
    }

    uint256 exchangeRateStored = vToken.exchangeRateStored();

    if (deleveragedAmount.mul(1e18) >= exchangeRateStored && deleveragedAmount > 10) {
      deleveragedAmount = deleveragedAmount - 10;
      vToken.redeemUnderlying(deleveragedAmount);

      vToken.repayBorrow(deleveragedAmount);
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

    if (leveragedAmount >= maxLeverage) {
      leveragedAmount = maxLeverage;
    }
    if (leveragedAmount > 10) {
      leveragedAmount = leveragedAmount - 10;
      require(vToken.borrow(leveragedAmount) == 0, "got collateral?");
      require(vToken.mint(want.balanceOf(address(this))) == 0, "supply error");
    }
  }

  //Cream calls this function after doing flash loan
  /**
   * @notice
   *  called by cream flash loan contract
   * @param initiator the address of flash loan caller
   * @param token the address of token we borrowed
   * @param amount the amount borrowed
   * @param fee flash loan fee
   * @param data param data sent when loaning
   */
  function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) override external returns (bytes32) {
    // uint currentBalance = IERC20(underlying).balanceOf(address(this));
    require(initiator == address(this), "caller is not this contract");
    (bool deficit, uint256 borrowAmount) = abi.decode(data, (bool, uint256));
    require(borrowAmount == amount, "encoded data (borrowAmount) does not match");
    require(msg.sender == crWant, "Not Flash Loan Provider");
    
    _loanLogic(deficit, amount, amount + fee);

    IERC20(token).approve(msg.sender, amount + fee);
    return keccak256("ERC3156FlashBorrowerInterface.onFlashLoan");
  }

  /**
   * @notice
   *  logic after getting flash-loaned assets, called by executeOperation
   * @param deficit true if redeem, false if borrow
   * @param amount the amount to borrow
   * @param repayAmount the amount to repay
   */
  function _loanLogic(bool deficit, uint256 amount, uint256 repayAmount) internal returns (uint) {
    uint256 bal = want.balanceOf(address(this));
    require(bal >= amount, "Invalid balance, was the flashloan successful?");

    if (deficit) {
      vToken.repayBorrow(amount);
      vToken.redeemUnderlying(repayAmount);
    } else {
      require(vToken.mint(bal) == 0, "mint error");

      address[] memory vTokens = new address[](1);
      vTokens[0] = address(vToken);
      
      uint256[] memory errors = venus.enterMarkets(vTokens);
      if (errors[0] != 0) {
        revert("Comptroller.enterMarkets failed.");
      }
      
      (uint256 error, uint256 liquidity, uint256 shortfall) = venus.getAccountLiquidity(address(this));
      if (error != 0) {
        revert("Comptroller.getAccountLiquidity failed.");
      }
      require(shortfall == 0, "account underwater");
      require(liquidity > 0, "account has excess collateral");
      require(vToken.borrow(repayAmount) == 0, "borrow error");
    }
  }

  /**
   * @notice
   *  get the current position of strategy
   * @return deposits the amount lent
   * @return borrows the amount borrowed
   */
  function getLivePosition() public returns (uint256 deposits, uint256 borrows) {
    deposits = vToken.balanceOfUnderlying(address(this));
    borrows = vToken.borrowBalanceStored(address(this));
  }

  // claims XVS reward token
  function _claimXvs() internal {
    VTokenI[] memory tokens = new VTokenI[](1);
    tokens[0] = vToken;
    venus.claimVenus(address(this), tokens);
  }

  // sell harvested XVS tokens
  function _disposeOfXvs() internal {
    uint256 _xvs = IERC20(xvs).balanceOf(address(this));

    if (_xvs > minXvsToSell) {
      address[] memory path = new address[](3);
      path[0] = xvs;
      path[1] = wbnb;
      path[2] = address(want);

      IUniswapV2Router02(uniswapRouter).swapExactTokensForTokens(_xvs, uint256(0), path, address(this), now);
    }
  }

  /**
   * @notice
   *  Liquidate up to _amountNeeded of asset of this strategy's position
   *  irregardless of slippage.
   * @param _amountNeeded the amount to liquidate
   * @return _amountFreed the amount freed
   * @return _loss the amount lost
   */
  function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
    uint256 _balance = want.balanceOf(address(this));
    uint256 assets = netBalanceLent().add(_balance);

    uint256 debtOutstanding = vault.debtOutstanding(address(this));

    if (debtOutstanding > assets) {
      _loss = debtOutstanding - assets;
    }

    if (assets < _amountNeeded) {
      (uint256 deposits, uint256 borrows) = getLivePosition();
      if (vToken.balanceOf(address(this)) > 1) {
        _withdrawSome(deposits.sub(borrows));
      }

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

  function setProtectedTokens() internal override {
    protected[xvs] = true;
  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

}
