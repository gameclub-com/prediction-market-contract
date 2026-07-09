# GameClub Contracts

Smart contracts for **GameClub**, a Polymarket-style prediction market built on **BNB Smart Chain (BSC)** — conditional outcome tokens, a central limit order book (CLOB) exchange, and oracle-based market resolution.

This repository contains the on-chain contracts of the GameClub platform. All core contracts are live on **BNB Smart Chain Mainnet (Chain ID: 56)** and use the canonical BSC USDT as collateral.

## Technology Stack

- **Blockchain**: BNB Smart Chain (BSC) — EVM-compatible
- **Smart Contracts**: Solidity 0.8.24 (Cancun EVM, viaIR)
- **Upgradeability**: UUPS proxies (OpenZeppelin), upgrades gated by a TimelockController
- **Development**: Hardhat, OpenZeppelin Contracts / Contracts-Upgradeable v5

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56) — production deployment
- **BNB Smart Chain Testnet** (Chain ID: 97) — staging
- Hardhat local network (Chain ID: 31337) — development and tests

## Contract Addresses (BNB Smart Chain Mainnet)

Interact with the **proxy** addresses; implementation addresses are listed for verification.

| Contract | Proxy (use this address) | Implementation |
|----------|--------------------------|----------------|
| ConditionalTokens | `0xE6D3a683bEB3fB92A4F2DB53d642Af331bfbbfb3` | `0xcb500e6f54d241303bbeef9f2d19489b3f7ebac3` |
| MarketRegistry | `0xB7A66AC8308C94De7cc6bBe6CfDc5d2487c2E011` | `0xA0386563254AA4e9Df2c46FeE3ac253308D2e01a` |
| ExchangeCLOB | `0x5a8A13F9e92b7847D6F9e56e92FF7560e258844a` | `0x4dD4Fa13A3156187e942eCab908ACb40fAAA2C7E` |
| CentralizedOracleRouter | `0xDb200BaF0a9c0eC41fAD3Ea5cd0e3aF79216e931` | `0x25CE79880B75B04C979B56BA14caFdCB0a81F8b6` |
| DepositRouter | `0xA0Bb3eC8f540957E6F5d82f5Ebd2Beac39D65e36` | `0x9a877e9bA77D2eD34f6650232eB6c1742EDFd0f7` |
| SafeProxyFactory (non-upgradeable) | `0xC590Ab41e94F801c41c96Fa595f67D59B8C6A176` | — |
| ProxyWallet (user wallet logic) | — | `0xF3dFEd734BE236D2503E649F81F88e991B210773` |

## Features

- **Conditional outcome tokens** — binary/categorical market positions minted and redeemed against USDT collateral on BNB Chain
- **On-chain CLOB exchange** — order matching and settlement for outcome tokens, gas-optimized for BNB Smart Chain
- **Oracle-based resolution** — markets resolved through the CentralizedOracleRouter with full open-interest closure
- **Proxy wallets** — per-user proxy wallets deployed via SafeProxyFactory for streamlined deposits and trading
- **Timelocked upgrades** — all UUPS proxy upgrades are administered by a TimelockController for safety
- **Audited** — multiple external audit rounds completed with all findings resolved

## Repository Structure

```
contracts/
  ConditionalTokens.sol        # Outcome token minting, splitting, merging, redemption
  MarketRegistry.sol           # Market creation and lifecycle management
  ExchangeCLOB.sol             # Central limit order book exchange
  CentralizedOracleRouter.sol  # Market resolution oracle router
  DepositRouter.sol            # Collateral deposit routing
  SafeProxyFactory.sol         # User proxy wallet factory
  ProxyWallet.sol              # User wallet logic (implementation)
scripts/                       # Deployment and operations scripts
test/                          # Hardhat test suite
```

## Development

```bash
pnpm install
pnpm build   # hardhat compile
pnpm test    # hardhat test
```

To deploy or interact with BNB Smart Chain networks, configure your RPC and deployer key via environment variables (see `hardhat.config.ts` — `bscMainnet` / `bscTestnet` networks).
