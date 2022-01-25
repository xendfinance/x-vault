const { expectRevert, time } = require('@openzeppelin/test-helpers');
// const { assertion } = require('@openzeppelin/test-helpers/src/expectRevert');
const BN = require('bn.js');

const VaultProxyAdmin = artifacts.require('VaultProxyAdmin');
const XVault = artifacts.require('XVault');
const VaultProxy = artifacts.require('VaultProxy');
const Strategy = artifacts.require('Strategy');
const StrategyProxy = artifacts.require('StrategyProxy');
const StrategyAlpacaAutofarm = artifacts.require('StrategyAlpacaAutofarm');
const USDT = require('./abi/USDT.json');

contract('alpaca', async([guardian, governance, alice, bob]) => {
  
  async function report(vaultInstance, strategyInstance) {
    const strategy = await vaultInstance.strategies(strategyInstance.address);
    const activationDate = strategy.activation;
    const dateObj = new Date(parseInt(activationDate.toString()) * 1000);
    const lastReport = strategy.lastReport;
    const lastReportObj = new Date(parseInt(lastReport.toString()) * 1000);
    const debtRatio = strategy.debtRatio;
    const totalDebt = strategy.totalDebt;
    const totalGain = strategy.totalGain;
    const totalLoss = strategy.totalLoss;
    const performanceFee = strategy.performanceFee;
    const rateLimit = strategy.rateLimit;
    const emergency = await vaultInstance.emergencyShutdown();
    const totalEstimatedAssets = await strategyInstance.estimatedTotalAssets();
    const creditAvailable = await vaultInstance.creditAvailable(strategyInstance.address);
    const debtOutstanding = await vaultInstance.debtOutstanding(strategyInstance.address);
    const expectedReturn = await vaultInstance.expectedReturn(strategyInstance.address);

    console.log('-------------');
    console.log('activated:', dateObj.toISOString());
    console.log('lastReport:', lastReportObj.toISOString());
    console.log('totalDebt:', web3.utils.fromWei(totalDebt.toString()));
    console.log('emergency:', emergency);
    console.log('totalEstimatedAssets:', web3.utils.fromWei(totalEstimatedAssets.toString()));
    console.log('creditAvailable:', web3.utils.fromWei(creditAvailable.toString()));
    console.log('debtOutstanding:', web3.utils.fromWei(debtOutstanding.toString()));
    console.log('debtRatio:', debtRatio.toString());
    console.log('totalGain:', web3.utils.fromWei(totalGain.toString()));
    console.log('totalLoss:', web3.utils.fromWei(totalLoss.toString()));
    console.log('expectedReturn:', web3.utils.fromWei(expectedReturn.toString()));
    console.log('strategyPerformanceFee:', performanceFee.toString());
    console.log('rateLimit:', web3.utils.fromWei(rateLimit.toString()));
    console.log('***');
  }

  beforeEach(async () => {

    this.usdtContract = new web3.eth.Contract(USDT, '0x55d398326f99059ff775485246999027b3197955');


    this.proxyAdmin = await VaultProxyAdmin.new({from: guardian})

    this.xVault = await XVault.new({from: guardian})
    this.vaultProxy = await VaultProxy.new(this.xVault.address, this.proxyAdmin.address, "0x", {from: guardian})
    this.vaultInstance = await XVault.at(this.vaultProxy.address);
    await this.vaultInstance.initialize(this.usdtContract.options.address, governance, '0x143afc138978Ad681f7C7571858FAAA9D426CecE', {from: guardian})
    const vaultName = await this.xVault.symbol();
    console.log(vaultName);

    
    // this.strategy = await Strategy.new({from: guardian})
    // this.strategyProxy = await StrategyProxy.new(this.strategy.address, this.proxyAdmin.address, {from: guardian})
    // this.strategyInstance = await Strategy.at(this.strategyProxy.address)

    const path = [
      "0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F", "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56", "0x55d398326f99059ff775485246999027b3197955"
    ]
    this.alpacaStrategy = await StrategyAlpacaAutofarm.new({from: guardian})
    this.strategyProxy = await StrategyProxy.new(this.alpacaStrategy.address, this.proxyAdmin.address, "0x", {from: guardian})
    this.alpacaInstance = await StrategyAlpacaAutofarm.at(this.strategyProxy.address)
    await this.alpacaInstance.initialize(this.vaultInstance.address, '0x158Da805682BdC8ee32d52833aD41E74bb951E59', 16, path, {from: guardian})
    
    const usdtHolder = '0xefdca55e4bce6c1d535cb2d0687b5567eef2ae83';
    await this.usdtContract.methods.transfer(alice, "100000000000000000000000").send({
      from: usdtHolder
    });
    await this.usdtContract.methods.transfer(bob, "100000000000000000000000").send({
      from: usdtHolder
    });

  });


  it("add strategy, deposit and trigger tend, withdraw", async () => {
    
    const balanceBefore = await this.usdtContract.methods.balanceOf(alice).call();
    

    // await this.vaultInstance.addStrategy(this.strategyInstance.address, '50', web3.utils.toWei('0.05'), '0');
    await this.vaultInstance.addStrategy(this.alpacaInstance.address, '50', web3.utils.toWei('0.05'), '0', {from: governance});
    
    await report(this.vaultInstance, this.alpacaInstance);
    
    const depositedAmount = web3.utils.toWei('100000');
    
    this.usdtContract.methods.approve(this.vaultInstance.address, depositedAmount.toString()).send({
      from: alice
    });

    let apy = await this.vaultInstance.getApy();
    console.log('apy:', apy.toString());

    await this.vaultInstance.deposit(depositedAmount.toString(), {
      from: alice
    });

    await time.increase(time.duration.days(5));

    await this.alpacaInstance.harvest({
      from: governance
    });

    this.usdtContract.methods.approve(this.vaultInstance.address, depositedAmount.toString()).send({
      from: bob
    });
    await this.vaultInstance.deposit(depositedAmount.toString(), {
      from: bob
    });

    await time.increase(time.duration.days(5));
    await this.alpacaInstance.harvest({
      from: governance
    });
    await time.increase(time.duration.days(5));
    await report(this.vaultInstance, this.alpacaInstance);

    for (i = 0; i < 10; i++) {
      await this.alpacaInstance.tend({
        from: governance
      });
      await time.increase(time.duration.days(1));
    }

    await this.alpacaInstance.harvest({
      from: governance
    });
    
    // await report(this.vaultInstance, this.strategy);

    let share = await this.vaultInstance.balanceOf(alice);
    await this.vaultInstance.withdraw(share.toString(), alice, 1, {
      from: alice
    });

    apy = await this.vaultInstance.getApy();
    console.log('apy:', apy.toString());

    const balanceAfter = await this.usdtContract.methods.balanceOf(alice).call();
    console.log('balanceBefore:', web3.utils.fromWei(balanceBefore));
    console.log('balanceAfter: ', web3.utils.fromWei(balanceAfter))

    share = await this.vaultInstance.balanceOf(alice);
    console.log('alice xtoken balance:', share.toString())

    await report(this.vaultInstance, this.alpacaInstance);

    const fee = await this.vaultInstance.performanceFee();
    console.log('vault fee:', fee.toString());
    const totalSupply = await this.vaultInstance.totalSupply();
    console.log('vault total supply:', web3.utils.fromWei(totalSupply.toString()));

    const feeAmount = await this.vaultInstance.balanceOf('0x143afc138978Ad681f7C7571858FAAA9D426CecE');
    console.log('fee Amount:', web3.utils.fromWei(feeAmount.toString()))
    
  });


});
