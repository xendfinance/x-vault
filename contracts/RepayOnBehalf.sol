// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/flashloan/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/venus/VBep20I.sol";
import "./interfaces/VaultAPI.sol";

interface IStrategy {
  function want() external view returns (address);
  function vault() external view returns (address);
  function estimatedTotalAssets() external view returns (uint256);
  function withdraw(uint256 _amount) external returns (uint256, uint256);
  function withdrawToRepay(uint256 amount) external;
  function migrate(address _newStrategy) external;
  function getLivePosition() external returns (uint256 deposits, uint256 borrows);
}

interface IVault {
  function setGovernance(address _governance) external;
  function migrateStrategy(address oldVersion, address newVersion) external;
}

contract RepayOnBehalf is Ownable, IERC3156FlashBorrower {
  using SafeERC20 for IERC20;
  
  IStrategy strategy;
  address public crWant = address(0xD83C88DB3A6cA4a32FFf1603b0f7DDce01F5f727);
  address public want;
  VBep20I public vToken;
  address public vault;
  address public newStrategy;

  constructor (address _strategy, address _vToken, address _newStrategy) public {
    strategy = IStrategy(_strategy);
    want = IStrategy(_strategy).want();
    vault = IStrategy(_strategy).vault();
    vToken = VBep20I(_vToken);
    newStrategy = _newStrategy;
  }

  function start() external onlyOwner {
    (, uint256 borrows) = strategy.getLivePosition();
    doFlashLoan(true, borrows);
  }

  function doFlashLoan(bool deficit, uint256 amountDesired) internal returns (uint256) {
    if (amountDesired == 0) {
      return 0;
    }

    uint256 amount = amountDesired;
    bytes memory data = abi.encode(deficit, amount);

    ICTokenFlashloan(crWant).flashLoan(address(this), address(want), amount, data);

    return amount;
    
  }

  function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata params) override external returns (bytes32) {
    require(initiator == address(this), "caller is not this contract");
    require(msg.sender == crWant, "Not Flash Loan Provider");
    (, uint256 borrowAmount) = abi.decode(params, (bool, uint256));
    require(amount == borrowAmount, "insuffient amount");

    repayOnBehalf(amount + fee);
    IERC20(token).approve(msg.sender, amount + fee);
    return keccak256("ERC3156FlashBorrowerInterface.onFlashLoan");
    
  }

  function repayOnBehalf(uint256 withdrawAmount) internal {
    IERC20(want).safeApprove(address(vToken), uint256(-1));
    vToken.repayBorrowBehalf(address(strategy), uint256(-1));
    IVault(vault).migrateStrategy(address(strategy), newStrategy);
    IStrategy(newStrategy).withdrawToRepay(withdrawAmount);
  }

  function setGovernance(address _governance) external onlyOwner {
    IVault(vault).setGovernance(_governance);
  }

}
