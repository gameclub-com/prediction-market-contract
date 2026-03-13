import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import type {
  ExchangeCLOB,
  ConditionalTokens,
  MarketRegistry,
  MockUSDT,
} from "../typechain-types";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));
const ORACLE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));
const KEEPER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("KEEPER_ROLE"));
const SAFETY_COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SAFETY_COUNCIL_ROLE"));

const ONE = ethers.parseEther("1");
const HUNDRED = ethers.parseEther("100");
const THOUSAND = ethers.parseEther("1000");
const TEN_THOUSAND = ethers.parseEther("10000");

// ---------------------------------------------------------------------------
// Fixture — minimal deploy for seeding tests
// ---------------------------------------------------------------------------

async function seedFixture() {
  const [deployer, relayer, marketAdmin, oracle, keeper, safetyCouncil, feeCollector, treasury, mmWallet] =
    await ethers.getSigners();

  // Deploy contracts
  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const ConditionalTokens = await ethers.getContractFactory("ConditionalTokens");
  const ct = await ConditionalTokens.deploy(await usdt.getAddress(), treasury.address);

  const MarketRegistry = await ethers.getContractFactory("MarketRegistry");
  const registry = await MarketRegistry.deploy(await ct.getAddress());

  const ExchangeCLOB = await ethers.getContractFactory("ExchangeCLOB");
  const exchange = await ExchangeCLOB.deploy(
    await usdt.getAddress(),
    await ct.getAddress(),
    await registry.getAddress(),
    feeCollector.address,
    treasury.address
  );

  // Grant roles
  await exchange.grantRole(RELAYER_ROLE, relayer.address);
  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(ORACLE_ROLE, oracle.address);
  await registry.grantRole(KEEPER_ROLE, keeper.address);
  await registry.grantRole(SAFETY_COUNCIL_ROLE, safetyCouncil.address);
  await registry.grantRole(RELAYER_ROLE, await exchange.getAddress());

  // Set up profile
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("default"));
  await registry.setProfile(profileHash, 500, ethers.parseEther("10000"), ethers.parseEther("1000000"), 3600, 0, 0, false);

  // Create 2 markets
  const now = (await ethers.provider.getBlock("latest"))!.timestamp;
  const questionId1 = ethers.keccak256(ethers.toUtf8Bytes("Will BTC > 100k?"));
  const questionId2 = ethers.keccak256(ethers.toUtf8Bytes("Will ETH > 5k?"));

  await registry.connect(marketAdmin).createMarket({
    questionId: questionId1,
    endTime: now + 86400 * 7,
    profileHash,
    tags: ["crypto"],
    cutoff: now + 86400 * 7 - 3600,
    outcomeSlotCount: 2,
  });

  await registry.connect(marketAdmin).createMarket({
    questionId: questionId2,
    endTime: now + 86400 * 7,
    profileHash,
    tags: ["crypto"],
    cutoff: now + 86400 * 7 - 3600,
    outcomeSlotCount: 2,
  });

  const market1 = await registry.getMarket(1);
  const market2 = await registry.getMarket(2);
  const conditionId1 = market1.conditionId;
  const conditionId2 = market2.conditionId;

  // Mint USDT to mmWallet
  await usdt.mint(mmWallet.address, TEN_THOUSAND);

  return {
    deployer,
    relayer,
    marketAdmin,
    oracle,
    feeCollector,
    treasury,
    mmWallet,
    usdt,
    ct,
    registry,
    exchange,
    conditionId1,
    conditionId2,
  };
}

// ===========================================================================
// Test Suite — Phase 7: Non-custodial seed pipeline
// ===========================================================================

describe("SeedLiquidity", function () {
  // -----------------------------------------------------------------------
  // 1. Full seed pipeline: approve → split → approve Exchange (non-custodial)
  // -----------------------------------------------------------------------
  describe("Full seed pipeline", function () {
    it("should split USDT into YES/NO tokens held in MM wallet", async function () {
      const { mmWallet, usdt, ct, exchange, conditionId1 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();
      const exchangeAddr = await exchange.getAddress();
      const splitAmount = HUNDRED;

      // Step 1: Approve USDT → CT
      await usdt.connect(mmWallet).approve(ctAddr, splitAmount);

      // Step 2: Split position
      await ct.connect(mmWallet).splitPosition(conditionId1, splitAmount);

      // Verify: MM wallet now holds YES + NO tokens
      const collectionId0 = await ct.getCollectionId(conditionId1, 1); // indexSet=1 → outcome 0
      const collectionId1 = await ct.getCollectionId(conditionId1, 2); // indexSet=2 → outcome 1
      const posId0 = await ct.getPositionId(await usdt.getAddress(), collectionId0);
      const posId1 = await ct.getPositionId(await usdt.getAddress(), collectionId1);

      expect(await ct.balanceOf(mmWallet.address, posId0)).to.equal(splitAmount);
      expect(await ct.balanceOf(mmWallet.address, posId1)).to.equal(splitAmount);

      // Step 3: Approve Exchange for ERC1155 (so settlement can transferFrom)
      await ct.connect(mmWallet).setApprovalForAll(exchangeAddr, true);
      expect(await ct.isApprovedForAll(mmWallet.address, exchangeAddr)).to.be.true;

      // Step 4: Approve Exchange for USDT (so settlement can transferFrom)
      await usdt.connect(mmWallet).approve(exchangeAddr, ethers.MaxUint256);

      // Phase 7: Shares stay in wallet — no deposit needed
      // Verify shares are still in MM wallet (not Exchange)
      expect(await ct.balanceOf(mmWallet.address, posId0)).to.equal(splitAmount);
      expect(await ct.balanceOf(mmWallet.address, posId1)).to.equal(splitAmount);
    });

    it("should consume USDT equal to split amount", async function () {
      const { mmWallet, usdt, ct, conditionId1 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();
      const splitAmount = HUNDRED;

      const balanceBefore = await usdt.balanceOf(mmWallet.address);
      await usdt.connect(mmWallet).approve(ctAddr, splitAmount);
      await ct.connect(mmWallet).splitPosition(conditionId1, splitAmount);
      const balanceAfter = await usdt.balanceOf(mmWallet.address);

      expect(balanceBefore - balanceAfter).to.equal(splitAmount);
    });
  });

  // -----------------------------------------------------------------------
  // 2. Idempotency — CT balance > 0 indicates already seeded
  // -----------------------------------------------------------------------
  describe("Idempotency check", function () {
    it("CT balanceOf > 0 indicates already seeded", async function () {
      const { mmWallet, usdt, ct, conditionId1 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();
      const splitAmount = HUNDRED;

      const collYes = await ct.getCollectionId(conditionId1, 1);
      const posYes = await ct.getPositionId(await usdt.getAddress(), collYes);

      // Before seeding: CT balance should be 0
      expect(await ct.balanceOf(mmWallet.address, posYes)).to.equal(0n);

      // Seed
      await usdt.connect(mmWallet).approve(ctAddr, splitAmount);
      await ct.connect(mmWallet).splitPosition(conditionId1, splitAmount);

      // After seeding: CT balance > 0 → skip
      expect(await ct.balanceOf(mmWallet.address, posYes)).to.be.gt(0n);
    });

    it("can seed multiple markets independently", async function () {
      const { mmWallet, usdt, ct, conditionId1, conditionId2 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();
      const splitAmount = HUNDRED;

      // Approve once with MaxUint256
      await usdt.connect(mmWallet).approve(ctAddr, ethers.MaxUint256);

      // Split market 1
      await ct.connect(mmWallet).splitPosition(conditionId1, splitAmount);

      // Split market 2
      await ct.connect(mmWallet).splitPosition(conditionId2, splitAmount);

      // Both markets have YES tokens in wallet
      const coll1 = await ct.getCollectionId(conditionId1, 1);
      const pos1 = await ct.getPositionId(await usdt.getAddress(), coll1);
      const coll2 = await ct.getCollectionId(conditionId2, 1);
      const pos2 = await ct.getPositionId(await usdt.getAddress(), coll2);

      expect(await ct.balanceOf(mmWallet.address, pos1)).to.equal(splitAmount);
      expect(await ct.balanceOf(mmWallet.address, pos2)).to.equal(splitAmount);
    });
  });

  // -----------------------------------------------------------------------
  // 3. Merge positions back to USDT
  // -----------------------------------------------------------------------
  describe("Merge positions", function () {
    it("should merge YES+NO tokens back into USDT", async function () {
      const { mmWallet, usdt, ct, conditionId1 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();
      const splitAmount = HUNDRED;

      // Split first
      await usdt.connect(mmWallet).approve(ctAddr, splitAmount);
      await ct.connect(mmWallet).splitPosition(conditionId1, splitAmount);

      const usdtBefore = await usdt.balanceOf(mmWallet.address);

      // Merge back
      await ct.connect(mmWallet).mergePositions(conditionId1, splitAmount);

      const usdtAfter = await usdt.balanceOf(mmWallet.address);
      expect(usdtAfter - usdtBefore).to.equal(splitAmount);
    });

    it("should revert merge if insufficient outcome tokens", async function () {
      const { mmWallet, usdt, ct, conditionId1 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();
      const splitAmount = HUNDRED;

      // Split 100
      await usdt.connect(mmWallet).approve(ctAddr, splitAmount);
      await ct.connect(mmWallet).splitPosition(conditionId1, splitAmount);

      // Try to merge 200 → should revert
      await expect(
        ct.connect(mmWallet).mergePositions(conditionId1, splitAmount * 2n)
      ).to.be.reverted;
    });
  });

  // -----------------------------------------------------------------------
  // 4. Approval caching — setApprovalForAll once
  // -----------------------------------------------------------------------
  describe("Approval caching", function () {
    it("setApprovalForAll persists across multiple markets", async function () {
      const { mmWallet, usdt, ct, exchange, conditionId1, conditionId2 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();
      const exchangeAddr = await exchange.getAddress();
      const splitAmount = HUNDRED;

      await usdt.connect(mmWallet).approve(ctAddr, ethers.MaxUint256);

      // Approve exchange once
      await ct.connect(mmWallet).setApprovalForAll(exchangeAddr, true);
      expect(await ct.isApprovedForAll(mmWallet.address, exchangeAddr)).to.be.true;

      // Split market 1 — shares stay in wallet
      await ct.connect(mmWallet).splitPosition(conditionId1, splitAmount);

      // Split market 2 — no need for setApprovalForAll again
      await ct.connect(mmWallet).splitPosition(conditionId2, splitAmount);

      // Both have shares in wallet, approval still valid
      expect(await ct.isApprovedForAll(mmWallet.address, exchangeAddr)).to.be.true;

      const coll1 = await ct.getCollectionId(conditionId1, 1);
      const pos1 = await ct.getPositionId(await usdt.getAddress(), coll1);
      const coll2 = await ct.getCollectionId(conditionId2, 1);
      const pos2 = await ct.getPositionId(await usdt.getAddress(), coll2);

      expect(await ct.balanceOf(mmWallet.address, pos1)).to.equal(splitAmount);
      expect(await ct.balanceOf(mmWallet.address, pos2)).to.equal(splitAmount);
    });

    it("MaxUint256 USDT approval persists across splits", async function () {
      const { mmWallet, usdt, ct, conditionId1, conditionId2 } = await loadFixture(seedFixture);
      const ctAddr = await ct.getAddress();

      // Approve once with MaxUint256
      await usdt.connect(mmWallet).approve(ctAddr, ethers.MaxUint256);

      // Split market 1
      await ct.connect(mmWallet).splitPosition(conditionId1, HUNDRED);

      // Split market 2 — no additional approve needed
      await ct.connect(mmWallet).splitPosition(conditionId2, HUNDRED);

      // Both splits succeeded
      const coll1 = await ct.getCollectionId(conditionId1, 1);
      const pos1 = await ct.getPositionId(await usdt.getAddress(), coll1);
      const coll2 = await ct.getCollectionId(conditionId2, 1);
      const pos2 = await ct.getPositionId(await usdt.getAddress(), coll2);

      expect(await ct.balanceOf(mmWallet.address, pos1)).to.equal(HUNDRED);
      expect(await ct.balanceOf(mmWallet.address, pos2)).to.equal(HUNDRED);
    });
  });

  // -----------------------------------------------------------------------
  // 5. Edge cases
  // -----------------------------------------------------------------------
  describe("Edge cases", function () {
    it("should revert split with zero amount", async function () {
      const { mmWallet, usdt, ct, conditionId1 } = await loadFixture(seedFixture);
      await usdt.connect(mmWallet).approve(await ct.getAddress(), HUNDRED);

      await expect(
        ct.connect(mmWallet).splitPosition(conditionId1, 0)
      ).to.be.revertedWithCustomError(ct, "ZeroAmount");
    });

    it("should revert split with insufficient USDT", async function () {
      const { mmWallet, usdt, ct, conditionId1 } = await loadFixture(seedFixture);
      const tooMuch = TEN_THOUSAND * 2n; // 20k but only have 10k

      await usdt.connect(mmWallet).approve(await ct.getAddress(), tooMuch);

      await expect(
        ct.connect(mmWallet).splitPosition(conditionId1, tooMuch)
      ).to.be.reverted;
    });
  });
});
