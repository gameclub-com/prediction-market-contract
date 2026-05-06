# Option C Migration Scripts (reference)

These scripts are reference implementations for upgrading an existing v2 deployment to Option C (Full Closure). When integrating into the gameclub repo (`packages/contracts/scripts/`), adapt the env var names and any project-specific deployment patterns.

## Order of execution

```
1. upgrade-conditional-tokens-v3.ts   (ConditionalTokens proxy → v3 + initializeVx)
2. setup-ct-registry-link.ts          (MarketRegistry.setConditionalTokens)
3. upgrade-exchange-v4.ts             (ExchangeCLOB proxy → v4)
```

After all three: protocol-wide OI sync is active. ExchangeCLOB no longer calls `addVolumeAndOI` / `subtractOI` directly. ConditionalTokens drives `currentOI` via hooks on `splitPosition` / `mergePositions` / ERC1155 transfers.

## Env vars required

```
CONDITIONAL_TOKENS_ADDRESS=0x...
MARKET_REGISTRY_ADDRESS=0x...
EXCHANGE_ADDRESS=0x...
```

## Verification after migration

Run on testnet (or local hardhat fork) before mainnet:

1. `await ct.marketRegistry()` returns the registry address.
2. `await registry.conditionalTokensAddress()` returns the CT address.
3. Direct `ct.splitPosition(conditionId, amount)` increments `(await registry.getMarket(marketId)).currentOI` by `amount`.
4. Direct `ct.mergePositions(conditionId, amount)` decrements `currentOI` by `min(amount, eligibility)`.
5. ERC1155 `safeTransferFrom` emits `OIEligibilityMoved`.
6. `settleMintSweep` increments OI; CLOB MERGE decrements OI.
7. `recoverOI` admin escape hatch still works.

## For fresh deployments

If deploying fresh (no existing markets), the order is:

```
1. Deploy USDT (or use existing).
2. Deploy ConditionalTokens (UUPS proxy with `initialize`).
3. Deploy MarketRegistry (UUPS proxy with `initialize(ctAddr)`).
4. Call ct.initializeVx(registryAddr).
5. Call registry.setConditionalTokens(ctAddr).
6. Deploy ExchangeCLOB (UUPS proxy with `initialize(...)`).
7. Deploy CentralizedOracleRouter, link via registry.initOracleRouter(...).
8. Grant roles (RELAYER_ROLE etc.).
```

Steps 4 + 5 are the Option C wiring. Without them, splitPosition/mergePositions skip OI hooks (back-compat behavior).

## Backfill (existing testnet/mainnet)

If markets were created before Option C, run a separate `backfill-condition-id-mapping.ts` (not provided here — adapt from gameclub's market enumeration logic):

```typescript
const markets = /* enumerate from indexer DB or on-chain */;
for (const m of markets) {
  // Idempotent: skips if already mapped, reverts if mapped to different marketId
  await registry.backfillConditionMapping(m.marketId);
}
```

## Mainnet caveat

For mainnet with existing share holders:

- `oiEligibleShares` will be 0 for all existing positions (mappings default to zero).
- This means existing direct mergePositions on legacy holdings do NOT decrement OI (consistent with Option C invariant).
- Existing `currentOI` drift (under/over) must be reconciled via `recoverOI` admin operations.
- This is intentional: the eligibility model is forward-only. Backfilling per-user eligibility requires separate analysis (re-indexing share acquisition history).
- Recommendation: roll out Option C on testnet/fresh first; mainnet adoption is a separate Phase with eligibility backfill policy decision.
