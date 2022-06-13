// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "../interfaces/VaultAPI.sol";

/**
 *  BaseStrategy implements all of the required functionality to interoperate
 *  closely with the Vault contract. This contract should be inherited and the
 *  abstract methods implemented to adapt the Strategy to the particular needs
 *  it has to create a return.
 *
 *  Of special interest is the relationship between `harvest()` and
 *  `vault.report()'. `harvest()` may be called simply because enough time has
 *  elapsed since the last report, and not because any funds need to be moved
 *  or positions adjusted. This is critical so that the Vault may maintain an
 *  accurate picture of the Strategy's performance. See  `vault.report()`,
 *  `harvest()`, and `harvestTrigger()` for further details.
 */
abstract contract BaseStrategy is Initializable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  VaultAPI public vault;
  
  address public strategist;
  address public rewards;
  address public keeper;


  IERC20 public want;

  // The maximum number of seconds between harvest calls.
  uint256 public maxReportDelay;    // maximum report delay

  // The minimum multiple that `callCost` must be above the credit/profit to
  // be "justifiable". See `setProfitFactor()` for more details.
  uint256 public profitFactor;

  // Use this to adjust the threshold at which running a debt causes a
  // harvest trigger. See `setDebtThreshold()` for more details.
  uint256 public debtThreshold;

  bool public emergencyExit;

  mapping (address => bool) public protected;
  
  event Harvested(uint256 profit, uint256 loss, uint256 debtPayment, uint256 debtOutstanding);
  
  event UpdatedReportDelay(uint256 delay);
  
  event UpdatedProfitFactor(uint256 profitFactor);
  
  event UpdatedDebtThreshold(uint256 debtThreshold);
  
  event UpdatedStrategist(address newStrategist);

  event UpdatedKeeper(address newKeeper);

  event UpdatedRewards(address rewards);

  event EmergencyExitEnabled();

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

  modifier onlyStrategist() {
    require(msg.sender == strategist, "!strategist");
    _;
  }

  function initialize(
    address _vault
  ) public initializer {
    
    vault = VaultAPI(_vault);
    want = IERC20(VaultAPI(_vault).token());
    
    IERC20(VaultAPI(_vault).token()).safeApprove(_vault, uint256(-1));
    
    strategist = msg.sender;
    rewards = msg.sender;
    keeper = msg.sender;
    
    setProtectedTokens();
    
    profitFactor = 100;
    debtThreshold = 0;
    maxReportDelay = 86400;
  }
  
  function apiVersion() external pure returns (string memory) {
    return '0.1.0';
  }

  function name() external virtual view returns (string memory);

  function setStrategist(address _strategist) external onlyAuthorized {
    require(_strategist != address(0), "zero address");
    strategist = _strategist;
    emit UpdatedStrategist(_strategist);
  }

  function setKeeper(address _keeper) external onlyAuthorized {
    require(_keeper != address(0), "zero address");
    keeper = _keeper;
    emit UpdatedKeeper(_keeper);
  }

  function setRewards(address _rewards) external onlyStrategist {
    require(_rewards != address(0), "zero address");
    rewards = _rewards;
    emit UpdatedRewards(_rewards);
  }

  function setProfitFactor(uint256 _profitFactor) external onlyAuthorized {
    profitFactor = _profitFactor;
    emit UpdatedProfitFactor(_profitFactor);
  }

  function setDebtThreshold(uint256 _debtThreshold) external onlyAuthorized {
    debtThreshold = _debtThreshold;
    emit UpdatedDebtThreshold(_debtThreshold);
  }

  function setMaxReportDelay(uint256 _delay) external onlyAuthorized {
    maxReportDelay = _delay;
    emit UpdatedReportDelay(_delay);
  }

  /** 
   * @notice
   * Harvest the strategy.
   * This function can be called only by governance, the strategist or the keeper
   * harvest function is called in order to take in profits, to borrow newly available funds from the vault, or adjust the position
   */

  function harvest() external onlyKeepers {
    _harvest();
  }

  // withdraw assets to the vault
  function withdraw(uint256 _amountNeeded) external returns (uint256 amountFreed, uint256 _loss) {
    require(msg.sender == address(vault), "!vault");
    (amountFreed, _loss) = liquidatePosition(_amountNeeded);
    want.safeTransfer(msg.sender, amountFreed);
  }

  
  /**
   * Transfer all assets from current strategy to new strategy
   */
  function migrate(address _newStrategy) external {
    require(msg.sender == address(vault) || msg.sender == governance(), "!vault or !governance");
    require(BaseStrategy(_newStrategy).vault() == vault, "vault address is not the same");
    prepareMigration(_newStrategy);
    want.safeTransfer(_newStrategy, want.balanceOf(address(this)));
  }

  /**
   * @notice
   * Activates emergency exit. The strategy will be rovoked and withdraw all funds to the vault.
   * This may only be called by governance or the strategist.
   */

  function setEmergencyExit() external onlyAuthorized {
    emergencyExit = true;
    vault.revokeStrategy(address(this));

    emit EmergencyExitEnabled();
  }

  // Removes tokens from this strategy that are not the type of tokens managed by this strategy
  function sweep(address _token) external onlyGovernance {
    require(_token != address(want), "!want");
    require(_token != address(vault), "!shares");
    require(!protected[_token], "!protected");

    IERC20(_token).safeTransfer(governance(), IERC20(_token).balanceOf(address(this)));
  }

  /**
   * @notice
   *  Provide an accurate estimate for the total amount of assets
   *  (principle + return) that this Strategy is currently managing,
   *  denominated in terms of `want` tokens.
   * @return The estimated total assets in this Strategy.
   */
  function estimatedTotalAssets() external view returns (uint256) {
    return _estimatedTotalAssets();
  }

  /**
   * @notice
   *  Provide an indication of whether this strategy is currently "active"
   *  in that it is managing an active position, or will manage a position in
   *  the future. This should correlate to `harvest()` activity, so that Harvest
   *  events can be tracked externally by indexing agents.
   * @return True if the strategy is actively managing a position.
   */
  function isActive() external view returns (bool) {
    return vault.strategies(address(this)).debtRatio > 0 || _estimatedTotalAssets() > 0;
  }

  function harvestTrigger(uint256 callCost) external virtual view returns (bool) {
    StrategyParams memory params = vault.strategies(address(this));

    if (params.activation == 0) return false;

    if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

    uint256 outstanding = vault.debtOutstanding(address(this));
    if (outstanding > debtThreshold) return true;

    uint256 total = _estimatedTotalAssets();

    if (total.add(debtThreshold) < params.totalDebt) return true;

    uint256 profit = 0;
    if (total > params.totalDebt) profit = total.sub(params.totalDebt);

    uint256 credit = vault.creditAvailable(address(this));
    return (profitFactor.mul(callCost) < credit.add(profit));
  }

  function governance() internal view returns (address) {
    return vault.governance();
  }

  function _estimatedTotalAssets() internal virtual view returns (uint256);

  /**
   * Perform any Strategy unwinding or other calls necessary to capture the
   * "free return" this Strategy has generated since the last time its core
   * position(s) were adjusted. Examples include unwrapping extra rewards.
   * This call is only used during "normal operation" of a Strategy, and
   * should be optimized to minimize losses as much as possible.
   *
   * This method returns any realized profits and/or realized losses
   * incurred, and should return the total amounts of profits/losses/debt
   * payments (in `want` tokens) for the Vault's accounting (e.g.
   * `want.balanceOf(this) >= _debtPayment + _profit - _loss`).
   */
  function prepareReturn(uint256 _debtOutstanding) internal virtual returns (
    uint256 _profit,
    uint256 _loss,
    uint256 _debtPayment
  );

  /**
   * Perform any adjustments to the core position(s) of this Strategy given
   * what change the Vault made in the "investable capital" available to the
   * Strategy. Note that all "free capital" in the Strategy after the report
   * was made is available for reinvestment. Also note that this number
   * could be 0, and you should handle that scenario accordingly.
   */
  function adjustPosition(uint256 _debtOutstanding) internal virtual;

  /**
   * Liquidate up to `_amountNeeded` of `want` of this strategy's positions,
   * irregardless of slippage. Any excess will be re-invested with `adjustPosition()`.
   * This function should return the amount of `want` tokens made available by the
   * liquidation. If there is a difference between them, `_loss` indicates whether the
   * difference is due to a realized loss, or if there is some other sitution at play
   * (e.g. locked funds). This function is used during emergency exit instead of
   * `prepareReturn()` to liquidate all of the Strategy's positions back to the Vault.
   */
  function liquidatePosition(uint256 _amountNeeded) internal virtual returns (uint256 _liquidatedAmount, uint256 _loss);

  /**
   *  `Harvest()` calls this function after shares are created during
   *  `vault.report()`. You can customize this function to any share
   *  distribution mechanism you want.
   */
  function distributeRewards() internal virtual {
    uint256 balance = vault.balanceOf(address(this));
    if (balance > 0) {
      IERC20(vault).safeTransfer(rewards, balance);
    }
  }

  function _harvest() internal {
    uint256 _profit = 0;
    uint256 _loss = 0;
    uint256 _debtOutstanding = vault.debtOutstanding(address(this));
    uint256 _debtPayment = 0;

    if (emergencyExit) {
      uint256 totalAssets = _estimatedTotalAssets();     // accurated estimate for the total amount of assets that the strategy is managing in terms of want token.
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

  /**
   * Do anything necessary to prepare this Strategy for migration, such as
   * transferring any reserve or LP tokens, CDPs, or other tokens or stores of
   * value.
   */
  function prepareMigration(address _newStrategy) internal virtual;

  function setProtectedTokens() internal virtual;
}