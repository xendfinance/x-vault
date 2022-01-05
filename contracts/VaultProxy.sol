// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";

contract VaultProxy is TransparentUpgradeableProxy {
  constructor (address logic, address admin, bytes memory data) TransparentUpgradeableProxy(logic, admin, data) public {}
}