// const XVault = artifacts.require("XVault");
// const Strategy = artifacts.require("Strategy");

const usdtAddress = '0x55d398326f99059ff775485246999027b3197955';
const vUsdtAddress = '0xfd5840cd36d94d7229439859c0112a4185bc0255';
const adminAddress = '0xefdca55e4bce6c1d535cb2d0687b5567eef2ae83';

// async function doDeploy(deployer) {
//   await deployer.deploy(XVault, usdtAddress, adminAddress, adminAddress);
//   xVaultContract = await XVault.deployed();
//   await deployer.deploy(Strategy, xVaultContract.address, vUsdtAddress);
// }

// module.exports = function (deployer) {
//   deployer.then(async () => {
//     await doDeploy(deployer);
//   });
// };

const XVault = artifacts.require("XVault");
const Strategy = artifacts.require("Strategy");
const secondsPerBlock = 3;

module.exports = function (deployer) {
    deployer.deploy(XVault, usdtAddress, adminAddress, adminAddress).then(function () {
      return deployer.deploy(Strategy, XVault.address, vUsdtAddress, secondsPerBlock)
    });
};
