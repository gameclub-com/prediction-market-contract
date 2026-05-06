// Reference script — Option C ConditionalTokens ↔ MarketRegistry linkage.
// Adapt to gameclub repo paths/env vars when integrating.
//
// Prerequisites:
//   - upgrade-conditional-tokens-v3.ts ran successfully (CT knows registry).
//   - Caller holds DEFAULT_ADMIN_ROLE on MarketRegistry.
//
// Effect:
//   - Calls MarketRegistry.setConditionalTokens(ct) — one-time setter.
//   - Enables onlyConditionalTokens modifier on addOIByCondition / subtractOIByCondition.
//   - Idempotent: if already set to the same address, skips.
//   - If already set to a DIFFERENT address, throws (operator must call
//     emergencyResetConditionalTokens first).
//
// Optional: backfill conditionIdToMarketId for markets created before Option C upgrade.

import { ethers } from "hardhat";

async function main() {
  const registryAddr = process.env.MARKET_REGISTRY_ADDRESS;
  const ctAddr = process.env.CONDITIONAL_TOKENS_ADDRESS;
  if (!registryAddr) throw new Error("MARKET_REGISTRY_ADDRESS env var missing");
  if (!ctAddr) throw new Error("CONDITIONAL_TOKENS_ADDRESS env var missing");

  const registry = await ethers.getContractAt("MarketRegistry", registryAddr);

  console.log("───────────────────────────────────────────────");
  console.log("Option C: MarketRegistry ↔ ConditionalTokens link");
  console.log(`  Registry: ${registryAddr}`);
  console.log(`  CT:       ${ctAddr}`);
  console.log("───────────────────────────────────────────────");

  // Idempotency check
  const current: string = await registry.conditionalTokensAddress();
  if (current.toLowerCase() === ctAddr.toLowerCase()) {
    console.log("Already linked. Skipping setConditionalTokens.");
  } else if (current !== ethers.ZeroAddress) {
    throw new Error(
      `MarketRegistry already linked to a different CT: ${current}. ` +
      `Run emergencyResetConditionalTokens() first if rotation is intended.`
    );
  } else {
    console.log("Calling setConditionalTokens...");
    const tx = await registry.setConditionalTokens(ctAddr);
    const rcpt = await tx.wait();
    console.log(`  → tx: ${rcpt?.hash} @ block ${rcpt?.blockNumber}`);
    console.log("✓ Linked.");
  }

  // Optional: backfill condition mappings for legacy markets.
  // For fresh deployments (no markets yet), this is a no-op and can be skipped.
  // For existing testnet/mainnet with prior markets, run a separate
  // backfill-condition-id-mapping.ts that iterates through all markets.

  console.log("");
  console.log("Next: run upgrade-exchange-v4.ts to remove ExchangeCLOB's direct OI calls.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
