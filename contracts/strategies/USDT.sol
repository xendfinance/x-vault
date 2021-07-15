// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./BaseStrategy.sol";
import "../interfaces/venus/VBep20I.sol";


contract Strategy is BaseStrategy {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  constructor(address _vault, address _vToken) public BaseStrategy(_vault) {
    vToken = VBep20I(_vToken);
  }

}