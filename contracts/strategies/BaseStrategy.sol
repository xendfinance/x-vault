// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/VaultAPI.sol";

abstract contract BaseStrategy {
  using SafeMath for uint256;
  
  function apiVersion() public pure returns (string memory) {
    return '0.1.0';
  }

  function name() external virtual view returns (string memory);

  function delegatedAssets() external virtual pure returns (uint256) {
    return 0;
  }

  VaultAPI public vault;
  
  address public strategist;
  address public rewards;
  address public keeper;


  IERC20 public want;

  uint256 public maxReportDelay = 86400;

  uint256 public profitFactor = 100;

  uint256 public debtThreshold = 0;

  bool public emergencyExit;

  event EmergencyExitEnabled();
  event Harvested(uint256 profit, uint256 loss, uint256 debtPayment, uint256 debtOutstanding);

  modifier onlyKeepers() {
    require(msg.sender == keeper || msg.sender == strategist || msg.sender == governance(), "!keeper & !strategist & !governance");
    _;
  }

  modifier onlyAuthorized() {
    require(msg.sender == strategist || msg.sender == governance(), "!strategist & !governance");
    _;
  }

  modifier onlyGovernance() {
    require(msg.sender == governance(), "!authorized");
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
    adjustPosition(vault.debtOutstanding(address(this)));
  }

  function harvestTrigger(uint256 callCost) public virtual view returns (bool) {
    StrategyParams memory params = vault.strategies(address(this));

    if (params.activation == 0) return false;

    if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

    uint256 outstanding = vault.debtOutstanding(address(this));
    if (outstanding > debtThreshold) return true;

    uint256 total = estimatedTotalAssets();

    if (total.add(debtThreshold) < params.totalDebt) return true;

    uint256 profit = 0;
    if (total > params.totalDebt) profit = total.sub(params.totalDebt);

    uint256 credit = vault.creditAvailable();
    return (profitFactor.mul(callCost) < credit.add(profit));
  }

  /** 
   * @notice
   * Harvest the strategy.
   * This function can be called only by governance, the strategist or the keeper
   * harvest function is called in order to take in profits, to borrow newly available funds from the vault, or adjust the position
   */

  function harvest() external onlyKeepers {
    uint256 _profit = 0;
    uint256 _loss = 0;
    uint256 _debtOutstanding = vault.debtOutstanding(address(this));
    uint256 _debtPayment = 0;

    if (emergencyExit) {
      uint256 totalAssets = estimatedTotalAssets();     // accurated estimate for the total amount of assets that the strategy is managing in terms of want token.
      (_debtPayment, _loss) = liquidatePosition(totalAssets > _debtOutstanding ? totalAssets : _debtOutstanding);
      if (_debtPayment > _debtOutstanding) {
        _profit = _debtPayment.sub(_debtOutstanding);
        _debtPayment = _debtOutstanding;
      }
    } else {
      (_profit, _loss, _debtPayment) = prepareReturn(_debtOutstanding);
    }

    // returns available free tokens of this strategy
    // this debtOutstanding becomes prevDebtOutstanding - debtPayment
    _debtOutstanding = vault.report(_profit, _loss, _debtPayment);

    distributeRewards();
    adjustPosition(_debtOutstanding);

    emit Harvested(_profit, _loss, _debtPayment, _debtOutstanding);
  }

  // withdraw assets to the vault
  function withdraw(uint256 _amountNeeded) external returns (uint256 _loss) {
    require(msg.sender == address(vault), "!vault");
    uint256 amountFreed;
    (amountFreed, _loss) = liquidatePosition(_amountNeeded);
    want.transfer(msg.sender, amountFreed);
  }

  /**
   * Do anything necessary to prepare this Strategy for migration, such as
   * transferring any reserve or LP tokens, CDPs, or other tokens or stores of
   * value.
   */
  function prepareMigration(address _newStrategy) internal virtual;

  
  /**
   * Transfer all assets from current strategy to new strategy
   */
  function migrate(address _newStrategy) external {
    require(msg.sender == address(vault) || msg.sender == governance());
    require(BaseStrategy(_newStrategy).vault() == vault);
    prepareMigration(_newStrategy);
    want.transfer(_newStrategy, want.balanceOf(address(this)));
  }

  /**
   * @notice
   * Activates emergency exit. The strategy will be rovoked and withdraw all funds to the vault on the next harvest.
   * This may only be called by governance or the strategist.
   */

  function setEmergencyExit() external onlyAuthorized {
    emergencyExit = true;
    vault.revokeStrategy();

    emit EmergencyExitEnabled();
  }

  function protectedTokens() internal virtual view returns (address[] memory);

  // Removes tokens from this strategy that are not the type of tokens managed by this strategy
  function sweep(address _token) external onlyGovernance {
    require(_token != address(want), "!want");
    require(_token != address(vault), "!shares");

    address[] memory _protectedTokens = protectedTokens();
    for (uint256 i; i < _protectedTokens.length; i++) require(_token != _protectedTokens[i], "!protected");

    IERC20(_token).transfer(governance(), IERC20(_token).balanceOf(address(this)));
  }
}