// Reference upgrade script — Option C v4 ExchangeCLOB upgrade.
// Adapt to gameclub repo paths/env vars when integrating.
//
// Prerequisites:
//   - upgrade-conditional-tokens-v3.ts ran successfully.
//   - setup-ct-registry-link.ts ran successfully.
//   - Caller holds DEFAULT_ADMIN_ROLE on ExchangeCLOB.
//
// Effect:
//   - Upgrades ExchangeCLOB implementation to V4 (Option C).
//   - Internal logic changes: settleMintSweep no longer calls addVolumeAndOI (calls addVolume only),
//     _applyMerge no longer calls subtractOI. OI is now driven by ConditionalTokens hooks.
//   - No reinitializer needed — storage layout is unchanged from v3 ExchangeCLOB.
//   - hardhat-upgrades plugin verifies storage compatibility automatically.

import { ethers, upgrades } from "hardhat";

async function main() {
  const exchangeAddr = process.env.EXCHANGE_ADDRESS;
  if (!exchangeAddr) throw new Error("EXCHANGE_ADDRESS env var missing");

  console.log("───────────────────────────────────────────────");
  console.log("Option C: ExchangeCLOB v4 upgrade");
  console.log(`  Exchange proxy: ${exchangeAddr}`);
  console.log("───────────────────────────────────────────────");

  const ExchangeCLOBV4 = await ethers.getContractFactory("ExchangeCLOB");
  console.log("Upgrading proxy implementation...");
  const exchange = await upgrades.upgradeProxy(exchangeAddr, ExchangeCLOBV4);
  await exchange.waitForDeployment();
  console.log("  → upgraded.");

  // Sanity: confirm the upgrade by checking a non-storage view (constants survived).
  const maxFee = await exchange.MAX_FEE();
  console.log(`✓ ExchangeCLOB v4 active. MAX_FEE = ${maxFee}`);
  console.log("");
  console.log("Option C migration complete. Verify with on-chain testing:");
  console.log("  1. Direct splitPosition → currentOI increases");
  console.log("  2. Direct mergePositions → currentOI decreases");
  console.log("  3. settleMintSweep → currentOI increases via splitPosition hook");
  console.log("  4. CLOB MERGE → currentOI decreases via mergePositions hook");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
