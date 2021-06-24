// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract xvUSDT is ERC20 {
  using SafeERC20 for ERC20;
  using Address for address;
  using SafeMath for uint256;
  
  address public guardian;
  address public governance;
  ERC20 public token;

  uint256 public min = 9500;
  uint256 public constant max = 10000;

  constructor(
    address _token,
    address _governance,
    address _rewards,
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
    _setupDecimals(ERC20(_token).decimals());
  }

  function balance() public view returns (uint256) {
    return token.balanceOf(address(this));
  }

  function setMin(uint256 _min) external {
    require(msg.sender == governance, "!governance");
    min = _min;
  }

  function setGovernance(address _governance) public {
    require(msg.sender == governance, "!governance");
    governance = _governance;
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
    deposit(token.balanceOf(msg.sender));
  }

  function deposit(uint256 _amount) public {
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


}
