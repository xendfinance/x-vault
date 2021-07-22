// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BaseStrategy.sol";
import "../interfaces/venus/VBep20I.sol";
import "../interfaces/venus/UnitrollerI.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";


contract Strategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  UnitrollerI public constant venus = UnitrollerI(0xfD36E2c2a6789Db23113685031d7F16329158384);
  
  address public constant vai = address(0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7);
  address public constant xvs = address(0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63);
  address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

  address public constant uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);

  VBep20I public vToken;
  uint256 secondsPerBlock = 13;     // roughly 13 seconds per block
  uint256 public minXvsToSell = 0.1 ether;

  constructor(address _vault, address _vToken) public BaseStrategy(_vault) {
    vToken = VBep20I(_vToken);
    want.safeApprove(address(vToken), uint256(-1));
    
    maxReportDelay = 3600 * 24;
  }

  function name() external override view returns (string memory) {
    return "strategyGenericLevVenusFarm";
  }

  function estimatedTotalAssets() public override view returns (uint256) {
    (uint256 deposits, uint256 borrows) = getCurrentPosition();
    uint256 _claimableXVS = predictXvsAccrued();
    uint256 currentXvs = IERC20(xvs).balanceOf(address(this));

    uint256 estimatedWant = priceCheck(xvs, address(want), _claimableXVS.add(currentXvs));
    uint256 conservativeWant = estimatedWant.mul(9).div(10);      // remainig 10% will be used for compensate offset

    return want.balanceOf(address(this)).add(deposits).add(conservativeWant).sub(borrows);
  }

  function expectedReturn() public view returns (uint256) {
    uint256 estimatedAssets = estimatedTotalAssets();

    uint256 debt = vault.strategies(address(this)).totalDebt;
    if (debt > estimatedAssets) {
      return 0;
    } else {
      return estimatedAssets - debt;
    }
  }

  function getCurrentPosition() public view returns (uint256 deposits, uint256 borrows) {
    (, uint256 vTokenBalance, uint256 borrowBalance, uint256 exchangeRate) = vToken.getAccountSnapshot(address(this));
    borrows = borrowBalance;

    deposits = vTokenBalance.mul(exchangeRate).div(1e18);
  }

  /**
   * This function makes a prediction on how much xvs is accrued
   * It is not 100% accurate as it uses current balances in Venus to predict into the past
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

    if (balance > debt) {
      _profit = balance - debt;
      if (wantBalance < _profit) {
        _debtPayment = wantBalance;
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
  function adjustPosition(uint256 _debtOutstanding) internal override {
    if (emergencyExit) {
      return;
    }

    uint256 _wantBal = want.balanceOf(address(this));
    // if (_wantBal < _debtOutstanding)
  }

  function getLivePosition() public returns (uint256 deposits, uint256 borrows) {
    deposits = vToken.balanceOfUnderlying(address(this));
    borrows = vToken.borrowBalanceStored(address(this));
  }

  function _claimXvs() internal {
    VTokenI[] memory tokens = new VTokenI[](1);
    tokens[0] = vToken;
    venus.claimVenus(address(this), tokens);
  }

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

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

}
