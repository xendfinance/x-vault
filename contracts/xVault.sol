// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

interface GuestList {
  function authorized(address guest, uint256 amount) public returns (bool);
}

interface Strategy {
  function want() public view returns (address);
  function vault() public view returns (address);
  function estimateTotalAssets() public view returns (uint256);
  function withdraw(uint256 _amount) public returns (uint256);
  function migrate(address _newStrategy) public;
}

contract xvUSDT is ERC20 {
  using SafeERC20 for ERC20;
  using Address for address;
  using SafeMath for uint256;
  
  address public guardian;
  address public governance;
  address public management;
  ERC20 public token;

  GuestList guestList;

  struct StrategyParams {
    uint256 performanceFee;
    uint256 activation;
    uint256 debtRatio;
    uint256 rateLimit;
    uint256 lastReport;
    uint256 totalDebt;
    uint256 totalGain;
    uint256 totalLoss;
  }

  uint256 public min = 9500;
  uint256 public constant max = 10000;
  uint256 public MAX_BPS = 100;

  mapping (address => StrategyParams) public strategies;
  uint256 MAXIMUM_STRATEGIES = 20;
  address[] public withdrawalQueue;

  bool public emergencyShutdown;
  
  uint256 public depositLimit;  // Limit of totalAssets the vault can hold
  uint256 public debtRatio;
  uint256 public totalDebt;   // Amount of tokens that all strategies have borrowed
  uint256 public lastReport;  // block.timestamp of last report
  uint256 public activation;  // block.timestamp of contract deployment

  address public treasury;    // reward contract where governance fees are sent to
  uint256 public managementFee;
  uint256 public performanceFee;

  event UpdateTreasury(address treasury);
  event UpdateGuardian(address guardian);
  event UpdateGuestList(address guestList);
  event UpdateDepositLimit(uint256 depositLimit);
  event UpdatePerformanceFee(uint256 fee);
  event StrategyRemovedFromQueue(address strategy);
  event UpdateManangementFee(uint256 fee);
  event EmergencyShutdown(bool active);

  constructor(
    address _token,
    address _governance,
    address _treasury,
    string memory _nameOverride,
    string memory _symbolOverride
  ) 
  public ERC20(
    string(abi.encodePacked("xend ", ERC20(_token).name())),
    string(abi.encodePacked("xv", ERC20(_token).name()))
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

  function setName(string memory _name) external {
    require(msg.sender == governance, "!governance");
    name = _name;
  }

  function setSymbol(string memory _symbol) external {
    require(msg.sender == governance, "!governance");
    symbol = _symbol;
  }

  function setTreasury(address _treasury) external {
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

  function setMin(uint256 _min) external {
    require(msg.sender == governance, "!governance");
    min = _min;
  }

  function setGovernance(address _governance) external {
    require(msg.sender == governance, "!governance");
    governance = _governance;
  }

  function setGuestList(address _guestList) external {
    require(msg.sender == governance, "!governance");
    guestList = GuestList(_guestList);
    emit UpdateGuestList(guestList);
  }

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

    if (active) {
      require(msg.sender == guardian || msg.sender == governance, "caller must be guardian or governance");
    } else {
      require(msg.sender == governance, "caller must be governance");
    }
    emergencyShutdown = active;
    emit EmergencyShutdown(active);
  }

  

  function available() public view returns (uint256) {
    return token.balanceOf(address(this)).mul(min).div(max);
  }

  function earn() public {
    uint256 _bal = available();
    token.safeTransfer(governance, _bal);
    
    // call external function
  }

  function depositAll() external {
    deposit(token.balanceOf(msg.sender), msg.sender);
  }

  function _issueSharesForAmount(address to, uint256 amount) internal returns (uint256) {
    uint256 shares = 0;
    if (totalSupply() > 0) {
      shares = amount * totalSupply() / _totalAssets();
    } else {
      shares = amount;
    }

    _mint(to, shares);
    emit Transfer(address(0), to, shares);
  }

  function deposit(uint256 _amount) public returns (uint256) {
    require(emergencyShutdown != true, "in status of Emergency Shutdown");
    uint256 amount = min(depositLimit - _totalAssets(), token.balanceOf(msg.sender));
    
    require(amount > 0, "deposit amount should be bigger than zero");

    uint256 shares = _issueSharesForAmount(msg.sender, amount);

    token.safeTransferFrom(msg.sender, address(this), _amount);
    
    return shares;
  }

  function harvest(address reserve, uint256 amount) external {
    require(msg.sender == governance, "!governance");
    require(reserve != address(token), "token");
    ERC20(reserve).safeTransfer(governance, amount);
  }

  function _totalAssets() internal view returns (uint256) {
    return token.balanceOf(address(this)) + totalDebt;
  }

  function _shareValue(uint256 _share) internal view returns (uint256) {
    // Determine the current value of `shares`
    return (_share * _totalAssets()) / totalSupply();
  }

  function _sharesForAmount(uint256 amount) internal view returns (uint256) {
    // Determine how many shares `amount` of token would receive
    if (_totalAssets() > 0) {
      return amount.mul(totalSupply()).div(_totalAssets());
    } else {
      return 0;
    }
  }

  function withdraw(
    uint256 maxShare,
    address recipient,
    uint256 maxLoss     // if 1, 0.01%
  ) public returns (uint256) {
    uint256 shares = maxShare;
    if (maxShare == 0) {
      shares = balanceOf[msg.sender];
    }
    require(shares <= balanceOf[msg.sender], "share should be smaller than their own");
    
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

        uint256 amountNeeded = value - token.balanceOf(address(this));    // recalculate the needed token amount to withdraw
        amountNeeded = min(amountNeeded, strategies[strategy].totalDebt);
        if (amountNeeded == 0)
          continue;
        
        uint256 before = token.balanceOf(address(this));
        uint256 loss = Strategy(strategy).withdraw(amountNeeded);
        uint256 withdrawn = token.balanceOf(address(this)) - before;

        if (loss > 0) {
          value = value.sub(loss);
          totalLoss = totalLoss.add(loss);
          strategies[strategy].totalLoss = strategies[strategy].totalLoss.add(loss);
        }
        strategies[strategy].totalDebt = strategies[strategy].sub(withdrawn.add(loss));
        totalDebt = totalDebt.sub(withdrawn.add(loss));
      }

      require(totalLoss < maxLoss.mul(value.add(totalLoss)).div(MAX_BPS), "revert if totalLoss is more than permitted");
    }

    if (value > token.balanceOf(address(this))) {
      value = token.balanceOf(address(this));
      shares = _sharesForAmount(value);
    }
    
    _burn(msg.sender, shares);

    emit Transfer(msg.sender, address(0), shares);

    uint256 b = token.balanceOf(address(this));
    
    token.safeTransfer(recipient, value);
    
    return value;
  }

  function addStrategy(address _strategy, uint256 _debtRatio, uint256 _rateLimit, uint256 _performanceFee) public {
    require(_strategy != address(0), "strategy address can't be zero");
    require(msg.sender == governance, "caller must be governance");
    require(performanceFee <= MAX_BPS, "performance fee should be smaller than ...");

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

    require(withdrawalQueue[MAXIMUM_STRATEGIES - 1] == address(0));
    withdrawalQueue[MAXIMUM_STRATEGIES - 1] = _strategy;
    _organizeWithdrawalQueue();

  }

  function removeStrategyFromQueue(address strategy) external {
    require(msg.sender == management || msg.sender == governance);
    
    for (uint i = 0; i < MAXIMUM_STRATEGIES; i++) {
      
      if (withdrawalQueue[i] == strategy) {
        withdrawalQueue[i] = address(0);
        _organizeWithdrawalQueue();
        emit StrategyRemovedFromQueue(strategy);
      }
    
    }
  }

  function revokeStrategy(address _strategy) public {
    require(msg.sender == _strategy || msg.sender == governance || msg.sender == guardian, "should be one of 3 admins");
    _revokeStrategy(_strategy);
  }

  function _revokeStrategy(address _strategy) internal {
    strategies[_strategy].debtRatio = 0;
    emit StrategyRevoked(strategy);
  }

  function expectedReturn(address _strategy) external returns (uint256) {
    _expectedReturn(_strategy);
  }

  function _expectedReturn(address _strategy) internal returns (uint256) {
    uint256 delta = block.timestamp - strategies[_strategy].lastReport;
    if (delta > 0) {
      return strategies[_strategy].totalGain.mul(delta).div(block.timestamp - strategies[_strategy].activation);
    } else {
      return 0;
    }
  }

  function _organizeWithdrawalQueue() internal {
    /* 
      Reorganize `withdrawalQueue` to replace empty value by the later value if there is empty value between 
      two actual value
    */
    uint256 offset = 0;
    for (uint i = 0; i < MAXIMUM_STRATEGIES; i++) {
      address strategy = withdrawalQueue[i];

      if (strategy == address(0)) {
        offset = offset + 1;
      } else if (offset > 0) {
        withdrawalQueue[i - offset] = strategy;
        withdrawalQueue[i] = address(0);
      }
    }
  }

  function pricePerShare() external view returns (uint256) {
    if (totalSupply() == 0) {
      return 10 ** decimals();      // price of 1:1
    } else {
      return _shareValue(10 ** decimals());
    }
  }

}
