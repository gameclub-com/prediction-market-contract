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
    }
  }
};

export default config;
