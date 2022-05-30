# Documentation

This strategy consists of three protocols: Alpaca AUSD protocol, Ellipsis Liquidity protocol and Pancakeswap.

Here’s a diagram of how it works.

![strategy diagram](https://github.com/xendfinance/x-vault/blob/alpaca-eps-strategy/public/images/diagram.PNG)

When harvest action called, the strategy contract pulls the available fund from the vault and lends it to alpaca lending protocol and borrows AUSD assets collateralized by lent assets.

Borrowed AUSD debt is deposited to ellipsis AUSD3EPS liquidity to issue ausd3eps LP token.

And stake that ausd3eps LP token to alpaca farm.

Since Alpaca Farm and Lending Protocol generates ALPACA reward until next harvest action so claims those rewards and swap to BUSD and add to depositing fund.

Every harvest action checks the increased AUSD debt size and staked AUSD size and adjusts them keep the same amount to be able to repay debt easily.

## Deployed Contracts

Visit [Xend Finance Docs](https://docs.xend.finance/contracts/registry) to see deployed smart contract addresses
