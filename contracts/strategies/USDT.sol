// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BaseStrategy.sol";
import "../interfaces/venus/VBep20I.sol";
import "../interfaces/venus/UnitrollerI.sol";


contract Strategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  UnitrollerI public constant venus = UnitrollerI(0xfD36E2c2a6789Db23113685031d7F16329158384);
  
  address public constant vai = address(0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7);
  VBep20I public vToken;
  uint256 secondsPerBlock = 13;     // roughly 13 seconds per block

  constructor(address _vault, address _vToken) public BaseStrategy(_vault) {
    vToken = VBep20I(_vToken);
    want.safeApprove(address(vToken), uint256(-1));
    
    maxReportDelay = 3600 * 24;
  }

  function name() external override view returns (string memory) {
    return "strategyGenericLevVenusFarm";
  }

  function estimateTotalAssets() public override view returns (uint256) {
    (uint256 deposits, uint256 borrows) = getCurrentPosition();
    uint256 _claimableXVS = predictXvsAccrued();
    // uint256 currentXvs = IERC20()
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

}