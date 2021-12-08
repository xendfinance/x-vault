// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface Strategy {
  function want() external view returns (address);
  function vault() external view returns (address);
  function estimatedTotalAssets() external view returns (uint256);
  function withdraw(uint256 _amount) external returns (uint256, uint256);
  function migrate(address _newStrategy) external;
}

interface ITreasury {
  function depositToken(address token) external payable;
}


contract XVault is ERC20, ReentrancyGuard {
  using SafeERC20 for ERC20;
  using Address for address;
  using SafeMath for uint256;
  
  address public guardian;
  address public governance;
  address public management;
  ERC20 public immutable token;


  struct StrategyParams {
    uint256 performanceFee;     // strategist's fee
    uint256 activation;         // block.timstamp of activation of strategy
    uint256 debtRatio;          // percentage of maximum token amount of total assets that strategy can borrow from the vault
    uint256 rateLimit;          // limit rate per unit time, it controls the amount of token strategy can borrow last harvest
    uint256 lastReport;         // block.timestamp of the last time a report occured
    uint256 totalDebt;          // total outstanding debt that strategy has
    uint256 totalGain;          // Total returns that Strategy has realized for Vault
    uint256 totalLoss;          // Total losses that Strategy has realized for Vault
  }

  uint256 public constant MAX_BPS = 10000;
  uint256 public constant SECS_PER_YEAR = 60 * 60 * 24 * 36525 / 100;

  mapping (address => StrategyParams) public strategies;
  uint256 constant MAXIMUM_STRATEGIES = 20;
  address[] public withdrawalQueue;

  bool public emergencyShutdown;
  uint256 private apy = 0;
  
  uint256 private tokenBalance; // token.balanceOf(address(this))
  uint256 public depositLimit;  // Limit of totalAssets the vault can hold
  uint256 public debtRatio;
  uint256 public totalDebt;   // Amount of tokens that all strategies have borrowed
  uint256 public lastReport;  // block.timestamp of last report
  uint256 public immutable activation;  // block.timestamp of contract deployment
  uint256 private lastValuePerShare = 1000000000;

  ITreasury public treasury;    // reward contract where governance fees are sent to
  uint256 public managementFee;
  uint256 public performanceFee;

  event Deposit(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount);
  event UpdateTreasury(ITreasury treasury);
  event UpdateGuardian(address guardian);
  event UpdateManagement(address management);
  event UpdateDepositLimit(uint256 depositLimit);
  event UpdatePerformanceFee(uint256 fee);
  event StrategyRemovedFromQueue(address strategy);
  event UpdateManangementFee(uint256 fee);
  event EmergencyShutdown(bool active);
  event UpdateWithdrawalQueue(address[] queue);
  event StrategyAddedToQueue(address strategy);
  event StrategyReported(
    address indexed strategy,
    uint256 gain,
    uint256 loss,
    uint256 totalGain,
    uint256 totalLoss,
    uint256 totalDebt,
    uint256 debtAdded,
    uint256 debtRatio
  );
  event StrategyAdded(
    address indexed strategy,
    uint256 debtRatio,
    uint256 rateLimit,
    uint256 performanceFee
  );
  event StrategyUpdateDebtRatio(
    address indexed strategy, 
    uint256 debtRatio
  );
  event StrategyUpdateRateLimit(
    address indexed strategy,
    uint256 rateLimit
  );
  event StrategyUpdatePerformanceFee(
    address indexed strategy,
    uint256 performanceFee
  );
  event StrategyRevoked(
    address indexed strategy
  );
  event StrategyMigrated(
    address oldStrategy,
    address newStrategy
  );

  modifier governanceOnly() {
    require(msg.sender == governance, "!governance");
    _;
  }

  modifier guardianOnly() {
    require(msg.sender == governance || msg.sender == guardian, "caller must be governance or guardian");
    _;
  }

  modifier managementOnly {
    require(msg.sender == governance || msg.sender == management, "caller must be governance or management");
    _;
  }

  constructor(
    address _token,
    address _governance,
    ITreasury _treasury
  ) 
  public ERC20(
    string(abi.encodePacked("Xend ", ERC20(_token).name())),
    string(abi.encodePacked("xv", ERC20(_token).symbol()))
  ){
    require(_governance != address(0), "governance address can't be zero");
    require(address(_treasury) != address(0), "treasury address can't be zero");
    token = ERC20(_token);
    guardian = msg.sender;
    governance = _governance;
    management = _governance;
    treasury = _treasury;

    performanceFee = 1000;        // 10% of yield
    managementFee = 200;          // 2% per year
    lastReport = block.timestamp;
    activation = block.timestamp;

    _setupDecimals(ERC20(_token).decimals());
  }

  function setTreasury(ITreasury _treasury) external governanceOnly {
    require(address(_treasury) != address(0), "treasury address can't be zero");
    treasury = _treasury;
    emit UpdateTreasury(_treasury);
  }

  function setGuardian(address _guardian) external guardianOnly {
    require(_guardian != address(0), "guardian address can't be zero");
    guardian = _guardian;
    emit UpdateGuardian(_guardian);
  }

  function setGovernance(address _governance) external governanceOnly {
    require(_governance != address(0), "guardian address can't be zero");
    governance = _governance;
  }

  function setManagement(address _management) external governanceOnly {
    require(_management != address(0), "guardian address can't be zero");
    management = _management;
    emit UpdateManagement(_management);
  }

  function setDepositLimit(uint256 limit) external governanceOnly {
    depositLimit = limit;
    emit UpdateDepositLimit(depositLimit);
  }
  

  function setPerformanceFee(uint256 fee) external governanceOnly {
    require(fee <= MAX_BPS - performanceFee, "performance fee should be smaller than ...");
    performanceFee = fee;
    emit UpdatePerformanceFee(fee);
  }

  function setManagementFee(uint256 fee) external governanceOnly {
    require(fee < MAX_BPS, "management fee should be smaller than ...");
    managementFee = fee;
    emit UpdateManangementFee(fee);
  }

  function setEmergencyShutdown(bool active) external {
    /***
      Activates or deactivates vault

      During Emergency Shutdown, 
      1. User can't deposit into the vault but can withdraw
      2. can't add new strategy
      3. only governance can undo Emergency Shutdown
    */
    require(active != emergencyShutdown, "already active/inactive status");
    
    require(msg.sender == governance || (active && msg.sender == guardian), "caller must be guardian or governance");

    emergencyShutdown = active;
    emit EmergencyShutdown(active);
  }

  /**
   *  @notice
   *    Update the withdrawalQueue.
   *    This may only be called by governance or management.
   *  @param queue The array of addresses to use as the new withdrawal queue. This is order sensitive.
   */
  function setWithdrawalQueue(address[] memory queue) external managementOnly {
    require(queue.length < MAXIMUM_STRATEGIES, "withdrawal queue is over allowed maximum");
    for (uint i = 0; i < queue.length; i++) {
      require(strategies[queue[i]].activation > 0, "all the strategies should be active");
    }
    withdrawalQueue = queue;
    emit UpdateWithdrawalQueue(queue);
  }

  function getApy() external view returns (uint256) {
    return apy;
  }


  /**
   * Issues `amount` Vault shares to `to`.
   */
  function _issueSharesForAmount(address to, uint256 amount) internal returns (uint256) {
    uint256 shares = 0;
    if (totalSupply() > 0) {
      shares = amount.mul(totalSupply()).div(_totalAssets());
    } else {
      shares = amount;
    }

    _mint(to, shares);

    return shares;
  }

  /**
   * Deposit `_amount` issuing shares to `msg.sender`.
   * If the vault is in emergency shutdown, deposits will not be accepted and this call will fail.
   */
  function deposit(uint256 _amount) public nonReentrant returns (uint256) {
    require(emergencyShutdown != true, "in status of Emergency Shutdown");
    uint256 amount = _amount;
    if (amount == uint256(-1)) {
      amount = _min(depositLimit.sub(_totalAssets()), token.balanceOf(msg.sender));
    } else {
      require(_totalAssets().add(amount) <= depositLimit, "exceeds deposit limit");
    }
    
    require(amount > 0, "deposit amount should be bigger than zero");

    uint256 shares = _issueSharesForAmount(msg.sender, amount);

    token.safeTransferFrom(msg.sender, address(this), amount);
    tokenBalance = tokenBalance.add(amount);
    emit Deposit(msg.sender, amount);

    return shares;
  }

  /**
   * Return the total quantity of assets
   * i.e. current balance of assets + total assets that strategies borrowed from the vault 
   */
  function _totalAssets() internal view returns (uint256) {
    return tokenBalance.add(totalDebt);
  }

  function totalAssets() external view returns (uint256) {
    return _totalAssets();
  }

  function balance() public view returns (uint256) {
    return token.balanceOf(address(this));
  }

  function _shareValue(uint256 _share) internal view returns (uint256) {
    // Determine the current value of `shares`
    return _share.mul(_totalAssets()).div(totalSupply());
  }

  function _sharesForAmount(uint256 amount) internal view returns (uint256) {
    // Determine how many shares `amount` of token would receive
    if (_totalAssets() > 0) {
      return amount.mul(totalSupply()).div(_totalAssets());
    } else {
      return 0;
    }
  }

  /**
   * @notice
   *    Determines the total quantity of shares this Vault can provide,
   *    factoring in assets currently residing in the Vault, as well as those deployed to strategies.
   * @dev
   *    If you want to calculate the maximum a user could withdraw up to, need to use this function
   * @return The total quantity of shares this Vault can provide
   */
  function maxAvailableShares() external view returns (uint256) {
    uint256 _shares = _sharesForAmount(token.balanceOf(address(this)));

    for (uint i = 0; i < withdrawalQueue.length; i++) {
      if (withdrawalQueue[i] == address(0)) break;
      _shares = _shares.add(_sharesForAmount(strategies[withdrawalQueue[i]].totalDebt));
    }

    return _shares;
  }

  /**
   * Withdraw the `msg.sender`'s tokens from the vault, redeeming amount `_shares`
   * for an appropriate number of tokens.
   * @param maxShare How many shares to try and redeem for tokens, defaults to all.
   * @param recipient The address to issue the shares in this Vault to, defaults to the caller's address
   * @param maxLoss The maximum acceptble loss to sustain on withdrawal, defaults to 0%.
   * @return The quantity of tokens redeemed for `_shares`.
   */
  function withdraw(
    uint256 maxShare,
    address recipient,
    uint256 maxLoss     // if 1, 0.01%
  ) public nonReentrant returns (uint256) {
    tokenBalance = token.balanceOf(address(this));
    uint256 shares = maxShare;
    if (maxShare == 0) {
      shares = balanceOf(msg.sender);
    }
    if (recipient == address(0)) {
      recipient = msg.sender;
    }

    require(shares <= balanceOf(msg.sender), "share should be smaller than their own");
    
    uint256 value = _shareValue(shares);
    uint256 totalLoss = 0;
    if (value > token.balanceOf(address(this))) {
      
      for(uint i = 0; i < withdrawalQueue.length; i++) {
        address strategy = withdrawalQueue[i];
        if (strategy == address(0)) {
          break;
        }
        if (value <= token.balanceOf(address(this))) {
          break;
        }

        uint256 amountNeeded = value.sub(token.balanceOf(address(this)));    // recalculate the needed token amount to withdraw
        amountNeeded = _min(amountNeeded, strategies[strategy].totalDebt);
        if (amountNeeded == 0)
          continue;
        
        (uint256 withdrawn, uint256 loss) = Strategy(strategy).withdraw(amountNeeded);
        tokenBalance = tokenBalance.add(withdrawn);

        if (loss > 0) {
          value = value.sub(loss);
          totalLoss = totalLoss.add(loss);
          strategies[strategy].totalLoss = strategies[strategy].totalLoss.add(loss);
        }
        strategies[strategy].totalDebt = strategies[strategy].totalDebt.sub(withdrawn.add(loss));
        totalDebt = totalDebt.sub(withdrawn.add(loss));
      }

    }

    if (value > token.balanceOf(address(this))) {
      value = token.balanceOf(address(this));
      shares = _sharesForAmount(value);
    }
    
    _burn(msg.sender, shares);
    
    require(totalLoss <= maxLoss.mul(value.add(totalLoss)).div(MAX_BPS), "revert if totalLoss is more than permitted");
    token.safeTransfer(recipient, value);
    tokenBalance = tokenBalance.sub(value);
    emit Withdraw(recipient, value);
    
    return value;
  }

  /**
   * @notice
   *    Add a Strategy to the Vault.
   *    This may only be called by governance.
   * @param _strategy The address of Strategy to add
   * @param _debtRatio The ratio of total assets in the Vault that strategy can manage
   * @param _rateLimit Limit on the increase of debt per unit time since last harvest
   * @param _performanceFee The fee the strategist will receive based on this Vault's performance.
   */
  function addStrategy(address _strategy, uint256 _debtRatio, uint256 _rateLimit, uint256 _performanceFee) public governanceOnly {
    require(_strategy != address(0), "strategy address can't be zero");
    require(!emergencyShutdown, "in status of Emergency Shutdown");
    require(_performanceFee <= MAX_BPS - performanceFee, "performance fee should be smaller than ...");
    require(debtRatio.add(_debtRatio) <= MAX_BPS, "total debt ratio should be smaller than MAX_BPS");
    require(strategies[_strategy].activation == 0, "already activated");
    require(Strategy(_strategy).vault() == address(this), "is not one for this vault");
    require(Strategy(_strategy).want() == address(token), "incorrect want token for this vault");

    strategies[_strategy] = StrategyParams({
      performanceFee: _performanceFee,
      activation: block.timestamp,
      debtRatio: _debtRatio,
      rateLimit: _rateLimit,
      lastReport: block.timestamp,
      totalDebt: 0,
      totalGain: 0,
      totalLoss: 0
    });

    debtRatio = debtRatio.add(_debtRatio);
    
    emit StrategyAdded(_strategy, _debtRatio, _rateLimit, _performanceFee);

    withdrawalQueue.push(_strategy);

  }

  /**
   * @notice
   *    Change the quantity of assets `strategy` may manage.
   *    This may be called by governance or management
   * @param _strategy The strategy to update
   * @param _debtRatio The quantity of assets `strategy` may now manage
   */
  function updateStrategyDebtRatio(address _strategy, uint256 _debtRatio) external managementOnly {
    require(strategies[_strategy].activation > 0, "the strategy not activated");
    debtRatio = debtRatio.sub(strategies[_strategy].debtRatio);
    strategies[_strategy].debtRatio = _debtRatio;
    debtRatio = debtRatio.add(_debtRatio);
    require(debtRatio <= MAX_BPS, "debtRatio should be smaller than MAX_BPS");
    emit StrategyUpdateDebtRatio(_strategy, _debtRatio);
  }

  /**
   * @notice
   *    Change the quantity of assets per block this Vault may deposit to or withdraw from `strategy`.
   *    This may only be called by governance or management.
   * @param _strategy The strategy to update
   * @param _rateLimit Limit on the increase of debt per unit time since the last harvest
   */
  function updateStrategyRateLimit(address _strategy, uint256 _rateLimit) external managementOnly {
    require(strategies[_strategy].activation > 0, "the strategy not activated");
    strategies[_strategy].rateLimit = _rateLimit;
    emit StrategyUpdateRateLimit(_strategy, _rateLimit);
  }

  /**
   * @notice 
   *    Change the fee the strategist will receive based on this Vault's performance
   *    This may only be called by goverance.
   * @param _strategy The strategy to update
   * @param _performanceFee The new fee the strategist will receive
   */
  function updateStrategyPerformanceFee(address _strategy, uint256 _performanceFee) external governanceOnly {
    require(performanceFee <= MAX_BPS - performanceFee, "fee should be smaller than MAX_BPS reduced by vault performance fee");
    require(strategies[_strategy].activation > 0, "the strategy not activated");
    strategies[_strategy].performanceFee = _performanceFee;
    emit StrategyUpdatePerformanceFee(_strategy, _performanceFee);
  }

  /**
   *  @notice
   *    Add `strategy` to `withdrawalQueue`.
   *    This may only be called by governance or management.
   *  @dev
   *    The Strategy will be appended to `withdrawalQueue`, call `setWithdrawalQueue` to change the order.
   *  @param _strategy The Strategy to add.
   */
  function addStrategyToQueue(address _strategy) external managementOnly {
    require(strategies[_strategy].activation > 0, "the strategy not activated");
    require(withdrawalQueue.length < MAXIMUM_STRATEGIES, "withdrawal queue is over allowed maximum");
    for (uint i = 0; i < withdrawalQueue.length; i++) {
      require(withdrawalQueue[i] != _strategy, "the strategy already added to the withdrawal queue");
    }
    withdrawalQueue.push(_strategy);
    emit StrategyAddedToQueue(_strategy);
  }

  /**
   * @notice
   *    Remove `strategy` from `withdrawalQueue`
   *    This may only be called by governance or management.
   * @param _strategy The Strategy to remove
   */
  function removeStrategyFromQueue(address _strategy) external managementOnly {
    
    for (uint i = 0; i < withdrawalQueue.length; i++) {
      
      if (withdrawalQueue[i] == _strategy) {
        withdrawalQueue[i] = withdrawalQueue[withdrawalQueue.length - 1];
        withdrawalQueue.pop();
        emit StrategyRemovedFromQueue(_strategy);
      }
    
    }
  }

  /**
   * @notice
   *    Revoke a Strategy, setting its debt limit to 0 and preventing any future deposits.
   *    This may only be called by governance, the guardian, or the Strategy itself.
   * @param _strategy The strategy to revoke
   */
  function revokeStrategy(address _strategy) public {
    require(msg.sender == _strategy || msg.sender == governance || msg.sender == guardian, "should be one of 3 admins");
    _revokeStrategy(_strategy);
  }

  function _revokeStrategy(address _strategy) internal {
    require(strategies[_strategy].debtRatio > 0, "the strategy already revoked");
    debtRatio = debtRatio.sub(strategies[_strategy].debtRatio);
    strategies[_strategy].debtRatio = 0;
    tokenBalance = token.balanceOf(address(this));
    emit StrategyRevoked(_strategy);
  }

  /**
   *  @notice
   *    Migrate a Strategy, including all assets from `oldVersion` to `newVersion`.
   *    This may only be called by governance.
   *  @param oldVersion The existing Strategy to migrate from.
   *  @param newVersion The new Strategy to migrate to.
   */
  function migrateStrategy(address oldVersion, address newVersion) external governanceOnly {
    require(newVersion != address(0), "new strategy can't be a zero");
    require(strategies[oldVersion].activation > 0, "the old strategy should've been active");
    require(strategies[newVersion].activation == 0, "the new strategy already activated before");

    StrategyParams memory strategy = strategies[oldVersion];
    _revokeStrategy(oldVersion);
    debtRatio = debtRatio.add(strategy.debtRatio);
    strategies[oldVersion].totalDebt = 0;

    strategies[newVersion] = StrategyParams({
      performanceFee: strategy.performanceFee,
      activation: block.timestamp,
      debtRatio: strategy.debtRatio,
      rateLimit: strategy.rateLimit,
      lastReport: block.timestamp,
      totalDebt: strategy.totalDebt,
      totalGain: 0,
      totalLoss: 0
    });

    Strategy(oldVersion).migrate(newVersion);
    emit StrategyMigrated(oldVersion, newVersion);

    for (uint i = 0; i < withdrawalQueue.length; i++) {
      if (withdrawalQueue[i] == oldVersion) {
        withdrawalQueue[i] = newVersion;
        return;
      }
    }
  }

  /**
   * @notice
   *    Provide an accurate expected value for the return this `strategy`
   * @param _strategy The Strategy to determine the expected return for. Defaults to caller.
   * @return
   *    The anticipated amount `strategy` should make on its investment since its last report.
   */
  function expectedReturn(address _strategy) external view returns (uint256) {
    return _expectedReturn(_strategy);
  }

  function _expectedReturn(address _strategy) internal view returns (uint256) {
    uint256 delta = block.timestamp - strategies[_strategy].lastReport;
    if (delta > 0) {
      return strategies[_strategy].totalGain.mul(delta).div(block.timestamp - strategies[_strategy].activation);
    } else {
      return 0;
    }
  }

  function availableDepositLimit() external view returns (uint256) {
    if (depositLimit > _totalAssets()) {
      return depositLimit.sub(_totalAssets());
    } else {
      return 0;
    }
  }

  /**
   * @notice Gives the price for a single Vault share.
   * @return The value of a single share.
   */
  function pricePerShare() external view returns (uint256) {
    if (totalSupply() == 0) {
      // return 10 ** decimals();      // price of 1:1
      return _totalAssets() > (uint256(10) ** decimals()) ? _totalAssets() : uint256(10) ** decimals();
    } else {
      return _shareValue(uint256(10) ** decimals());
    }
  }

  /**
   * @notice
   *    Determines if `strategy` is past its debt limit and if any tokens
   *    should be withdrawn to the Vault.
   * @param _strategy The Strategy to check. Defaults to the caller.
   * @return The quantity of tokens to withdraw.
   */
  function debtOutstanding(address _strategy) external view returns (uint256) {
    return _debtOutstanding(_strategy);
  }

  /**
   * Returns assets amount of strategy that is past its debt limit
   */
  function _debtOutstanding(address _strategy) internal view returns (uint256) {
    uint256 strategy_debtLimit = strategies[_strategy].debtRatio.mul(_totalAssets()).div(MAX_BPS);
    uint256 strategy_totalDebt = strategies[_strategy].totalDebt;

    if (emergencyShutdown) {      // if emergency status, return current debt
      return strategy_totalDebt;
    } else if (strategy_totalDebt <= strategy_debtLimit) {
      return 0;
    } else {
      return strategy_totalDebt.sub(strategy_debtLimit);
    }
  }

  function _assessFees(address _strategy, uint256 gain) internal {
    // issue new shares to cover fees
    // as a result, it reduces share token price by fee amount

    uint256 governance_fee = _totalAssets().mul(block.timestamp.sub(lastReport)).mul(managementFee).div(MAX_BPS).div(SECS_PER_YEAR);
    uint256 strategist_fee = 0;

    if (gain > 0) {     // apply strategy fee only if there's profit. if loss or no profit, it didn't get applied
      strategist_fee = gain.mul(strategies[_strategy].performanceFee).div(MAX_BPS);
      governance_fee = governance_fee.add(gain.mul(performanceFee).div(MAX_BPS));
    }

    uint256 totalFee = governance_fee + strategist_fee;
    if (totalFee > 0) {
      uint256 reward = _issueSharesForAmount(address(this), totalFee);
      
      if (strategist_fee > 0) {
        uint256 strategist_reward = strategist_fee.mul(reward).div(totalFee);
        _transfer(address(this), _strategy, strategist_reward);
      }
      if (balanceOf(address(this)) > 0) {
        _approve(address(this), address(treasury), balanceOf(address(this)));
        treasury.depositToken(address(this));
      }
    }
  }

  function _reportLoss(address _strategy, uint256 loss) internal {
    uint256 _totalDebt = strategies[_strategy].totalDebt;
    require(_totalDebt >= loss, "loss can't be bigger than deposited debt");

    strategies[_strategy].totalLoss = strategies[_strategy].totalLoss.add(loss);
    strategies[_strategy].totalDebt = _totalDebt.sub(loss);

    // reduce debtRatio if loss happens
    uint256 _debtRatio = strategies[_strategy].debtRatio;
    uint256 ratioChange = _min(loss.mul(debtRatio).div(_totalAssets()), _debtRatio);
    strategies[_strategy].debtRatio = _debtRatio.sub(ratioChange);
    debtRatio = debtRatio.sub(ratioChange);

    totalDebt = totalDebt.sub(loss);
  }

  /**
   * @notice
   *    Amount of tokens in Vault a Strategy has access to as a credit line.
   *    This will check the Strategy's debt limit, as well as the tokens
   *    available in the Vault, and determine the maximum amount of tokens
   *    (if any) the Strategy may draw on.
   * @param _strategy The Strategy to check. Defaults to caller.
   * @return The quantity of tokens available for the Strategy to draw on.
   */
  function creditAvailable(address _strategy) external view returns (uint256) {
    return _creditAvailable(_strategy);
  }

  function _creditAvailable(address _strategy) internal view returns (uint256) {
    if (emergencyShutdown) {
      return 0;
    }

    uint256 vault_totalAssets = _totalAssets();
    uint256 vault_debtLimit = debtRatio.mul(vault_totalAssets).div(MAX_BPS);
    uint256 vault_totalDebt = totalDebt;

    uint256 strategy_debtLimit = strategies[_strategy].debtRatio.mul(vault_totalAssets).div(MAX_BPS);
    uint256 strategy_totalDebt = strategies[_strategy].totalDebt;
    uint256 strategy_rateLimit = strategies[_strategy].rateLimit;
    uint256 strategy_lastReport = strategies[_strategy].lastReport;

    if (strategy_debtLimit <= strategy_totalDebt || vault_debtLimit <= vault_totalDebt) {
      return 0;
    }

    uint256 _available = strategy_debtLimit.sub(strategy_totalDebt);
    _available = _min(_available, vault_debtLimit.sub(vault_totalDebt));

    // if available token amount is bigger than the limit per report period, adjust it.
    uint256 delta = block.timestamp.sub(strategy_lastReport);      // time difference between current time and last report(i.e. harvest)
    if (strategy_rateLimit > 0 && _available >= strategy_rateLimit.mul(delta)) {
      _available = strategy_rateLimit.mul(delta);
    }

    return _min(_available, token.balanceOf(address(this)));
  }

  /**
   * @notice
   *    Reports the amount of assets the calling Strategy has free
   *    The performance fee, strategist's fee are determined here
   *    Returns outstanding debt
   * @param gain Amount Strategy has realized as a gain on it's investment since its
   *    last report, and is free to be given back to Vault as earnings
   * @param loss Amount Strategy has realized as a loss on it's investment since its
   *    last report, and should be accounted for on the Vault's balance sheet
   * @param _debtPayment Amount Strategy has made available to cover outstanding debt
   * @return Amount of debt outstanding (if totalDebt > debtLimit or emergency shutdown).
   */
  function report(uint256 gain, uint256 loss, uint256 _debtPayment) external returns (uint256) {
    require(strategies[msg.sender].activation > 0, "strategy should be active");
    require(token.balanceOf(msg.sender) >= gain.add(_debtPayment), "insufficient token balance of strategy");

    if (loss > 0) {
      _reportLoss(msg.sender, loss);
    }

    _assessFees(msg.sender, gain);

    strategies[msg.sender].totalGain = strategies[msg.sender].totalGain.add(gain);

    uint256 debt = _debtOutstanding(msg.sender);
    uint256 debtPayment = _min(_debtPayment, debt);

    if (debtPayment > 0) {
      strategies[msg.sender].totalDebt = strategies[msg.sender].totalDebt.sub(debtPayment);
      totalDebt = totalDebt.sub(debtPayment);
      debt = debt.sub(debtPayment);
    }

    // get the available tokens to borrow from the vault
    uint256 credit = _creditAvailable(msg.sender);

    if (credit > 0) {
      strategies[msg.sender].totalDebt = strategies[msg.sender].totalDebt.add(credit);
      totalDebt = totalDebt.add(credit);
    }

    uint256 totalAvailable = gain.add(debtPayment);
    if (totalAvailable < credit) {
      token.safeTransfer(msg.sender, credit.sub(totalAvailable));
      tokenBalance = tokenBalance.sub(credit.sub(totalAvailable));
    } else if (totalAvailable > credit) {
      token.safeTransferFrom(msg.sender, address(this), totalAvailable.sub(credit));
      tokenBalance = tokenBalance.add(totalAvailable.sub(credit));
    }
    // else (if totalAvailable == credit), it is already balanced so do nothing.

    // Update APY
    if (totalSupply() == 0) {
      apy = 0;
    } else {
      uint256 valuePerShare = _totalAssets().mul(1000000000).div(totalSupply());
      if (valuePerShare > lastValuePerShare) {
        apy = valuePerShare.sub(lastValuePerShare).mul(365 days).div(block.timestamp.sub(lastReport)).mul(1000).div(lastValuePerShare);
      } else {
        apy = 0;
      }
      lastValuePerShare = valuePerShare;
    }
    

    // Update reporting time
    strategies[msg.sender].lastReport = block.timestamp;
    lastReport = block.timestamp;

    emit StrategyReported(
      msg.sender,
      gain,
      loss,
      strategies[msg.sender].totalGain,
      strategies[msg.sender].totalLoss,
      strategies[msg.sender].totalDebt,
      credit,
      strategies[msg.sender].debtRatio
    );

    if (strategies[msg.sender].debtRatio == 0 || emergencyShutdown) {
      // this block is used for getting penny
      // if Strategy is rovoked or exited for emergency, it could have some token that wan't withdrawn
      // this is different from debt
      return Strategy(msg.sender).estimatedTotalAssets();
    } else {
      return debt;
    }

  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

}
