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
        runs: 1000,
      }
    }
  },
  networks: {
    hardhat: {
      forking: {
        url: `https://bsc.getblock.io/mainnet/?api_key=${process.env.GETBLOCK_API_KEY}`
      }
    }
  }
};
