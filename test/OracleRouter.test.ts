import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import type {
  CentralizedOracleRouter,
  MarketRegistry,
  ConditionalTokens,
  MockUSDT,
} from "../typechain-types";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));
const PROPOSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROPOSER_ROLE"));
const COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("COUNCIL_ROLE"));
const SAFETY_COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SAFETY_COUNCIL_ROLE"));

const DISPUTE_WINDOW = 3600; // 1 hour
const DISPUTE_BOND = ethers.parseEther("100");

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

async function oracleFixture() {
  const [deployer, proposer, council, disputer, disputer2, marketAdmin, treasury] =
    await ethers.getSigners();

  // Deploy contracts
  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const CT = await ethers.getContractFactory("ConditionalTokens");
  const ct = await upgrades.deployProxy(CT, [await usdt.getAddress(), treasury.address, deployer.address], {
    kind: 'uups', initializer: 'initialize',
  });

  const MR = await ethers.getContractFactory("MarketRegistry");
  const registry = await upgrades.deployProxy(MR, [await ct.getAddress()], {
    kind: 'uups', initializer: 'initialize',
  });

  const Router = await ethers.getContractFactory("CentralizedOracleRouter");
  const router = await upgrades.deployProxy(Router, [await registry.getAddress(), await usdt.getAddress(), treasury.address], {
    kind: 'uups', initializer: 'initialize',
  });

  // H-4 v2: Wire oracle router (2-step with 24h delay)
  await registry.proposeOracleRouter(await router.getAddress());
  await time.increase(86400);
  await registry.acceptOracleRouter();

  // Grant roles
  await router.grantRole(PROPOSER_ROLE, proposer.address);
  await router.grantRole(COUNCIL_ROLE, council.address);
  await router.grantRole(SAFETY_COUNCIL_ROLE, council.address);
  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(SAFETY_COUNCIL_ROLE, council.address);

  // Create profile with disputes enabled
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("dispute-enabled"));
  await registry.setProfile(
    profileHash, 500, ethers.parseEther("10000"), ethers.parseEther("1000000"),
    3600, DISPUTE_WINDOW, DISPUTE_BOND, true,
  );

  // Create profile with disputes disabled (immediate finalization)
  const noDisputeProfile = ethers.keccak256(ethers.toUtf8Bytes("no-dispute"));
  await registry.setProfile(
    noDisputeProfile, 500, ethers.parseEther("10000"), ethers.parseEther("1000000"),
    3600, 0, 0, false,
  );

  // H-2 v2: proposeOutcome requires time past cutoff/endTime
  // Use short cutoff (1h) so tests can advance time easily
  const now = await time.latest();
  const MARKET_CUTOFF = now + 3600;
  const MARKET_END = now + 3600 * 2;
  const questionId1 = ethers.keccak256(ethers.toUtf8Bytes("Will BTC > 100k?"));

  await registry.connect(marketAdmin).createMarket({
    questionId: questionId1,
    endTime: MARKET_END,
    profileHash,
    tags: ["crypto"],
    cutoff: MARKET_CUTOFF,
    outcomeSlotCount: 2, collateralPerSet: 0,
  });

  // Create market with disputes disabled
  const questionId2 = ethers.keccak256(ethers.toUtf8Bytes("Will ETH > 5k?"));
  await registry.connect(marketAdmin).createMarket({
    questionId: questionId2,
    endTime: MARKET_END,
    profileHash: noDisputeProfile,
    tags: ["crypto"],
    cutoff: MARKET_CUTOFF,
    outcomeSlotCount: 2, collateralPerSet: 0,
  });

  // H-2 v2: Advance past cutoff so proposeOutcome works in all tests
  await time.increase(3600);

  // Mint USDT to disputers for bonds
  await usdt.mint(disputer.address, ethers.parseEther("10000"));
  await usdt.mint(disputer2.address, ethers.parseEther("10000"));

  return {
    deployer, proposer, council, disputer, disputer2, marketAdmin, treasury,
    usdt, ct, registry, router,
    profileHash, noDisputeProfile,
  };
}

// ===========================================================================
// Test Suite — CentralizedOracleRouter
// ===========================================================================

describe("CentralizedOracleRouter", function () {
  // -----------------------------------------------------------------------
  // 1. Deployment
  // -----------------------------------------------------------------------
  describe("Deployment", function () {
    it("should set immutable references correctly", async function () {
      const { router, registry, usdt, treasury } = await loadFixture(oracleFixture);
      expect(await router.marketRegistry()).to.equal(await registry.getAddress());
      expect(await router.bondToken()).to.equal(await usdt.getAddress());
      expect(await router.treasury()).to.equal(treasury.address);
    });

    it("should revert with zero address", async function () {
      const Router = await ethers.getContractFactory("CentralizedOracleRouter");
      await expect(
        upgrades.deployProxy(Router, [ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress], {
          kind: 'uups', initializer: 'initialize',
        }),
      ).to.be.revertedWithCustomError(Router, "ZeroAddress");
    });
  });

  // -----------------------------------------------------------------------
  // 2. proposeOutcome — immediate finalization (disputes disabled)
  // -----------------------------------------------------------------------
  describe("proposeOutcome — immediate finalization", function () {
    it("should finalize immediately when disputes disabled", async function () {
      const { proposer, router, registry } = await loadFixture(oracleFixture);

      // Market 2 has no-dispute profile
      await router.connect(proposer).proposeOutcome(2, 0);

      const proposal = await router.getProposal(2);
      expect(proposal.status).to.equal(3); // FINALIZED
      expect(proposal.outcomeIndex).to.equal(0);

      const market = await registry.getMarket(2);
      expect(market.resolved).to.be.true;
      expect(market.finalized).to.be.true;
    });

    it("should emit both Proposed and Finalized events", async function () {
      const { proposer, router } = await loadFixture(oracleFixture);

      await expect(router.connect(proposer).proposeOutcome(2, 0))
        .to.emit(router, "OutcomeProposed")
        .and.to.emit(router, "OutcomeFinalized");
    });
  });

  // -----------------------------------------------------------------------
  // 3. proposeOutcome — dispute window
  // -----------------------------------------------------------------------
  describe("proposeOutcome — with dispute window", function () {
    it("should set PROPOSED status and correct deadline", async function () {
      const { proposer, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 1);

      const proposal = await router.getProposal(1);
      expect(proposal.status).to.equal(1); // PROPOSED
      expect(proposal.outcomeIndex).to.equal(1);
      expect(proposal.proposer).to.equal(proposer.address);
      expect(proposal.disputeDeadline).to.be.gt(proposal.proposedAt);
    });

    it("should mark market as resolved (stops trading)", async function () {
      const { proposer, router, registry } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      const market = await registry.getMarket(1);
      expect(market.resolved).to.be.true;
      expect(market.finalized).to.be.false;
    });

    it("should revert for non-proposer", async function () {
      const { disputer, router } = await loadFixture(oracleFixture);

      await expect(
        router.connect(disputer).proposeOutcome(1, 0),
      ).to.be.reverted;
    });

    it("should revert for invalid outcomeIndex > 1", async function () {
      const { proposer, router } = await loadFixture(oracleFixture);

      await expect(
        router.connect(proposer).proposeOutcome(1, 2),
      ).to.be.revertedWithCustomError(router, "InvalidOutcome");
    });

    it("should revert if proposal already exists (PROPOSED)", async function () {
      const { proposer, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      await expect(
        router.connect(proposer).proposeOutcome(1, 1),
      ).to.be.revertedWithCustomError(router, "ProposalAlreadyExists");
    });
  });

  // -----------------------------------------------------------------------
  // 4. disputeOutcome
  // -----------------------------------------------------------------------
  describe("disputeOutcome", function () {
    it("should accept dispute with bond transfer", async function () {
      const { proposer, disputer, router, usdt } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      // Approve bond
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);

      const balBefore = await usdt.balanceOf(disputer.address);
      await router.connect(disputer).disputeOutcome(1);
      const balAfter = await usdt.balanceOf(disputer.address);

      expect(balBefore - balAfter).to.equal(DISPUTE_BOND);

      const proposal = await router.getProposal(1);
      expect(proposal.status).to.equal(2); // DISPUTED
      expect(proposal.disputer).to.equal(disputer.address);
      expect(proposal.disputeBond).to.equal(DISPUTE_BOND);
    });

    it("should freeze market on dispute", async function () {
      const { proposer, disputer, router, registry, usdt } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      const market = await registry.getMarket(1);
      expect(market.frozen).to.be.true;
    });

    it("should emit OutcomeDisputed event", async function () {
      const { proposer, disputer, router, usdt } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);

      await expect(router.connect(disputer).disputeOutcome(1))
        .to.emit(router, "OutcomeDisputed")
        .withArgs(1, disputer.address, DISPUTE_BOND);
    });

    it("should revert if not in PROPOSED status", async function () {
      const { disputer, router } = await loadFixture(oracleFixture);

      await expect(
        router.connect(disputer).disputeOutcome(1),
      ).to.be.revertedWithCustomError(router, "ProposalNotProposed");
    });

    it("should revert if dispute window expired", async function () {
      const { proposer, disputer, router, usdt } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);

      // Fast-forward past dispute window
      await time.increase(DISPUTE_WINDOW + 1);

      await expect(
        router.connect(disputer).disputeOutcome(1),
      ).to.be.revertedWithCustomError(router, "DisputeWindowExpired");
    });
  });

  // -----------------------------------------------------------------------
  // 5. finalizeOutcome (after dispute window, no dispute)
  // -----------------------------------------------------------------------
  describe("finalizeOutcome", function () {
    it("should finalize after dispute window expires", async function () {
      const { proposer, disputer, router, registry } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      // Fast-forward past dispute window
      await time.increase(DISPUTE_WINDOW + 1);

      await router.connect(disputer).finalizeOutcome(1); // anyone can call

      const proposal = await router.getProposal(1);
      expect(proposal.status).to.equal(3); // FINALIZED

      const market = await registry.getMarket(1);
      expect(market.finalized).to.be.true;
    });

    it("should emit OutcomeFinalized event", async function () {
      const { proposer, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await time.increase(DISPUTE_WINDOW + 1);

      await expect(router.finalizeOutcome(1))
        .to.emit(router, "OutcomeFinalized")
        .withArgs(1, 0);
    });

    it("should revert if dispute window not expired", async function () {
      const { proposer, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      await expect(
        router.finalizeOutcome(1),
      ).to.be.revertedWithCustomError(router, "DisputeWindowNotExpired");
    });

    it("should revert if not in PROPOSED status", async function () {
      const { router } = await loadFixture(oracleFixture);

      await expect(
        router.finalizeOutcome(1),
      ).to.be.revertedWithCustomError(router, "ProposalNotProposed");
    });
  });

  // -----------------------------------------------------------------------
  // 6. councilResolve — dispute upheld (disputer wins)
  // -----------------------------------------------------------------------
  describe("councilResolve — dispute upheld", function () {
    it("should finalize with new outcome and return bond to disputer", async function () {
      const { proposer, council, disputer, router, registry, usdt } =
        await loadFixture(oracleFixture);

      // Propose outcome 0
      await router.connect(proposer).proposeOutcome(1, 0);

      // Dispute
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      const balBefore = await usdt.balanceOf(disputer.address);

      // Council resolves with outcome 1 (different from proposed 0) → disputer wins
      await router.connect(council).councilResolve(1, 1);

      const balAfter = await usdt.balanceOf(disputer.address);
      expect(balAfter - balBefore).to.equal(DISPUTE_BOND);

      const proposal = await router.getProposal(1);
      expect(proposal.status).to.equal(3); // FINALIZED

      const market = await registry.getMarket(1);
      expect(market.finalized).to.be.true;
    });
  });

  // -----------------------------------------------------------------------
  // 7. councilResolve — dispute rejected (proposer was right)
  // -----------------------------------------------------------------------
  describe("councilResolve — dispute rejected", function () {
    it("should finalize with original outcome and send bond to treasury", async function () {
      const { proposer, council, disputer, router, usdt, treasury } =
        await loadFixture(oracleFixture);

      // Propose outcome 0
      await router.connect(proposer).proposeOutcome(1, 0);

      // Dispute
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      const treasuryBefore = await usdt.balanceOf(treasury.address);

      // Council resolves with outcome 0 (same as proposed) → disputer loses bond
      await router.connect(council).councilResolve(1, 0);

      const treasuryAfter = await usdt.balanceOf(treasury.address);
      expect(treasuryAfter - treasuryBefore).to.equal(DISPUTE_BOND);
    });

    it("should revert if not disputed", async function () {
      const { proposer, council, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      await expect(
        router.connect(council).councilResolve(1, 0),
      ).to.be.revertedWithCustomError(router, "ProposalNotDisputed");
    });

    it("should revert for non-council role", async function () {
      const { proposer, disputer, router, usdt } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      await expect(
        router.connect(disputer).councilResolve(1, 0),
      ).to.be.reverted;
    });
  });

  // -----------------------------------------------------------------------
  // 8. emergencyReject
  // -----------------------------------------------------------------------
  describe("emergencyReject", function () {
    it("should reject proposal and unresolve market", async function () {
      const { proposer, council, router, registry } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      await router.connect(council).emergencyReject(1);

      const proposal = await router.getProposal(1);
      expect(proposal.status).to.equal(4); // REJECTED

      const market = await registry.getMarket(1);
      expect(market.resolved).to.be.false;
      expect(market.finalized).to.be.false;
    });

    it("should return bond to disputer on rejected dispute", async function () {
      const { proposer, council, disputer, router, usdt } =
        await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      const balBefore = await usdt.balanceOf(disputer.address);
      await router.connect(council).emergencyReject(1);
      const balAfter = await usdt.balanceOf(disputer.address);

      expect(balAfter - balBefore).to.equal(DISPUTE_BOND);
    });

    it("should allow re-proposal after rejection", async function () {
      const { proposer, council, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await router.connect(council).emergencyReject(1);

      // Re-propose with different outcome
      await router.connect(proposer).proposeOutcome(1, 1);

      const proposal = await router.getProposal(1);
      expect(proposal.status).to.equal(1); // PROPOSED
      expect(proposal.outcomeIndex).to.equal(1);
    });

    it("should revert for non-council role", async function () {
      const { proposer, disputer, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      await expect(
        router.connect(disputer).emergencyReject(1),
      ).to.be.reverted;
    });

    it("should revert if already finalized", async function () {
      const { proposer, council, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await time.increase(DISPUTE_WINDOW + 1);
      await router.finalizeOutcome(1);

      await expect(
        router.connect(council).emergencyReject(1),
      ).to.be.revertedWithCustomError(router, "ProposalNotFound");
    });
  });

  // -----------------------------------------------------------------------
  // 9. Full lifecycle E2E
  // -----------------------------------------------------------------------
  describe("E2E: propose → dispute → council resolve → redeem", function () {
    it("full dispute lifecycle with bond disposition", async function () {
      const { proposer, council, disputer, router, usdt, treasury } =
        await loadFixture(oracleFixture);

      // 1. Propose outcome 0 (YES wins)
      await router.connect(proposer).proposeOutcome(1, 0);

      // 2. Disputer disputes
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      // 3. Council agrees with original → disputer loses bond
      const treasuryBefore = await usdt.balanceOf(treasury.address);
      await router.connect(council).councilResolve(1, 0);
      const treasuryAfter = await usdt.balanceOf(treasury.address);

      expect(treasuryAfter - treasuryBefore).to.equal(DISPUTE_BOND);

      // 4. Verify final state
      const proposal = await router.getProposal(1);
      expect(proposal.status).to.equal(3); // FINALIZED
      expect(proposal.outcomeIndex).to.equal(0);
    });
  });

  // -----------------------------------------------------------------------
  // 10. Admin functions
  // -----------------------------------------------------------------------
  describe("Admin", function () {
    it("setTreasury updates treasury address", async function () {
      const { deployer, router, disputer } = await loadFixture(oracleFixture);

      await expect(router.connect(deployer).setTreasury(disputer.address))
        .to.emit(router, "TreasuryUpdated");

      expect(await router.treasury()).to.equal(disputer.address);
    });

    it("setTreasury reverts with zero address", async function () {
      const { deployer, router } = await loadFixture(oracleFixture);

      await expect(
        router.connect(deployer).setTreasury(ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(router, "ZeroAddress");
    });

    it("setTreasury reverts for non-admin", async function () {
      const { disputer, router } = await loadFixture(oracleFixture);

      await expect(
        router.connect(disputer).setTreasury(disputer.address),
      ).to.be.reverted;
    });
  });

  // -----------------------------------------------------------------------
  // 11. H-3 v2: emergencyResolve (replaces overrideOutcome)
  // -----------------------------------------------------------------------
  describe("emergencyResolve", function () {
    it("SAFETY_COUNCIL can resolve without prior proposal", async function () {
      const { council, router, registry, ct } = await loadFixture(oracleFixture);

      await router.connect(council).emergencyResolve(1, 0);

      const market = await registry.getMarket(1);
      expect(market.resolved).to.be.true;
      expect(market.finalized).to.be.true;

      const conditionId = market.conditionId;
      expect(await ct.isResolved(conditionId)).to.be.true;
      expect(await ct.payoutNumerators(conditionId, 0)).to.equal(1n);
      expect(await ct.payoutNumerators(conditionId, 1)).to.equal(0n);
    });

    it("returns dispute bond to disputer when disputed", async function () {
      const { proposer, council, disputer, router, usdt } = await loadFixture(oracleFixture);

      // Propose and dispute
      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      const balBefore = await usdt.balanceOf(disputer.address);

      // Emergency resolve — should return bond to disputer
      await router.connect(council).emergencyResolve(1, 1);

      const balAfter = await usdt.balanceOf(disputer.address);
      expect(balAfter - balBefore).to.equal(DISPUTE_BOND);
    });

    it("reverts if already finalized", async function () {
      const { proposer, council, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);
      await time.increase(DISPUTE_WINDOW + 1);
      await router.finalizeOutcome(1);

      await expect(
        router.connect(council).emergencyResolve(1, 0),
      ).to.be.revertedWithCustomError(router, "ProposalAlreadyExists");
    });

    it("non-SAFETY_COUNCIL reverts", async function () {
      const { disputer, router } = await loadFixture(oracleFixture);

      await expect(
        router.connect(disputer).emergencyResolve(1, 0),
      ).to.be.reverted;
    });
  });

  // -----------------------------------------------------------------------
  // 12. H-2 v2: proposeOutcome time check
  // -----------------------------------------------------------------------
  describe("proposeOutcome — time validation", function () {
    it("PROPOSER cannot propose before cutoff", async function () {
      const { proposer, router, registry, marketAdmin } = await loadFixture(oracleFixture);

      // Create a new market with far-future cutoff
      const now = await time.latest();
      const profileHash = ethers.keccak256(ethers.toUtf8Bytes("dispute-enabled"));
      const futureQid = ethers.keccak256(ethers.toUtf8Bytes("future-market"));
      await registry.connect(marketAdmin).createMarket({
        questionId: futureQid,
        endTime: now + 86400 * 30,
        profileHash,
        tags: ["test"],
        cutoff: now + 86400 * 29,
        outcomeSlotCount: 2, collateralPerSet: 0,
      });

      // Market 3 has far-future cutoff — cannot propose yet
      await expect(
        router.connect(proposer).proposeOutcome(3, 0),
      ).to.be.revertedWith("Market not yet ended");
    });

    it("SAFETY_COUNCIL can emergencyResolve before cutoff (bypasses time check)", async function () {
      const { council, router, registry, marketAdmin } = await loadFixture(oracleFixture);

      // Create a new market with far-future cutoff
      const now = await time.latest();
      const profileHash = ethers.keccak256(ethers.toUtf8Bytes("dispute-enabled"));
      const futureQid = ethers.keccak256(ethers.toUtf8Bytes("future-market-sc"));
      await registry.connect(marketAdmin).createMarket({
        questionId: futureQid,
        endTime: now + 86400 * 30,
        profileHash,
        tags: ["test"],
        cutoff: now + 86400 * 29,
        outcomeSlotCount: 2, collateralPerSet: 0,
      });

      // SAFETY_COUNCIL can resolve at any time
      await router.connect(council).emergencyResolve(3, 1);

      const market = await registry.getMarket(3);
      expect(market.resolved).to.be.true;
      expect(market.finalized).to.be.true;
    });
  });

  // -----------------------------------------------------------------------
  // 13. Dispute window blocks redemption (isResolved = false until finalized)
  // -----------------------------------------------------------------------
  describe("Dispute window blocks on-chain redemption", function () {
    it("redeemPositions reverts during dispute window (isResolved is false)", async function () {
      const { proposer, router, ct, registry, usdt, disputer } =
        await loadFixture(oracleFixture);

      // Mint USDT and split to get outcome tokens
      const market = await registry.getMarket(1);
      const conditionId = market.conditionId;
      const splitAmount = ethers.parseEther("100");
      await usdt.mint(disputer.address, splitAmount);
      await usdt.connect(disputer).approve(await ct.getAddress(), splitAmount);
      await ct.connect(disputer).splitPosition(conditionId, splitAmount);

      // Propose outcome (starts dispute window)
      await router.connect(proposer).proposeOutcome(1, 0);

      // Verify: market is resolved but NOT finalized
      const marketAfter = await registry.getMarket(1);
      expect(marketAfter.resolved).to.be.true;
      expect(marketAfter.finalized).to.be.false;

      // Verify: ConditionalTokens isResolved is still FALSE (reportPayouts not called yet)
      expect(await ct.isResolved(conditionId)).to.be.false;

      // Attempt to redeem during dispute window — should revert
      await expect(
        ct.connect(disputer).redeemPositions(conditionId, [1]),
      ).to.be.revertedWithCustomError(ct, "ConditionNotResolved");
    });

    it("redeemPositions succeeds after finalization (dispute window expired)", async function () {
      const { proposer, router, ct, registry, usdt, disputer } =
        await loadFixture(oracleFixture);

      // Split to get outcome tokens
      const market = await registry.getMarket(1);
      const conditionId = market.conditionId;
      const splitAmount = ethers.parseEther("100");
      await usdt.mint(disputer.address, splitAmount);
      await usdt.connect(disputer).approve(await ct.getAddress(), splitAmount);
      await ct.connect(disputer).splitPosition(conditionId, splitAmount);

      // Propose → wait dispute window → finalize
      await router.connect(proposer).proposeOutcome(1, 0);
      await time.increase(DISPUTE_WINDOW + 1);
      await router.finalizeOutcome(1);

      // Now isResolved should be true
      expect(await ct.isResolved(conditionId)).to.be.true;

      // Redeem winning outcome (outcome 0)
      const balBefore = await usdt.balanceOf(disputer.address);
      await ct.connect(disputer).redeemPositions(conditionId, [1]); // indexSet 1 = outcome 0
      const balAfter = await usdt.balanceOf(disputer.address);

      expect(balAfter - balBefore).to.equal(splitAmount);
    });

    it("redeemPositions succeeds after council resolve (dispute upheld)", async function () {
      const { proposer, council, disputer, router, ct, registry, usdt } =
        await loadFixture(oracleFixture);

      // Split to get outcome tokens
      const market = await registry.getMarket(1);
      const conditionId = market.conditionId;
      const splitAmount = ethers.parseEther("100");
      await usdt.mint(disputer.address, splitAmount);
      await usdt.connect(disputer).approve(await ct.getAddress(), splitAmount);
      await ct.connect(disputer).splitPosition(conditionId, splitAmount);

      // Propose → dispute → council resolves with different outcome
      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      // During dispute: redeem should still fail
      expect(await ct.isResolved(conditionId)).to.be.false;
      await expect(
        ct.connect(disputer).redeemPositions(conditionId, [1]),
      ).to.be.revertedWithCustomError(ct, "ConditionNotResolved");

      // Council resolves with outcome 1 (overturns proposal)
      await router.connect(council).councilResolve(1, 1);

      // Now isResolved should be true
      expect(await ct.isResolved(conditionId)).to.be.true;

      // Redeem outcome 1 (winning after council override)
      const balBefore = await usdt.balanceOf(disputer.address);
      await ct.connect(disputer).redeemPositions(conditionId, [2]); // indexSet 2 = outcome 1
      const balAfter = await usdt.balanceOf(disputer.address);

      expect(balAfter - balBefore).to.equal(splitAmount);
    });
  });

  // -----------------------------------------------------------------------
  // 14. rescueBond
  // -----------------------------------------------------------------------
  describe("rescueBond", function () {
    it("rescues bond from orphaned disputed proposal", async function () {
      const { proposer, council, disputer, router, registry, usdt, marketAdmin } =
        await loadFixture(oracleFixture);

      // Propose and dispute market 1
      await router.connect(proposer).proposeOutcome(1, 0);
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(1);

      // Expire market externally (bypasses OracleRouter)
      const market = await registry.getMarket(1);
      await time.increase(3600 * 2 + 1); // past endTime
      await registry.grantRole(ethers.keccak256(ethers.toUtf8Bytes("KEEPER_ROLE")), council.address);
      await registry.connect(council).expireMarket(1);

      // Bond is stuck — rescue it
      const balBefore = await usdt.balanceOf(disputer.address);
      await router.connect(council).rescueBond(1);
      const balAfter = await usdt.balanceOf(disputer.address);

      expect(balAfter - balBefore).to.equal(DISPUTE_BOND);
    });

    it("reverts if proposal is not disputed", async function () {
      const { proposer, council, router } = await loadFixture(oracleFixture);

      await router.connect(proposer).proposeOutcome(1, 0);

      await expect(
        router.connect(council).rescueBond(1),
      ).to.be.revertedWithCustomError(router, "ProposalNotDisputed");
    });
  });

  // -----------------------------------------------------------------------
  // 15. proposeOutcomeBatch — multi-market resolution in single tx
  // -----------------------------------------------------------------------
  describe("proposeOutcomeBatch", function () {
    // Helper: create multiple markets for batch testing
    async function batchFixture() {
      const base = await loadFixture(oracleFixture);
      const { registry, marketAdmin } = base;

      const now = await time.latest();
      const cutoff = now + 100;
      const endTime = now + 200;

      // Create 3 more markets (market IDs 3, 4, 5) — all dispute-enabled
      for (let i = 0; i < 3; i++) {
        const qid = ethers.keccak256(ethers.toUtf8Bytes(`batch-market-${i}`));
        await registry.connect(marketAdmin).createMarket({
          questionId: qid,
          endTime,
          profileHash: base.profileHash,
          tags: ["batch"],
          cutoff,
          outcomeSlotCount: 2,
          collateralPerSet: 0,
        });
      }

      // Create 2 more markets (market IDs 6, 7) — no-dispute (immediate finalization)
      for (let i = 0; i < 2; i++) {
        const qid = ethers.keccak256(ethers.toUtf8Bytes(`batch-nodispute-${i}`));
        await registry.connect(marketAdmin).createMarket({
          questionId: qid,
          endTime,
          profileHash: base.noDisputeProfile,
          tags: ["batch"],
          cutoff,
          outcomeSlotCount: 2,
          collateralPerSet: 0,
        });
      }

      // Advance past cutoff
      await time.increase(101);

      return base;
    }

    it("should propose multiple dispute-enabled markets in one tx", async function () {
      const { proposer, router, registry } = await batchFixture();

      await router.connect(proposer).proposeOutcomeBatch(
        [3, 4, 5],
        [0, 1, 0],
      );

      // All should be PROPOSED with dispute window
      for (const id of [3, 4, 5]) {
        const proposal = await router.getProposal(id);
        expect(proposal.status).to.equal(1); // PROPOSED

        const market = await registry.getMarket(id);
        expect(market.resolved).to.be.true;
        expect(market.finalized).to.be.false;
      }

      expect((await router.getProposal(3)).outcomeIndex).to.equal(0);
      expect((await router.getProposal(4)).outcomeIndex).to.equal(1);
      expect((await router.getProposal(5)).outcomeIndex).to.equal(0);
    });

    it("should finalize immediately for no-dispute markets in batch", async function () {
      const { proposer, router, registry } = await batchFixture();

      await router.connect(proposer).proposeOutcomeBatch(
        [6, 7],
        [0, 1],
      );

      for (const id of [6, 7]) {
        const proposal = await router.getProposal(id);
        expect(proposal.status).to.equal(3); // FINALIZED

        const market = await registry.getMarket(id);
        expect(market.resolved).to.be.true;
        expect(market.finalized).to.be.true;
      }
    });

    it("should handle mixed dispute/no-dispute markets in one batch", async function () {
      const { proposer, router, registry } = await batchFixture();

      // 3 = dispute-enabled, 6 = no-dispute
      await router.connect(proposer).proposeOutcomeBatch(
        [3, 6],
        [0, 1],
      );

      // Market 3: PROPOSED (dispute window)
      const p3 = await router.getProposal(3);
      expect(p3.status).to.equal(1);
      const m3 = await registry.getMarket(3);
      expect(m3.resolved).to.be.true;
      expect(m3.finalized).to.be.false;

      // Market 6: FINALIZED (no dispute)
      const p6 = await router.getProposal(6);
      expect(p6.status).to.equal(3);
      const m6 = await registry.getMarket(6);
      expect(m6.resolved).to.be.true;
      expect(m6.finalized).to.be.true;
    });

    it("should revert on array length mismatch", async function () {
      const { proposer, router } = await batchFixture();

      await expect(
        router.connect(proposer).proposeOutcomeBatch([3, 4], [0]),
      ).to.be.revertedWith("Array length mismatch");
    });

    it("should revert on empty batch", async function () {
      const { proposer, router } = await batchFixture();

      await expect(
        router.connect(proposer).proposeOutcomeBatch([], []),
      ).to.be.revertedWith("Empty batch");
    });

    it("should revert for non-proposer", async function () {
      const { disputer, router } = await batchFixture();

      await expect(
        router.connect(disputer).proposeOutcomeBatch([3], [0]),
      ).to.be.reverted;
    });

    it("should revert entire batch if any market already proposed", async function () {
      const { proposer, router } = await batchFixture();

      // Propose market 3 individually first
      await router.connect(proposer).proposeOutcome(3, 0);

      // Batch including already-proposed market 3 should revert
      await expect(
        router.connect(proposer).proposeOutcomeBatch([3, 4], [1, 0]),
      ).to.be.revertedWithCustomError(router, "ProposalAlreadyExists");
    });

    it("E2E: batch propose → dispute one → council resolve → finalize others", async function () {
      const { proposer, council, disputer, router, registry, usdt } = await batchFixture();

      // 1. Batch propose markets 3, 4, 5 (all dispute-enabled)
      await router.connect(proposer).proposeOutcomeBatch([3, 4, 5], [0, 1, 0]);

      // 2. Dispute market 4 only
      await usdt.connect(disputer).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(disputer).disputeOutcome(4);

      expect((await router.getProposal(4)).status).to.equal(2); // DISPUTED

      // 3. Council resolves market 4
      await router.connect(council).councilResolve(4, 1);
      expect((await router.getProposal(4)).status).to.equal(3); // FINALIZED
      expect((await registry.getMarket(4)).finalized).to.be.true;

      // 4. Wait for dispute window and finalize markets 3, 5
      await time.increase(DISPUTE_WINDOW + 1);
      await router.finalizeOutcome(3);
      await router.finalizeOutcome(5);

      expect((await registry.getMarket(3)).finalized).to.be.true;
      expect((await registry.getMarket(5)).finalized).to.be.true;
    });
  });
});
