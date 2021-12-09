const { expectRevert, time } = require('@openzeppelin/test-helpers');
// const { assertion } = require('@openzeppelin/test-helpers/src/expectRevert');
const BN = require('bn.js');

const XVault = artifacts.require('XVault');
const Strategy = artifacts.require('StrategyUgoHawkVenusUSDTFarm');
const NewStrategy = artifacts.require('StrategyUgoHawkVenusUSDCFarm');
const VaultProxy = artifacts.require('VaultProxy');
const VaultProxyAdmin = artifacts.require('VaultProxyAdmin');
const USDT = require('./abi/USDT.json');
const ERC20 = require('./abi/ERC20.json');

contract('xVault', async([dev, minter, admin, alice, bob]) => {
  
  async function report(vaultInstance, strategyInstance) {
    const strategy = await vaultInstance.strategies(strategyInstance.address);
    const totalDebtRatio = await vaultInstance.debtRatio();
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
    console.log('totalDebt:', totalDebt.toString());
    console.log('emergency:', emergency);
    console.log('totalEstimatedAssets:', totalEstimatedAssets.toString());
    console.log('creditAvailable:', creditAvailable.toString());
    console.log('debtOutstanding:', debtOutstanding.toString());
    console.log('totalDebtRatio:', totalDebtRatio.toString());
    console.log('debtRatio:', debtRatio.toString());
    console.log('totalGain:', totalGain.toString());
    console.log('totalLoss:', totalLoss.toString());
    console.log('expectedReturn:', expectedReturn.toString());
    console.log('performanceFee:', performanceFee.toString());
    console.log('rateLimit:', rateLimit.toString());
    console.log('***');
  }

  // beforeEach(async () => {

  //   this.usdtContract = new web3.eth.Contract(USDT, '0x55d398326f99059ff775485246999027b3197955');
  //   this.vUSDTAddress = '0xfd5840cd36d94d7229439859c0112a4185bc0255';

  //   this.xVault = await XVault.new(this.usdtContract.options.address, dev, '0x143afc138978Ad681f7C7571858FAAA9D426CecE', {
  //     from: minter,
  //   });
  //   const vaultName = await this.xVault.symbol();
  //   console.log(vaultName);

  //   this.strategy = await Strategy.new(this.xVault.address, this.vUSDTAddress, '3', {
  //     from: minter
  //   });
    
  //   const usdtHolder = '0xefdca55e4bce6c1d535cb2d0687b5567eef2ae83';
  //   await this.usdtContract.methods.transfer(alice, "100000000000000000000000").send({
  //     from: usdtHolder
  //   });
  //   await this.usdtContract.methods.transfer(bob, "100000000000000000000000").send({
  //     from: usdtHolder
  //   });

  // });

  // When using proxy
  beforeEach(async () => {

    console.log('dev:', dev)
    console.log('minter:', minter)

    this.usdtContract = new web3.eth.Contract(USDT, '0x55d398326f99059ff775485246999027b3197955');
    this.vUSDTAddress = '0xfd5840cd36d94d7229439859c0112a4185bc0255';

    this.xVault = await XVault.new({
      from: minter,
    });

    this.newXVault = await XVault.new({
      from: minter,
    });

    this.proxyAdmin = await VaultProxyAdmin.new({
      from: minter
    })

    this.vaultProxy = await VaultProxy.new(this.xVault.address, this.proxyAdmin.address, "0x", {
      from: minter
    })

    this.vaultProxyInstance = await XVault.at(this.vaultProxy.address)
    
    await this.vaultProxyInstance.initialize(this.usdtContract.options.address, dev, '0x143afc138978Ad681f7C7571858FAAA9D426CecE', {
      from: minter
    })


    const vaultName = await this.vaultProxyInstance.symbol();
    console.log('vaultName:', vaultName);

    this.strategy = await Strategy.new(this.vaultProxyInstance.address, this.vUSDTAddress, '3', {
      from: minter
    });
    
    const usdtHolder = '0xefdca55e4bce6c1d535cb2d0687b5567eef2ae83';
    await this.usdtContract.methods.transfer(alice, "100000000000000000000000").send({
      from: usdtHolder
    });
    await this.usdtContract.methods.transfer(bob, "100000000000000000000000").send({
      from: usdtHolder
    });

  });

  // it("simple test", async () => {
  //   testContract = await TestContract.new({
  //     from: minter
  //   });
  //   const usdtHolder = '0xefdca55e4bce6c1d535cb2d0687b5567eef2ae83';
  //   console.log(testContract.address);
  //   this.usdtContract.methods.transfer(testContract.address, "100000000000000000000").send({
  //     from: usdtHolder
  //   });
  //   const tx = await testContract.loanLogic();
  //   // console.log(tx.logs);
  //   console.log('initial balance:', tx.logs[0].args.val.toString());
  //   console.log('collateral:', tx.logs[2].args.val.toString());
  //   console.log('last balance:',tx.logs[3].args.val.toString());
  //   console.log('success:',tx.logs[4].args.val.toString());
  // })

  // it("simple deposit and withdraw", async () => {
  //   const balanceOfVault = await this.xVault.balance();
  //   assert.equal(balanceOfVault.toString(), '0', 'the token balance of vault is not zero');

  //   this.usdtContract.methods.approve(this.xVault.address, 100).send({
  //     from: alice
  //   });
  //   await this.xVault.deposit(100, {
  //     from: alice
  //   });
  //   const balanceOfVaultAfterDeposit = await this.xVault.balance();
  //   assert.equal(balanceOfVaultAfterDeposit.toString(), '100', 'deposited tokens are missing');

  //   const balanceOfVaultToken = await this.xVault.balanceOf(alice);
    
  //   // withdraw tokens
  //   await this.xVault.withdraw(balanceOfVaultToken.toString(), alice, 1, {
  //     from: alice
  //   });
  //   const balanceOfVaultAfterWithdraw = await this.xVault.balance();
  //   assert.equal(balanceOfVaultAfterWithdraw.toString(), 0, 'should be zero');
    
  // });

  // it("add strategy, simple deposit and withdraw", async () => {
  //   await this.xVault.addStrategy(this.strategy.address, '50', '5', '5');

  //   this.usdtContract.methods.approve(this.xVault.address, 100000000000).send({
  //     from: alice
  //   });
  //   await this.xVault.deposit(100000000000, {
  //     from: alice
  //   });

  //   // const expectedReturn = await this.xVault.expectedReturn(this.strategy.address);

  //   // const blocks = await this.strategy.getblocksUntilLiquidation();
  //   // console.log('blocks:', blocks.toString());

  //   // await this.strategy.tend({
  //   //   from: minter
  //   // });

  //   // await this.strategy.harvest({
  //   //   from: minter
  //   // });
  //   const share = await this.xVault.balanceOf(alice);
  //   const tx = await this.xVault.withdraw(share.toString(), alice, 1, {
  //     from: alice
  //   });

  //   console.log(tx);

  //   // assert.equal(, 100000000000, 'harvested amount is smaller than deposited amount');
  // });

  // it("migrate strategy", async () => {
    
  //   const balanceBefore = await this.usdtContract.methods.balanceOf(alice).call();
  //   console.log('balanceBefore:', balanceBefore);

  //   await this.xVault.addStrategy(this.strategy.address, '10000', '50000000000000000', '0');
  //   // await report(this.xVault, this.strategy);
    
  //   const depositedAmount = '100000000000000000000';
    
  //   this.usdtContract.methods.approve(this.xVault.address, depositedAmount.toString()).send({
  //     from: alice
  //   });

  //   let apy = await this.xVault.getApy();
  //   console.log('apy:', apy.toString());

  //   await this.xVault.deposit(depositedAmount.toString(), {
  //     from: alice
  //   });
  //   console.log(`deposited ${depositedAmount} tokens`);

  //   await time.increase(time.duration.days(5));
  //   console.log('5 days passed')

  //   await this.strategy.harvest({
  //     from: minter
  //   });
  //   console.log('harvest called')
    

  //   this.newStrategy = await Strategy.new(this.xVault.address, this.vUSDTAddress, '4', {
  //     from: minter
  //   });
  //   console.log('new strategy deployed')

  //   await this.strategy.setForceMigrate(true, {
  //     from: dev
  //   })
  //   console.log('set force migration')

  //   await this.xVault.migrateStrategy(this.strategy.address, this.newStrategy.address, {
  //     from: dev
  //   })
  //   console.log('migration done')

  //   this.usdtContract.methods.approve(this.xVault.address, depositedAmount.toString()).send({
  //     from: bob
  //   });
  //   await this.xVault.deposit(depositedAmount.toString(), {
  //     from: bob
  //   });
  //   console.log(`deposited ${depositedAmount} tokens`);

  //   await time.increase(time.duration.days(5));
  //   console.log('5 days passed')

  //   await this.strategy.harvest({
  //     from: minter
  //   });
  //   console.log('harvest called')
    
    
  // });

  // it("add strategy, deposit and trigger tend, withdraw", async () => {
    
  //   const balanceBefore = await this.usdtContract.methods.balanceOf(alice).call();
  //   console.log('balanceBefore:', balanceBefore);

  //   await this.xVault.addStrategy(this.strategy.address, '10000', '50000000000000000', '0');
  //   // await report(this.xVault, this.strategy);
    
  //   const depositedAmount = '100000000000000000000';
    
  //   this.usdtContract.methods.approve(this.xVault.address, depositedAmount.toString()).send({
  //     from: alice
  //   });

  //   let apy = await this.xVault.getApy();
  //   console.log('apy:', apy.toString());

  //   await this.xVault.deposit(depositedAmount.toString(), {
  //     from: alice
  //   });

  //   await time.increase(time.duration.days(5));

  //   await this.strategy.harvest({
  //     from: minter
  //   });

  //   this.usdtContract.methods.approve(this.xVault.address, depositedAmount.toString()).send({
  //     from: bob
  //   });
  //   await this.xVault.deposit(depositedAmount.toString(), {
  //     from: bob
  //   });

  //   await time.increase(time.duration.days(5));
  //   await this.strategy.harvest({
  //     from: minter
  //   });
  //   await time.increase(time.duration.days(5));
  //   // await report(this.xVault, this.strategy);

  //   // for (i = 0; i < 10; i++) {
  //   //   await this.strategy.tend({
  //   //     from: minter
  //   //   });
  //   //   await time.increase(time.duration.days(1));
  //   // }

  //   await this.strategy.setFlashLoan(false, {
  //     from: minter
  //   })
  //   console.log('setFlashLoan to false')

  //   this.usdtContract.methods.approve(this.xVault.address, depositedAmount.toString()).send({
  //     from: bob
  //   });
  //   await this.xVault.deposit(depositedAmount.toString(), {
  //     from: bob
  //   });
    
  //   await this.strategy.harvest({
  //     from: minter
  //   });
    
  //   // await report(this.xVault, this.strategy);

  //   let share = await this.xVault.balanceOf(alice);
  //   await this.xVault.withdraw(share.toString(), alice, 1, {
  //     from: alice
  //   });

  //   apy = await this.xVault.getApy();
  //   console.log('apy:', apy.toString());

  //   const balanceAfter = await this.usdtContract.methods.balanceOf(alice).call();

  //   share = await this.xVault.balanceOf(alice);

  //   await report(this.xVault, this.strategy);

  //   await this.xVault.updateStrategyDebtRatio(this.strategy.address, 10000);
    
  // });

  it("add strategy, deposit and set collateral as zero, harvest", async () => {
    
    const balanceBefore = await this.usdtContract.methods.balanceOf(alice).call();
    console.log('balanceBefore:', balanceBefore);

    await this.vaultProxyInstance.addStrategy(this.strategy.address, '10000', '50000000000000000', '0', {
      from: dev
    });

    await this.vaultProxyInstance.setDepositLimit(balanceBefore.toString(), {
      from: dev
    });

    const max_bps = await this.vaultProxyInstance.MAX_BPS()
    console.log('max_bps:', max_bps.toString())
    
    // const depositedAmount = '100000000000000000000';
    const depositedAmount = web3.utils.toWei('100');
    
    this.usdtContract.methods.approve(this.vaultProxyInstance.address, web3.utils.toWei('1000000')).send({
      from: alice
    });

    await this.vaultProxyInstance.deposit(depositedAmount.toString(), {
      from: alice
    });

    const totalSupply = await this.vaultProxyInstance.totalSupply()
    console.log('totalSupply', totalSupply.toString())

    await time.increase(time.duration.days(5));

    // await this.strategy.setFlashLoan(false, {
    //   from: minter
    // })
    
    // await this.strategy.setCollateralTarget(0, {
    //   from: minter
    // })
    await this.strategy.setCollateralTarget(web3.utils.toWei('0.01'), {
      from: minter
    })

    await this.strategy.harvest({
      from: minter
    });

    await this.strategy.setFlashLoan(false, {
      from: minter
    })

    await this.vaultProxyInstance.deposit(depositedAmount.toString(), {
      from: alice
    });

    await time.increase(time.duration.days(5));

    await this.strategy.harvest({
      from: minter
    });

    await this.proxyAdmin.upgrade(this.vaultProxyInstance.address, this.newXVault.address, {
      from: minter
    })

    this.vToken = new web3.eth.Contract(ERC20, this.vUSDTAddress);
    const vTokenBalance = await this.vToken.methods.balanceOf(this.strategy.address).call();
    

    console.log('vTokenBalance:', vTokenBalance)

    const usdtBalance = await this.usdtContract.methods.balanceOf(this.strategy.address).call();
    console.log('usdtBalaanc:', usdtBalance)

  });


});
