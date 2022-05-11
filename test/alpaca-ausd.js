const { expect } = require("chai");

async function impersonateAccount(acc) {
  await hre.network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [acc],
  });
  return await ethers.getSigner(acc);
}

describe("alpha", function() {
  before(async function() {
    const StrategyAlpha = await ethers.getContractFactory('StrategyAlpha')
    this.strategyAlpha = await StrategyAlpha.deploy()

    const want = await ethers.getContractAt("IERC20", '0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56');
    // const wantHolder = ;
    const wantHolder = await impersonateAccount('0xF977814e90dA44bFA03b6295A0616a897441aceC');

    await want.connect(wantHolder).transfer(this.strategyAlpha.address, "100000000000000000000000");
  })

  it("call", async function() {
    await this.strategyAlpha.execute();
  })
})

// const { expectRevert, time } = require('@openzeppelin/test-helpers');
// // const { assertion } = require('@openzeppelin/test-helpers/src/expectRevert');
// const BN = require('bn.js');

// const StrategyAlpha = artifacts.require('StrategyAlpha');
// const ERC20 = require('./abi/ERC20.json');

// contract('xVault', async([dev, minter, admin, alice, bob]) => {
  
//   beforeEach(async () => {

//     this.wantContract = new web3.eth.Contract(ERC20, '0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56');

//     this.strategyAlpha = await StrategyAlpha.new({from: minter});
    
//     const wantHolder = '0xF977814e90dA44bFA03b6295A0616a897441aceC';
//     await this.wantContract.methods.transfer(this.strategyAlpha.address, "100000000000000000000000").send({
//       from: wantHolder
//     });

//   });

//   it("harvest", async () => {
//     await this.strategyAlpha.execute({from: dev});
//     // await this.strategyAlpha.openInvestBusd({ from: dev });
//     // await this.strategyAlpha.withdrawIbusd({ from: dev });
//     // await this.strategyAlpha.investIbusd({ from: dev });
//     // await this.strategyAlpha.investIbusdAndLendAusd({ from: dev });
//   });


// });
