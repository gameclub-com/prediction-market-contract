/**
 * OracleRouter-AdminUI.test.ts
 *
 * Admin UI에서 proposeOutcomeBatch가 revert되는 상황을 정확히 재현하는 테스트.
 * deploy-local.ts / deploy-mainnet.ts 의 role 부여 로직과 동일한 흐름으로 셋업.
 */
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";

// ── Role hashes (deploy 스크립트와 동일) ──
const PROPOSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROPOSER_ROLE"));
const COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("COUNCIL_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));
const SAFETY_COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SAFETY_COUNCIL_ROLE"));

const DISPUTE_WINDOW = 3600;
const DISPUTE_BOND = ethers.parseEther("100");

/**
 * deploy-local.ts 와 최대한 동일한 셋업을 재현.
 * deployer = Hardhat account #0 (deploy-local.ts의 deployer)
 * adminWallet = 별도 signer (Dan의 MetaMask 지갑 0x905e93... 역할)
 */
async function adminUIFixture() {
  const [deployer, relayer, marketAdmin, adminWallet, someUser, treasury] =
    await ethers.getSigners();

  // ── Deploy contracts (deploy-local.ts 동일) ──
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

  // ── Wire oracle router (deploy-local.ts: 2-step) ──
  await registry.proposeOracleRouter(await router.getAddress());
  await time.increase(86400);
  await registry.acceptOracleRouter();

  // ── Grant roles — deploy-local.ts 원본 로직 ──
  // deploy-local.ts:128-131 에서:
  //   grantRole(PROPOSER_ROLE, deployer)
  //   grantRole(COUNCIL_ROLE, deployer)
  //   grantRole(COUNCIL_ROLE, relayer)
  await router.grantRole(PROPOSER_ROLE, deployer.address);
  await router.grantRole(COUNCIL_ROLE, deployer.address);
  await router.grantRole(COUNCIL_ROLE, relayer.address);

  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(SAFETY_COUNCIL_ROLE, deployer.address);

  // ── Profile: dispute enabled ──
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("dispute-enabled"));
  await registry.setProfile(
    profileHash, 500, ethers.parseEther("10000"), ethers.parseEther("1000000"),
    3600, DISPUTE_WINDOW, DISPUTE_BOND, true,
  );

  // ── Profile: no disputes ──
  const noDisputeProfile = ethers.keccak256(ethers.toUtf8Bytes("no-dispute"));
  await registry.setProfile(
    noDisputeProfile, 500, ethers.parseEther("10000"), ethers.parseEther("1000000"),
    3600, 0, 0, false,
  );

  // ── Create markets (admin API createMarket 과정 재현) ──
  const now = await time.latest();
  const CUTOFF = now + 3600;       // 1시간 후 cutoff
  const END_TIME = now + 7200;     // 2시간 후 종료

  // Market 1: dispute enabled
  await registry.connect(marketAdmin).createMarket({
    questionId: ethers.keccak256(ethers.toUtf8Bytes("BTC > 100k by March 2026?")),
    endTime: END_TIME,
    profileHash,
    tags: ["crypto"],
    cutoff: CUTOFF,
    outcomeSlotCount: 2,
    collateralPerSet: 0,
  });

  // Market 2: no dispute
  await registry.connect(marketAdmin).createMarket({
    questionId: ethers.keccak256(ethers.toUtf8Bytes("ETH > 5k?")),
    endTime: END_TIME,
    profileHash: noDisputeProfile,
    tags: ["crypto"],
    cutoff: CUTOFF,
    outcomeSlotCount: 2,
    collateralPerSet: 0,
  });

  return {
    deployer, relayer, marketAdmin, adminWallet, someUser, treasury,
    usdt, ct, registry, router,
    profileHash, noDisputeProfile,
    CUTOFF, END_TIME,
  };
}

describe("Admin UI proposeOutcomeBatch — Reproduction", function () {

  // ═══════════════════════════════════════════════════════════════
  // 1. PROPOSER_ROLE 미부여 상태에서 adminWallet이 호출
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 1: adminWallet에 PROPOSER_ROLE 없음", function () {
    it("proposeOutcomeBatch가 AccessControl 에러로 revert", async function () {
      const { adminWallet, router } = await loadFixture(adminUIFixture);

      // adminWallet에는 PROPOSER_ROLE이 없음 (deploy 스크립트 원본 상태)
      const hasRole = await router.hasRole(PROPOSER_ROLE, adminWallet.address);
      expect(hasRole).to.be.false;

      // cutoff 지남
      await time.increase(3601);

      await expect(
        router.connect(adminWallet).proposeOutcomeBatch([1], [0]),
      ).to.be.reverted;
    });

    it("revert 메시지에 AccessControlUnauthorizedAccount 포함", async function () {
      const { adminWallet, router } = await loadFixture(adminUIFixture);
      await time.increase(3601);

      await expect(
        router.connect(adminWallet).proposeOutcomeBatch([1], [0]),
      ).to.be.revertedWithCustomError(
        router,
        "AccessControlUnauthorizedAccount",
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 2. PROPOSER_ROLE 부여 후 — cutoff 이전에 호출
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 2: PROPOSER_ROLE 있지만 market 아직 종료 안됨", function () {
    it("Market not yet ended 로 revert", async function () {
      const { deployer, adminWallet, router } = await loadFixture(adminUIFixture);

      // ORACLE_ADMIN_WALLETS 효과: role 부여
      await router.connect(deployer).grantRole(PROPOSER_ROLE, adminWallet.address);

      // 시간 안 넘김 — cutoff 이전
      await expect(
        router.connect(adminWallet).proposeOutcomeBatch([1], [0]),
      ).to.be.revertedWith("Market not yet ended or cutoff not reached");
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 3. PROPOSER_ROLE 부여 + cutoff 지남 — 정상 성공
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 3: 모든 조건 충족 — 정상 동작", function () {
    it("proposeOutcomeBatch 성공", async function () {
      const { deployer, adminWallet, router, registry } = await loadFixture(adminUIFixture);

      await router.connect(deployer).grantRole(PROPOSER_ROLE, adminWallet.address);
      await time.increase(3601); // cutoff 지남

      await router.connect(adminWallet).proposeOutcomeBatch([1, 2], [0, 1]);

      // Market 1: dispute enabled → PROPOSED
      const p1 = await router.getProposal(1);
      expect(p1.status).to.equal(1); // PROPOSED

      // Market 2: no dispute → FINALIZED
      const p2 = await router.getProposal(2);
      expect(p2.status).to.equal(3); // FINALIZED
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 4. 이미 propose 된 마켓에 다시 propose
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 4: 이미 proposed된 마켓에 재호출", function () {
    it("ProposalAlreadyExists로 revert", async function () {
      const { deployer, adminWallet, router } = await loadFixture(adminUIFixture);

      await router.connect(deployer).grantRole(PROPOSER_ROLE, adminWallet.address);
      await time.increase(3601);

      // 첫 번째 호출 성공
      await router.connect(adminWallet).proposeOutcomeBatch([1], [0]);

      // 두 번째 호출 — 이미 exists
      await expect(
        router.connect(adminWallet).proposeOutcomeBatch([1], [0]),
      ).to.be.revertedWithCustomError(router, "ProposalAlreadyExists");
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 5. 존재하지 않는 marketId
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 5: 존재하지 않는 marketId", function () {
    it("getMarket가 빈 struct → endTime=0 → cutoff=0 → 통과하지만 setResolved에서 실패 가능", async function () {
      const { deployer, adminWallet, router } = await loadFixture(adminUIFixture);

      await router.connect(deployer).grantRole(PROPOSER_ROLE, adminWallet.address);
      await time.increase(3601);

      // marketId 999는 존재하지 않음 — 어떻게 revert되는지 확인
      await expect(
        router.connect(adminWallet).proposeOutcomeBatch([999], [0]),
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 6. outcomeIndex가 잘못된 경우
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 6: outcomeIndex > 1", function () {
    it("InvalidOutcome 으로 revert", async function () {
      const { deployer, adminWallet, router } = await loadFixture(adminUIFixture);

      await router.connect(deployer).grantRole(PROPOSER_ROLE, adminWallet.address);
      await time.increase(3601);

      await expect(
        router.connect(adminWallet).proposeOutcomeBatch([1], [2]),
      ).to.be.revertedWithCustomError(router, "InvalidOutcome");
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 7. Full E2E: propose → dispute → council resolve (admin wallet 전체 흐름)
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 7: Admin UI 전체 E2E", function () {
    it("adminWallet propose → user dispute → council resolve", async function () {
      const { deployer, adminWallet, someUser, router, registry, usdt } =
        await loadFixture(adminUIFixture);

      // Setup: role 부여 + USDT 민트
      await router.connect(deployer).grantRole(PROPOSER_ROLE, adminWallet.address);
      await router.connect(deployer).grantRole(COUNCIL_ROLE, adminWallet.address);
      await usdt.mint(someUser.address, ethers.parseEther("1000"));
      await time.increase(3601);

      // Step 1: Admin UI에서 proposeOutcomeBatch 호출
      await router.connect(adminWallet).proposeOutcomeBatch([1], [0]);
      const p1 = await router.getProposal(1);
      expect(p1.status).to.equal(1); // PROPOSED
      expect(p1.outcomeIndex).to.equal(0);

      // Step 2: User가 dispute 제기 (approve + disputeOutcome)
      await usdt.connect(someUser).approve(await router.getAddress(), DISPUTE_BOND);
      await router.connect(someUser).disputeOutcome(1);
      const p2 = await router.getProposal(1);
      expect(p2.status).to.equal(2); // DISPUTED

      // Step 3: Admin이 council resolve
      await router.connect(adminWallet).councilResolve(1, 0);
      const p3 = await router.getProposal(1);
      expect(p3.status).to.equal(3); // FINALIZED

      const market = await registry.getMarket(1);
      expect(market.finalized).to.be.true;
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 8. deploy-local.ts 의 ORACLE_ADMIN_WALLETS 환경변수 시뮬레이션
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 8: ORACLE_ADMIN_WALLETS env var 시뮬레이션", function () {
    it("env var로 role 부여 → proposeOutcomeBatch 성공", async function () {
      const { deployer, adminWallet, router } = await loadFixture(adminUIFixture);

      // deploy 스크립트에서 ORACLE_ADMIN_WALLETS 처리하는 로직 재현:
      const envValue = adminWallet.address; // "0x905e9383..." 같은 값
      const extraAdmins = envValue.split(",").map(s => s.trim()).filter(Boolean);
      for (const addr of extraAdmins) {
        await router.connect(deployer).grantRole(PROPOSER_ROLE, addr);
        await router.connect(deployer).grantRole(COUNCIL_ROLE, addr);
      }

      // role 확인
      expect(await router.hasRole(PROPOSER_ROLE, adminWallet.address)).to.be.true;
      expect(await router.hasRole(COUNCIL_ROLE, adminWallet.address)).to.be.true;

      // cutoff 지남
      await time.increase(3601);

      // 성공해야 함
      await router.connect(adminWallet).proposeOutcomeBatch([1], [0]);
      const p = await router.getProposal(1);
      expect(p.status).to.equal(1);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 9. emergencyResolveBatch — cutoff 이전 다수 마켓 단일 tx 해소
  // ═══════════════════════════════════════════════════════════════
  describe("Scenario 9: emergencyResolveBatch", function () {
    async function multiMarketFixture() {
      const base = await loadFixture(adminUIFixture);
      const { deployer, adminWallet, registry, router, marketAdmin } = base;

      // adminWallet에 SAFETY_COUNCIL_ROLE 부여
      await router.connect(deployer).grantRole(SAFETY_COUNCIL_ROLE, adminWallet.address);

      // 추가 마켓 3개 생성 (market 3, 4, 5)
      const now = await time.latest();
      const profileHash = base.profileHash;
      for (let i = 0; i < 3; i++) {
        const qid = ethers.keccak256(ethers.toUtf8Bytes(`emergency-batch-${i}`));
        await registry.connect(marketAdmin).createMarket({
          questionId: qid,
          endTime: now + 7200,
          profileHash,
          tags: ["test"],
          cutoff: now + 3600,
          outcomeSlotCount: 2,
          collateralPerSet: 0,
        });
      }

      return base;
    }

    it("cutoff 이전 5개 마켓을 단일 트랜잭션으로 해소", async function () {
      const { adminWallet, router, registry } = await multiMarketFixture();

      // cutoff 안 넘김 — proposeOutcomeBatch는 실패할 상황
      await expect(
        router.connect(adminWallet).proposeOutcomeBatch([1, 2, 3, 4, 5], [0, 1, 0, 1, 0]),
      ).to.be.reverted;

      // emergencyResolveBatch는 성공
      await router.connect(adminWallet).emergencyResolveBatch(
        [1, 2, 3, 4, 5],
        [0, 1, 0, 1, 0],
      );

      // 모든 마켓 finalized 확인
      for (const id of [1, 2, 3, 4, 5]) {
        const proposal = await router.getProposal(id);
        expect(proposal.status).to.equal(3); // FINALIZED

        const market = await registry.getMarket(id);
        expect(market.resolved).to.be.true;
        expect(market.finalized).to.be.true;
      }
    });

    it("빈 배열로 호출 시 revert", async function () {
      const { adminWallet, router } = await multiMarketFixture();
      await expect(
        router.connect(adminWallet).emergencyResolveBatch([], []),
      ).to.be.revertedWith("Empty batch");
    });

    it("배열 길이 불일치 시 revert", async function () {
      const { adminWallet, router } = await multiMarketFixture();
      await expect(
        router.connect(adminWallet).emergencyResolveBatch([1, 2], [0]),
      ).to.be.revertedWith("Array length mismatch");
    });

    it("SAFETY_COUNCIL_ROLE 없으면 revert", async function () {
      const { someUser, router } = await multiMarketFixture();
      await expect(
        router.connect(someUser).emergencyResolveBatch([1], [0]),
      ).to.be.reverted;
    });

    it("이미 finalized된 마켓 포함 시 전체 batch revert", async function () {
      const { adminWallet, router } = await multiMarketFixture();

      // 마켓 1 먼저 해소
      await router.connect(adminWallet).emergencyResolve(1, 0);

      // 마켓 1 포함한 batch → ProposalAlreadyExists
      await expect(
        router.connect(adminWallet).emergencyResolveBatch([1, 2], [0, 1]),
      ).to.be.revertedWithCustomError(router, "ProposalAlreadyExists");
    });
  });
});
