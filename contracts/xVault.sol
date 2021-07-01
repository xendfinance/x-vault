// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

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
  
  uint256 public depositLimit;
  uint256 public debtRatio;
  uint256 public totalDebt;
  uint256 public lastReport;
  uint256 public activation;

  address public treasury;    // reward contract where governance fees are sent to
  uint256 public managementFee;
  uint256 public performanceFee;

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

  function deposit(uint256 _amount, address reciever) public returns (uint256) {
    uint256 amount = min(depositLimit - _totalAssets(), token.balanceOf(msg.sender));
    require(amount > 0, "deposit amount should be bigger than zero");

    uint256 _pool = balance();
    uint256 _before = token.balanceOf(address(this));
    token.safeTransferFrom(msg.sender, address(this), _amount);
    uint256 _after = token.balanceOf(address(this));
    _amount = _after.sub(_before);
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = _amount;
    } else {
      shares = (_amount.mul(totalSupply())).div(_pool);
    }
    _mint(msg.sender, shares);
  }

  function harvest(address reserve, uint256 amount) external {
    require(msg.sender == governance, "!governance");
    require(reserve != address(token), "token");
    ERC20(reserve).safeTransfer(governance, amount);
  }

  function withdraw(uint256 _shares) public {
    uint256 r = (balance().mul(_shares)).div(totalSupply());
    _burn(msg.sender, _shares);

    uint256 b = token.balanceOf(address(this));
    
    token.safeTransfer(msg.sender, r);
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

    emit StrategyAdded(_strategy, _debtRatio, _rateLimit, _performanceFee);

  }

  function revokeStrategy(address _strategy) public {
    require(msg.sender == strategy || msg.sender == governance || msg.sender == guardian, "should be one of 3 admins");
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

}
