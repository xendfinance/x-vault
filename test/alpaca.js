const { expectRevert, time } = require('@openzeppelin/test-helpers');
// const { assertion } = require('@openzeppelin/test-helpers/src/expectRevert');
const BN = require('bn.js');

const XVault = artifacts.require('XVault');
const Strategy = artifacts.require('Strategy');
const StrategyAlpacaAutofarm = artifacts.require('StrategyAlpacaAutofarm');
const USDT = require('./abi/USDT.json');

contract('alpaca', async([dev, minter, admin, alice, bob]) => {
  
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
    this.vUSDTAddress = '0xfd5840cd36d94d7229439859c0112a4185bc0255';

    this.xVault = await XVault.new(this.usdtContract.options.address, dev, '0x143afc138978Ad681f7C7571858FAAA9D426CecE', {
      from: minter,
    });
    const vaultName = await this.xVault.symbol();
    console.log(vaultName);

    this.strategy = await Strategy.new(this.xVault.address, this.vUSDTAddress, 3, {
      from: minter
    });

    this.alpacaStrategy = await StrategyAlpacaAutofarm.new(this.xVault.address, '0x158Da805682BdC8ee32d52833aD41E74bb951E59', 16, {
      from: minter
    })
    
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
    

    await this.xVault.addStrategy(this.strategy.address, '50', web3.utils.toWei('0.05'), '0');
    await this.xVault.addStrategy(this.alpacaStrategy.address, '50', web3.utils.toWei('0.05'), '0');
    
    await report(this.xVault, this.alpacaStrategy);
    
    const depositedAmount = web3.utils.toWei('100000');
    
    this.usdtContract.methods.approve(this.xVault.address, depositedAmount.toString()).send({
      from: alice
    });

    let apy = await this.xVault.getApy();
    console.log('apy:', apy.toString());

    await this.xVault.deposit(depositedAmount.toString(), {
      from: alice
    });

    await time.increase(time.duration.days(5));

    await this.alpacaStrategy.harvest({
      from: minter
    });

    this.usdtContract.methods.approve(this.xVault.address, depositedAmount.toString()).send({
      from: bob
    });
    await this.xVault.deposit(depositedAmount.toString(), {
      from: bob
    });

    await time.increase(time.duration.days(5));
    await this.alpacaStrategy.harvest({
      from: minter
    });
    await time.increase(time.duration.days(5));
    await report(this.xVault, this.alpacaStrategy);

    for (i = 0; i < 10; i++) {
      await this.alpacaStrategy.tend({
        from: minter
      });
      await time.increase(time.duration.days(1));
    }

    await this.alpacaStrategy.harvest({
      from: minter
    });
    
    // await report(this.xVault, this.strategy);

    let share = await this.xVault.balanceOf(alice);
    await this.xVault.withdraw(share.toString(), alice, 1, {
      from: alice
    });

    apy = await this.xVault.getApy();
    console.log('apy:', apy.toString());

    const balanceAfter = await this.usdtContract.methods.balanceOf(alice).call();
    console.log('balanceBefore:', web3.utils.fromWei(balanceBefore));
    console.log('balanceAfter: ', web3.utils.fromWei(balanceAfter))

    share = await this.xVault.balanceOf(alice);
    console.log('alice xtoken balance:', share.toString())

    await report(this.xVault, this.alpacaStrategy);

    const fee = await this.xVault.performanceFee();
    console.log('vault fee:', fee.toString());
    const totalSupply = await this.xVault.totalSupply();
    console.log('vault total supply:', web3.utils.fromWei(totalSupply.toString()));

    const feeAmount = await this.xVault.balanceOf('0x143afc138978Ad681f7C7571858FAAA9D426CecE');
    console.log('fee Amount:', web3.utils.fromWei(feeAmount.toString()))
    
  });


});
