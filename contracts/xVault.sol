// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// interface GuestList {
//   function authorized(address guest, uint256 amount) public returns (bool);
// }

interface Strategy {
  function want() external view returns (address);
  function vault() external view returns (address);
  function estimateTotalAssets() external view returns (uint256);
  function withdraw(uint256 _amount) external returns (uint256, uint256);
  function migrate(address _newStrategy) external;
}

interface ITreasury {
  function depositToken(address token) external payable;
}


contract XVault is ERC20 {
  using SafeERC20 for ERC20;
  using Address for address;
  using SafeMath for uint256;
  
  address public guardian;
  address public governance;
  address public management;
  ERC20 public token;

  // GuestList guestList;

  struct StrategyParams {
    uint256 performanceFee;     // strategist's fee
    uint256 activation;         // block.timstamp of activation of strategy
    uint256 debtRatio;          // percentage of maximum token amount of total assets that strategy can borrow from the vault
    uint256 rateLimit;          // limit rate per unit time, it controls the amount of token strategy can borrow last harvest
    uint256 lastReport;
    uint256 totalDebt;          // total outstanding debt that strategy has
    uint256 totalGain;
    uint256 totalLoss;
  }

  uint256 public MAX_BPS = 100;
  uint256 public SECS_PER_YEAR = 60 * 60 * 24 * 36525 / 100;

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
  uint256 public activation;  // block.timestamp of contract deployment
  uint256 private lastValuePerShare = 1000000000;

  ITreasury public treasury;    // reward contract where governance fees are sent to
  uint256 public managementFee;
  uint256 public performanceFee;

  event UpdateTreasury(ITreasury treasury);
  event UpdateGuardian(address guardian);
  event UpdateGuestList(address guestList);
  event UpdateDepositLimit(uint256 depositLimit);
  event UpdatePerformanceFee(uint256 fee);
  event StrategyRemovedFromQueue(address strategy);
  event UpdateManangementFee(uint256 fee);
  event EmergencyShutdown(bool active);
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
  event StrategyRevoked(
    address indexed strategy
  );

  constructor(
    address _token,
    address _governance,
    ITreasury _treasury
  ) 
  public ERC20(
    string(abi.encodePacked("xend ", ERC20(_token).name())),
    string(abi.encodePacked("xv", ERC20(_token).symbol()))
  ){

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

  // function setName(string memory _name) external {
  //   require(msg.sender == governance, "!governance");
  //   name = _name;
  // }

  // function setSymbol(string memory _symbol) external {
  //   require(msg.sender == governance, "!governance");
  //   symbol = _symbol;
  // }

  function setTreasury(ITreasury _treasury) external {
    require(msg.sender == governance, "!governance");
    treasury = _treasury;
    emit UpdateTreasury(_treasury);
  }

  function setGuardian(address _guardian) external {
    require(msg.sender == governance || msg.sender == guardian, "caller must be governance or guardian");
    guardian = _guardian;
    emit UpdateGuardian(_guardian);
  }

  function balance() public view returns (uint256) {
    return token.balanceOf(address(this));
  }

  function setGovernance(address _governance) external {
    require(msg.sender == governance, "!governance");
    governance = _governance;
  }

  // function setGuestList(address _guestList) external {
  //   require(msg.sender == governance, "!governance");
  //   guestList = GuestList(_guestList);
  //   emit UpdateGuestList(guestList);
  // }

  function setDepositLimit(uint256 limit) external {
    require(msg.sender == governance, "!governance");
    depositLimit = limit;
    emit UpdateDepositLimit(depositLimit);
  }
  

  function setPerformanceFee(uint256 fee) external {
    require(msg.sender == governance, "!governance");
    require(fee < MAX_BPS, "performance fee should be smaller than ...");
    performanceFee = fee;
    emit UpdatePerformanceFee(fee);
  }

  function setManagementFee(uint256 fee) external {
    require(msg.sender == governance, "!governance");
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
    
    if (active) {
      require(msg.sender == guardian || msg.sender == governance, "caller must be guardian or governance");
    } else {
      require(msg.sender == governance, "caller must be governance");
    }
    emergencyShutdown = active;
    emit EmergencyShutdown(active);
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
  function deposit(uint256 _amount) public returns (uint256) {
    require(emergencyShutdown != true, "in status of Emergency Shutdown");
    uint256 amount = _amount;
    if (amount == 0) {
      amount = _min(depositLimit.sub(_totalAssets()), token.balanceOf(msg.sender));
    }
    
    require(amount > 0, "deposit amount should be bigger than zero");

    uint256 shares = _issueSharesForAmount(msg.sender, amount);

    token.safeTransferFrom(msg.sender, address(this), amount);
    tokenBalance = tokenBalance.add(amount);

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
  ) public returns (uint256) {
    uint256 shares = maxShare;
    if (maxShare == 0) {
      shares = balanceOf(msg.sender);
    }
    if (recipient == address(0)) {
      recipient = msg.sender;
    }

    require(shares <= balanceOf(msg.sender), "share should be smaller than their own");
    
    uint256 value = _shareValue(shares);
    if (value > token.balanceOf(address(this))) {
      
      uint256 totalLoss = 0;
      
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

      require(totalLoss < maxLoss.mul(value.add(totalLoss)).div(MAX_BPS), "revert if totalLoss is more than permitted");
    }

    if (value > token.balanceOf(address(this))) {
      value = token.balanceOf(address(this));
      shares = _sharesForAmount(value);
    }
    
    _burn(msg.sender, shares);
    
    token.safeTransfer(recipient, value);
    tokenBalance = tokenBalance.sub(value);
    
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
  function addStrategy(address _strategy, uint256 _debtRatio, uint256 _rateLimit, uint256 _performanceFee) public {
    require(_strategy != address(0), "strategy address can't be zero");
    require(msg.sender == governance, "caller must be governance");
    require(_performanceFee <= MAX_BPS - performanceFee, "performance fee should be smaller than ...");

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
   *    Remove `strategy` from `withdrawalQueue`
   *    This may only be called by governance or management.
   * @param _strategy The Strategy to remove
   */
  function removeStrategyFromQueue(address _strategy) external {
    require(msg.sender == management || msg.sender == governance);
    
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
    debtRatio = debtRatio.sub(strategies[_strategy].debtRatio);
    strategies[_strategy].debtRatio = 0;
    emit StrategyRevoked(_strategy);
  }

  /**
   * @notice
   *    Provide an accurate expected value for the return this `strategy`
   * @param _strategy The Strategy to determine the expected return for. Defaults to caller.
   * @return
   *    The anticipated amount `strategy` should make on its investment since its last report.
   */
  function expectedReturn(address _strategy) external view returns (uint256) {
    _expectedReturn(_strategy);
  }

  function _expectedReturn(address _strategy) internal view returns (uint256) {
    uint256 delta = block.timestamp - strategies[_strategy].lastReport;
    if (delta > 0) {
      return strategies[_strategy].totalGain.mul(delta).div(block.timestamp - strategies[_strategy].activation);
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
      return _totalAssets() > 10 ** decimals() ? _totalAssets() : 10 ** decimals();
    } else {
      return _shareValue(10 ** decimals());
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

    uint256 _debtRatio = strategies[_strategy].debtRatio;
    strategies[_strategy].debtRatio = _debtRatio.sub(_min(loss.mul(MAX_BPS).div(_totalAssets()), _debtRatio));     // reduce debtRatio if loss happens

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
      token.transfer(msg.sender, credit.sub(totalAvailable));
      tokenBalance = tokenBalance.sub(credit.sub(totalAvailable));
    } else if (totalAvailable > credit) {
      token.transferFrom(msg.sender, address(this), totalAvailable.sub(credit));
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
      return Strategy(msg.sender).estimateTotalAssets();
    } else {
      return debt;
    }

  }

  function _min(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }

}
