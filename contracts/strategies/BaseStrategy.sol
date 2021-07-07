// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/VaultAPI.sol";

abstract contract BaseStrategy {
  using SafeMath for uint256;
  
  function apiVersion() public returns (string memory) {
    return '0.1.0';
  }

  function name() external virtual view returns (string memory);

  function delegatedAssets() external virtual view returns (uint256) {
    return 0;
  }

  address public strategist;
  address public rewards;
  address public keeper;


  IERC20 public want;

  uint256 public maxReportDelay = 86400;

  uint256 public profitFactor = 100;

  uint256 public debtThreshold = 0;

  bool public emergencyExit;

  modifier onlyKeepers() {
    require(msg.sender == keeper || msg.sender == strategist || msg.sender == governance(), "!authroized");
    _;
  }

  constructor(address _vault) public {
    vault = VaultAPI(_vault);
    want = IERC20(vault.token());
    want.approve(_vault, uint256(-1));
    strategist = msg.sender;
    rewards = msg.sender;
    keeper = msg.sender;
  }

  function governance() internal view returns (address) {
    return vault.governance();
  }

  function estimatedTotalAssets() public virtual view returns (uint256);

  function isActive() public view returns (bool) {
    return vault.strategies(address(this)).debtRatio > 0 || estimatedTotalAssets() > 0;
  }

  function prepareReturn(uint256 _debtOutstanding) internal virtual returns (
    uint256 _profit,
    uint256 _loss,
    uint256 _debtPayment
  );

  function adjustPosition(uint256 _debtOutstanding) internal virtual;

  function liquidatePosition(uint256 _amountNeeded) internal virtual returns (uint256 _liquidatedAmount, uint256 _loss);

  function distributeRewards() internal virtual {
    uint256 balance = vault.balanceOf(address(this));
    if (balance > 0) {
      vault.transfer(rewards, balance);
    }
  }

  function tendTrigger(uint256 callCost) public virtual view returns (bool) {
    return false;
  }

  function tend() external onlyKeepers {
    adjustPosition(vault.debtOutstanding());
  }

  function harvestTrigger(uint256 callCost) public virtual view returns (bool) {
    StrategyParams memory params = vault.strategies(address(this));

    if (params.activation == 0) return false;

    if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

    uint256 outstanding = vault.debtOutStanding();
    if (outstanding > debtThreshold) return true;

    uint256 total = estimatedTotalAssets();

    if (total.add(debtThreshold) < params.totalDebt) return true;

    uint256 profit = 0;
    if (total > params.totalDebt) profit = total.sub(params.totalDebt);

    uint256 credit = vault.creditAvailable();
    return (profitFactor.mul(callCost) < credit.add(profit));
  }
}