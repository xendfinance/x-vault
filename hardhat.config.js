require("@nomiclabs/hardhat-waffle");

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    version: "0.6.12",
    settings: {
      optimizer: {
        enabled: false,
        runs: 200,
      }
    }
  },
  networks: {
    hardhat: {
      forking: {
        url: `https://rpc.ankr.com/bsc`,
        blockNumber: 17286219,
      },
    },
    localhost: {
      url: 'http://localhost:8545',
    }
  },
  mocha: {
    timeout: 400000
  },
};
