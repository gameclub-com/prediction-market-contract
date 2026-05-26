/**
 * QGM-38 fix: one-time backfill of `setApprovalForAll(ConditionalTokens, true)` for
 * legacy ProxyWallets that were created BEFORE the SafeProxyFactory was updated to
 * auto-approve the CT contract itself.
 *
 * After this script runs, admin `ConditionalTokens.redeemPositionsFor(holder, ...)`
 * succeeds for the listed holders. Without this backfill, that call reverts with
 * `HolderApprovalRequired(holder)`.
 *
 * Usage:
 *   PROXY_LIST='["0xProxy1","0xProxy2",...]' \
 *   CT_ADDRESS=0xCt... \
 *   OWNER_SIGNERS='{"0xProxy1":"<owner-private-key-or-keystore-ref>", ...}' \
 *   npx hardhat run scripts/backfill-proxy-ct-approval.ts --network <net>
 *
 * Operational notes:
 *   - Each call is signed by the ProxyWallet's owner EOA (msg.sender == owner) — the
 *     factory deployer cannot sign on behalf of all proxies because ProxyWallet.execute
 *     requires `msg.sender == owner` (or a valid owner EIP-712 signature).
 *   - In a typical MM operation, the same operator EOA owns all MM proxies; configure
 *     OWNER_SIGNERS to map each proxy address to that single key.
 *   - Idempotent: if `isApprovedForAll(proxy, CT) == true` already, the script skips it.
 *   - Recommend a dry-run on testnet first.
 */

import { ethers } from "hardhat";

const PROXY_WALLET_ABI = [
    "function owner() view returns (address)",
    "function execute(address target, uint256 value, bytes data) returns (bytes)",
];

const CT_ABI = [
    "function isApprovedForAll(address account, address operator) view returns (bool)",
    "function setApprovalForAll(address operator, bool approved)",
];

async function main() {
    const proxyListRaw = process.env.PROXY_LIST;
    const ctAddress = process.env.CT_ADDRESS;
    const ownerSignersRaw = process.env.OWNER_SIGNERS;

    if (!proxyListRaw) throw new Error("PROXY_LIST env var is required (JSON array of proxy addresses)");
    if (!ctAddress) throw new Error("CT_ADDRESS env var is required");
    if (!ownerSignersRaw) throw new Error("OWNER_SIGNERS env var is required (JSON map proxy → owner pk)");

    const proxies: string[] = JSON.parse(proxyListRaw);
    const ownerSigners: Record<string, string> = JSON.parse(ownerSignersRaw);

    const ct = await ethers.getContractAt(CT_ABI, ctAddress);
    const ctIface = new ethers.Interface(CT_ABI);
    const setApprovalCalldata = ctIface.encodeFunctionData("setApprovalForAll", [ctAddress, true]);

    let succeeded = 0;
    let skipped = 0;
    let failed = 0;

    for (const proxy of proxies) {
        const proxyNorm = ethers.getAddress(proxy);
        try {
            const alreadyApproved: boolean = await ct.isApprovedForAll(proxyNorm, ctAddress);
            if (alreadyApproved) {
                console.log(`[skip] ${proxyNorm} — already approved`);
                skipped++;
                continue;
            }

            const ownerPk = ownerSigners[proxyNorm] ?? ownerSigners[proxy];
            if (!ownerPk) {
                console.warn(`[fail] ${proxyNorm} — no owner key configured`);
                failed++;
                continue;
            }

            const ownerWallet = new ethers.Wallet(ownerPk, ethers.provider);
            const proxyWallet = await ethers.getContractAt(PROXY_WALLET_ABI, proxyNorm, ownerWallet);

            // Sanity-check: the configured key must actually be the proxy owner.
            const onChainOwner: string = await proxyWallet.owner();
            if (ethers.getAddress(onChainOwner) !== ethers.getAddress(ownerWallet.address)) {
                console.warn(`[fail] ${proxyNorm} — configured key ${ownerWallet.address} is not owner (${onChainOwner})`);
                failed++;
                continue;
            }

            const tx = await proxyWallet.execute(ctAddress, 0, setApprovalCalldata);
            const receipt = await tx.wait();
            console.log(`[ok]   ${proxyNorm} — tx ${receipt?.hash}`);
            succeeded++;
        } catch (err) {
            console.error(`[err]  ${proxy} —`, err instanceof Error ? err.message : err);
            failed++;
        }
    }

    console.log("");
    console.log(`Backfill summary: ${succeeded} succeeded, ${skipped} skipped, ${failed} failed`);
    if (failed > 0) process.exitCode = 1;
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
