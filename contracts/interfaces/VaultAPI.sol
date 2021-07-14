// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

interface VaultAPI is IERC20 {

  function apiVersion() external view returns (string memory);

  function withdraw(uint256 shares, address recipient) external;

  function token() external view returns (address);

  function strategies(address _strategy) external view returns (StrategyParams memory);

  function creditAvailable() external view returns (uint256);

  function debtOutstanding(address _strategy) external view returns (uint256);

  function expectedReturn() external view returns (uint256);

  function report(
    uint256 _gain,
    uint256 _loss,
    uint256 _debtPayment
  ) external returns (uint256);

  function revokeStrategy() external;

  function governance() external view returns (address);

}
