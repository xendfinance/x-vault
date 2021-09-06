const HDWalletProvider = require('truffle-hdwallet-provider');
require('dotenv').config();

module.exports = {
  /**
   * Networks define how you connect to your ethereum client and let you set the
   * defaults web3 uses to send transactions. If you don't specify one truffle
   * will spin up a development blockchain for you on port 9545 when you
   * run `develop` or `test`. You can ask a truffle command to use a specific
   * network from the command line, e.g
   *
   * $ truffle test --network <network-name>
   */

  networks: {
    mainnet: {
      provider: () => new HDWalletProvider(process.env.PRIVATEKEY, `https://bsc-dataseed.binance.org/`),
      network_id: 56,
      confirmations: 2,      // # of confs to wait between deployments. (default: 0)
      timeoutBlocks: 10000,  // # of blocks before a deployment times out  (minimum/default: 50)
      gasPrice: 20000000000,
      skipDryRun: true       // Skip dry run before migrations? (default: false for public nets )
    },
    testnet: {
      provider: () => new HDWalletProvider(process.env.PRIVATEKEY, `https://data-seed-prebsc-1-s2.binance.org:8545/`),
      network_id: 97,
      confirmations: 5,       // # of confs to wait between deployments. (default: 0)
      gasPrice: 20000000000,
      timeoutBlocks: 200,  // # of blocks before a deployment times out  (minimum/default: 50)
      skipDryRun: true,       // Skip dry run before migrations? (default: false for public nets )
      networkCheckTimeout:999999
    },
    development: {
      host: '127.0.0.1',
      port: 8545,
      network_id: '*'
    }
  },
  plugins: [
    'truffle-plugin-verify',
    'solidity-coverage'
  ],
  api_keys: {
    bscscan: process.env.BSCSCAN_API_KEY
  },
  // Set default mocha options here, use special reporters etc.
  mocha: {
     timeout: 300000
  },

  // Configure your compilers
  compilers: {
    solc: {
      version: "0.6.12",    // Fetch exact version from solc-bin (default: truffle's version)
      settings: {          // See the solidity docs for advice about optimization and evmVersion
        optimizer: {
          enabled: true,
          runs: 200
       },
       evmVersion: "istanbul"
      }
    }
  }
};