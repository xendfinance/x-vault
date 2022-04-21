// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./BaseStrategy.sol";
import "../interfaces/alpaca/IAlpacaVault.sol";
import "../interfaces/alpaca/IProxyWalletRegistry.sol";
import "../interfaces/alpaca/IAlpacaFarm.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";

contract StrategyAlpha {
  address want = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
  IProxyWalletRegistry public constant proxyWalletRegistry = IProxyWalletRegistry(0x13e3Bc3c6A96aE3beaDD1B08531Fde979Dd30aEa);
  IProxyWallet proxy;

  address public proxyActions = 0x1391FB5efc2394f33930A0CfFb9d407aBdbf1481;
  address vault = 0x7C9e73d4C71dae564d41F78d56439bB4ba87592f;
  address positionManager = 0xABA0b03eaA3684EB84b51984add918290B41Ee19;
  address stabilityFeeCollector = 0x45040e48C00b52D9C0bd11b8F577f188991129e6;
  address tokenAdapter = 0x4f56a92cA885bE50E705006876261e839b080E36;
  address stablecoinAdapter = 0xD409DA25D32473EFB0A1714Ab3D0a6763bCe4749;
  bytes32 collateralPoolId = 0x6962425553440000000000000000000000000000000000000000000000000000;

  constructor () public {
    proxy = IProxyWallet(proxyWalletRegistry.build());
    IERC20(want).approve(address(proxy), uint256(-1));
    IERC20(vault).approve(address(proxy), uint256(-1));
  }
  
  function openInvestBusd() external {
    

    // invest busd and lend ausd
    uint256 amount = 800 ether;
    uint256 borrowAmount = 500 ether;
    bytes memory _data = abi.encodeWithSignature(
      "convertOpenLockTokenAndDraw(address,address,address,address,address,bytes32,uint256,uint256,bytes)", 
      vault, 
      positionManager,
      stabilityFeeCollector,
      tokenAdapter,
      stablecoinAdapter,
      collateralPoolId,
      amount,
      borrowAmount,
      abi.encode(address(this))
    );
    proxy.execute(proxyActions, _data);

  }

  function withdrawIbusd() external {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxy));

    // withdraw ibusd
    uint256 withdrawAmount = 50 ether;
    bytes memory _data = abi.encodeWithSignature(
      "unlockToken(address,address,uint256,uint256,bytes)", 
      positionManager,
      tokenAdapter,
      positionId,
      withdrawAmount,
      abi.encode(address(this))
    );

    proxy.execute(proxyActions, _data);
  }

  function investIbusd() external {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxy));
    uint256 amount = 10 ether;

    bytes memory _data = abi.encodeWithSignature(
      "lockToken(address,address,uint256,uint256,bool,bytes)",
      positionManager,
      tokenAdapter,
      positionId,
      amount,
      true,
      abi.encode(address(this))
    );

    proxy.execute(proxyActions, _data);
  }

  function investIbusdAndLendAusd() external {
    uint256 positionId = IPositionManager(positionManager).ownerFirstPositionId(address(proxy));
    uint256 _collateralAmount = 10 ether;
    uint256 _stablecoinAmount = 10 ether;

    bytes memory _data = abi.encodeWithSignature(
      "lockTokenAndDraw(address,address,address,address,uint256,uint256,uint256,bool,bytes)",
      positionManager,
      stabilityFeeCollector,
      tokenAdapter,
      stablecoinAdapter,
      positionId,
      _collateralAmount,
      _stablecoinAmount,
      true,
      abi.encode(address(this))
    );

    proxy.execute(proxyActions, _data);
  }
}