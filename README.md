# Documentation

![vault diagram](https://github.com/xendfinance/x-vault/blob/main/public/images/diagram.jpg)

This is a vault system that leverages the USDT token to get high yield.

User deposits tokens to the vault. The vault deposits or withdraws tokens to the strategy contract based on current assets and position of strategy.

Now the system consists of mainly 2 parts: vault token(share token) and strategy.

- Vault

Vault Token (e.g. xvUSDT)  is a share token that proves your contribution to the liquidity.

The Vault contract manages the funds user deposited

The deposited assets are in the vault and when signaled, they are deposited to the strategy.

Vault has several functions that report the strategy status like position and get available assets and predict assets.

- Strategy

Whenever funds are deposited to the strategy contract from the vault, it lends assets (USDT) it borrowed  from the cream finance through flash loan then deposited  assets (USDT) from the vault are both deposited together to the venus protocol.

It then borrows assets from venus protocol to repay  cream finance.

After that, adjusting position function is called regularly by the keeper to optimize the high yield.

On the other hand, while lending assets to the venus protocol, venus gives XVS token as a reward so we claim XVS tokens and swap to USDT and deposit to the venus when adjusting position.

When funds are withdrawn, strategy borrows assets from cream finance using flash loan to repay to the venus protocol and withdraw needed funds from the venus protocol.

Then, strategy returns the assets to the vault.

## Deployed Contracts

Visit [Xend Finance Docs](https://docs.xend.finance/contracts/registry) to see deployed smart contract addresses