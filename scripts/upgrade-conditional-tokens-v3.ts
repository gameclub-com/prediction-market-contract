// Reference upgrade script — Option C v3 ConditionalTokens upgrade.
// Adapt to gameclub repo paths/env vars when integrating.
//
// Prerequisites:
//   - V2 ConditionalTokens already deployed and using AccessControl (post migrateToAccessControl).
//   - MarketRegistry already deployed and reachable.
//   - Caller holds DEFAULT_ADMIN_ROLE on ConditionalTokens (UUPS authorizer).
//
// Effect:
//   - Upgrades CT implementation to V3 (Option C).
//   - Calls initializeVx(registry) reinitializer(3) to wire CT → MarketRegistry.
//   - After this script + setup-ct-registry-link.ts, splitPosition / mergePositions / transfer
//     hooks become active and increment/decrement currentOI in lockstep.

import { ethers, upgrades } from "hardhat";

async function main() {
  const ctAddr = process.env.CONDITIONAL_TOKENS_ADDRESS;
  const registryAddr = process.env.MARKET_REGISTRY_ADDRESS;

  if (!ctAddr) throw new Error("CONDITIONAL_TOKENS_ADDRESS env var missing");
  if (!registryAddr) throw new Error("MARKET_REGISTRY_ADDRESS env var missing");

  console.log("───────────────────────────────────────────────");
  console.log("Option C: ConditionalTokens v3 upgrade");
  console.log(`  CT proxy:       ${ctAddr}`);
  console.log(`  MarketRegistry: ${registryAddr}`);
  console.log("───────────────────────────────────────────────");

  const ConditionalTokensV3 = await ethers.getContractFactory("ConditionalTokens");
  console.log("Upgrading proxy implementation...");
  const ct = await upgrades.upgradeProxy(ctAddr, ConditionalTokensV3);
  await ct.waitForDeployment();
  console.log("  → upgraded.");

  console.log("Calling initializeVx(registry)...");
  const tx = await ct.initializeVx(registryAddr);
  const rcpt = await tx.wait();
  console.log(`  → tx: ${rcpt?.hash} @ block ${rcpt?.blockNumber}`);

  // Sanity check
  const linkedRegistry = await ct.marketRegistry();
  if (linkedRegistry.toLowerCase() !== registryAddr.toLowerCase()) {
    throw new Error(`marketRegistry mismatch: ${linkedRegistry} != ${registryAddr}`);
  }
  console.log("✓ initializeVx OK. CT now wired to MarketRegistry for OI sync.");
  console.log("");
  console.log("Next: run setup-ct-registry-link.ts to grant CT access on MarketRegistry side.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
