import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import '@openzeppelin/hardhat-upgrades';
import '@nomicfoundation/hardhat-chai-matchers';

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.24',
    settings: {
      evmVersion: "cancun",
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      }
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    localhost: {
      url: 'http://127.0.0.1:8545',
      chainId: 31337,
    }
  }
};

export default config;
