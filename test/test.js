const { expect } = require("chai");

async function impersonateAccount(acc) {
  await hre.network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [acc],
  });
  return await ethers.getSigner(acc);
}

describe("basic test", function() {
  before(async function() {
    const [owner, addr1] = await ethers.getSigners();

    const XVault = await ethers.getContractFactory('XVault')
    const VaultProxyAdmin = await ethers.getContractFactory('VaultProxyAdmin')
    const VaultProxy = await ethers.getContractFactory('VaultProxy')

    this.xVaultContract = await XVault.deploy()
    this.proxyAdminContract = await VaultProxyAdmin.deploy()
    this.vaultProxyContract = await VaultProxy.deploy(this.xVaultContract.address, this.proxyAdminContract.address, "0x")
    this.vaultInstance = await ethers.getContractAt('XVault', this.vaultProxyContract.address)
    
    const wantContract = await ethers.getContractAt("IERC20", '0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56');
    await this.vaultInstance.initialize(wantContract.address, owner.address, '0x143afc138978Ad681f7C7571858FAAA9D426CecE')

    const StrategyAlpacaAUSDEPSFarm = await ethers.getContractFactory('StrategyAlpacaAUSDEPSFarm')
    const StrategyProxy = await ethers.getContractFactory('StrategyProxy')
    this.strategyContract = await StrategyAlpacaAUSDEPSFarm.deploy()
    this.strategyProxyContract = await StrategyProxy.deploy(this.strategyContract.address, this.proxyAdminContract.address, "0x")
    this.strategyInstance = await ethers.getContractAt('StrategyAlpacaAUSDEPSFarm', this.strategyProxyContract.address)
    console.log(this.strategyInstance)
    const path = [
      "0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F", "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56"
    ]
    await this.strategyInstance.initialize(this.vaultInstance.address, '0x7C9e73d4C71dae564d41F78d56439bB4ba87592f', path)

    
    const wantHolder = await impersonateAccount('0xF977814e90dA44bFA03b6295A0616a897441aceC');

    await wantContract.connect(wantHolder).transfer(this.strategyAlpha.address, "100000000000000000000000");
  })

  it("call", async function() {
    console.log('success')
    // await this.strategyAlpha.execute();
  })
})
