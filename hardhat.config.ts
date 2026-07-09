import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import '@openzeppelin/hardhat-upgrades';
import '@nomicfoundation/hardhat-chai-matchers';

const config: HardhatUserConfig = {
  solidity: {
    compilers: [{
      version: '0.8.24',
      settings: {
        evmVersion: "cancun",
        viaIR: true,
        optimizer: {
          enabled: true,
          runs: 200,
        },
      },
    }],
    overrides: {
      'contracts/ExchangeCLOB.sol': {
        version: '0.8.24',
        settings: {
          evmVersion: "cancun",
          viaIR: true,
          optimizer: { enabled: true, runs: 1 },
        },
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
      allowUnlimitedContractSize: true,
    },
    localhost: {
      url: 'http://127.0.0.1:8545',
      chainId: 31337,
    },
    // BNB Smart Chain (BSC) — production deployment target
    bscMainnet: {
      url: process.env.BSC_RPC_URL || 'https://bsc-dataseed.bnbchain.org',
      chainId: 56,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
    // BNB Smart Chain Testnet — staging
    bscTestnet: {
      url: process.env.BSC_TESTNET_RPC_URL || 'https://data-seed-prebsc-1-s1.bnbchain.org:8545',
      chainId: 97,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
  }
};

export default config;
