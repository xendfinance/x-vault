// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BaseStrategy.sol";
import "../interfaces/venus/VBep20I.sol";
import "../interfaces/venus/UnitrollerI.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";
import "../interfaces/flashloan/IFlashloanReceiver.sol";

contract EmergencyStrategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  VBep20I public vToken;
  
  address public constant xvs = address(0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63);
  uint256 immutable secondsPerBlock;     // approx seconds per block
  uint256 public immutable blocksToLiquidationDangerZone; // 7 days =  60 * 60 * 24 * 7 / secondsPerBlock

  address public constant uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
  mapping (address => bool) allowed;

  constructor(address _vault, address _vToken, uint8 _secondsPerBlock) public BaseStrategy(_vault) {
    vToken = VBep20I(_vToken);
    IERC20(VaultAPI(_vault).token()).safeApprove(address(vToken), uint256(-1));
    IERC20(xvs).safeApprove(uniswapRouter, uint256(-1));
    
    secondsPerBlock = _secondsPerBlock;
    blocksToLiquidationDangerZone = 60 * 60 * 24 * 7 / _secondsPerBlock;
    maxReportDelay = 3600 * 24;
    profitFactor = 100;
  }

  function name() external override view returns (string memory) {
    return "EmergencyStrategy";
  }

  function delegatedAssets() external override pure returns (uint256) {
    return 0;
  }

  function estimatedTotalAssets() public override view returns (uint256) {
    return want.balanceOf(address(this));
  }

  function prepareReturn(uint256 _debtOutstanding) internal override returns (
    uint256 _profit,
    uint256 _loss,
    uint256 _debtPayment
  ) {
    _profit = 0;
    _loss = 0;
    _debtPayment = 0;
  }

  function adjustPosition(uint256 _debtOutstanding) internal override {
    return;
  }

  function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
    _amountFreed = 0;
    _loss = 0;
  }

  function distributeRewards() internal override {
    uint256 balance = vault.balanceOf(address(this));
    if (balance > 0) {
      vault.transfer(rewards, balance);
    }
  }

  function tendTrigger(uint256 gasCost) public override view returns (bool) {
    return false;
  }

  function harvestTrigger(uint256 gasCost) public override view returns (bool) {
    return false;
  }

  /**
   * Do anything necessary to prepare this Strategy for migration, such as transferring any reserve.
   */
  function prepareMigration(address _newStrategy) internal override {
  }

  function setProtectedTokens() internal override {
    protected[xvs] = true;
  }

  function setAllowed(address _addr) external {
    require(msg.sender == strategist, "is not a strategist");
    allowed[_addr] = true;
  }

  function withdrawToRepay(uint256 amount) external {
    require(allowed[msg.sender] == true, "only allowed caller can withdraw");
    want.safeTransfer(msg.sender, amount);
  }

}
