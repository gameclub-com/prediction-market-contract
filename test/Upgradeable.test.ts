import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));
const PROPOSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROPOSER_ROLE"));
const COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("COUNCIL_ROLE"));
const SAFETY_COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SAFETY_COUNCIL_ROLE"));
const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));
const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

const ONE = ethers.parseEther("1");

// EIP-712 type definitions
const ORDER_TYPES = {
  Order: [
    { name: "maker", type: "address" },
    { name: "marketId", type: "uint256" },
    { name: "outcomeIndex", type: "uint256" },
    { name: "side", type: "uint8" },
    { name: "amount", type: "uint256" },
    { name: "price", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "orderType", type: "uint8" },
    { name: "salt", type: "uint256" },
  ],
};

// ---------------------------------------------------------------------------
// Fixture: Deploy all contracts via UUPS proxy
// ---------------------------------------------------------------------------

async function upgradeableFixture() {
  const [deployer, relayer, admin2, alice, bob, treasury, feeCollector, marketAdmin] =
    await ethers.getSigners();

  // ── MockUSDT (not upgradeable) ──
  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();
  const usdtAddr = await usdt.getAddress();

  // ── ConditionalTokens (UUPS proxy) ──
  const CT = await ethers.getContractFactory("ConditionalTokens");
  const ct = await upgrades.deployProxy(CT, [usdtAddr, treasury.address, deployer.address], {
    kind: "uups",
    initializer: "initialize",
  });
  const ctAddr = await ct.getAddress();

  // ── MarketRegistry (UUPS proxy) ──
  const MR = await ethers.getContractFactory("MarketRegistry");
  const registry = await upgrades.deployProxy(MR, [ctAddr], {
    kind: "uups",
    initializer: "initialize",
  });
  const registryAddr = await registry.getAddress();

  // ── ExchangeCLOB (UUPS proxy) ──
  const Exchange = await ethers.getContractFactory("ExchangeCLOB");
  const exchange = await upgrades.deployProxy(
    Exchange,
    [usdtAddr, ctAddr, registryAddr, feeCollector.address, treasury.address],
    { kind: "uups", initializer: "initialize" },
  );
  const exchangeAddr = await exchange.getAddress();

  // ── CentralizedOracleRouter (UUPS proxy) ──
  const OracleRouter = await ethers.getContractFactory("CentralizedOracleRouter");
  const oracleRouter = await upgrades.deployProxy(
    OracleRouter,
    [registryAddr, usdtAddr, treasury.address],
    { kind: "uups", initializer: "initialize" },
  );
  const oracleRouterAddr = await oracleRouter.getAddress();

  // ── DepositRouter (UUPS proxy) ──
  const DR = await ethers.getContractFactory("DepositRouter");
  const depositRouter = await upgrades.deployProxy(DR, [usdtAddr, deployer.address], {
    kind: "uups",
    initializer: "initialize",
  });
  const depositRouterAddr = await depositRouter.getAddress();

  // ── Role grants ──
  await exchange.grantRole(RELAYER_ROLE, relayer.address);
  await exchange.grantRole(PAUSER_ROLE, deployer.address);
  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(RELAYER_ROLE, exchangeAddr);
  await oracleRouter.grantRole(PROPOSER_ROLE, deployer.address);
  await oracleRouter.grantRole(COUNCIL_ROLE, deployer.address);
  await oracleRouter.grantRole(SAFETY_COUNCIL_ROLE, deployer.address);
  await depositRouter.grantRole(RELAYER_ROLE, relayer.address);

  // ── Wire oracle router (2-step) ──
  await registry.proposeOracleRouter(oracleRouterAddr);
  await time.increase(86400);
  await registry.acceptOracleRouter();

  return {
    deployer, relayer, admin2, alice, bob, treasury, feeCollector, marketAdmin,
    usdt, ct, registry, exchange, oracleRouter, depositRouter,
    usdtAddr, ctAddr, registryAddr, exchangeAddr, oracleRouterAddr, depositRouterAddr,
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("UUPS Upgradeable", () => {
  // ═══════════════════════════════════════════════════════
  // DEPLOYMENT
  // ═══════════════════════════════════════════════════════

  describe("Proxy deployment", () => {
    it("deploys all 5 contracts behind UUPS proxies", async () => {
      const f = await loadFixture(upgradeableFixture);

      // Verify proxy addresses are valid contracts
      expect(await ethers.provider.getCode(f.ctAddr)).to.not.equal("0x");
      expect(await ethers.provider.getCode(f.registryAddr)).to.not.equal("0x");
      expect(await ethers.provider.getCode(f.exchangeAddr)).to.not.equal("0x");
      expect(await ethers.provider.getCode(f.oracleRouterAddr)).to.not.equal("0x");
      expect(await ethers.provider.getCode(f.depositRouterAddr)).to.not.equal("0x");
    });

    it("initializes state correctly via proxy", async () => {
      const f = await loadFixture(upgradeableFixture);

      // ConditionalTokens
      expect(await f.ct.collateralToken()).to.equal(f.usdtAddr);
      expect(await f.ct.treasury()).to.equal(f.treasury.address);

      // MarketRegistry
      expect(await f.registry.conditionalTokens()).to.equal(f.ctAddr);
      expect(await f.registry.nextMarketId()).to.equal(1);

      // ExchangeCLOB
      expect(await f.exchange.usdt()).to.equal(f.usdtAddr);
      expect(await f.exchange.conditionalTokens()).to.equal(f.ctAddr);
      expect(await f.exchange.marketRegistry()).to.equal(f.registryAddr);
      expect(await f.exchange.feeCollector()).to.equal(f.feeCollector.address);
      expect(await f.exchange.treasury()).to.equal(f.treasury.address);

      // CentralizedOracleRouter
      expect(await f.oracleRouter.marketRegistry()).to.equal(f.registryAddr);
      expect(await f.oracleRouter.bondToken()).to.equal(f.usdtAddr);
      expect(await f.oracleRouter.treasury()).to.equal(f.treasury.address);

      // DepositRouter
      expect(await f.depositRouter.usdt()).to.equal(f.usdtAddr);
    });

    it("grants admin roles correctly", async () => {
      const f = await loadFixture(upgradeableFixture);

      expect(await f.exchange.hasRole(DEFAULT_ADMIN_ROLE, f.deployer.address)).to.be.true;
      expect(await f.registry.hasRole(DEFAULT_ADMIN_ROLE, f.deployer.address)).to.be.true;
      expect(await f.oracleRouter.hasRole(DEFAULT_ADMIN_ROLE, f.deployer.address)).to.be.true;
      expect(await f.depositRouter.hasRole(DEFAULT_ADMIN_ROLE, f.deployer.address)).to.be.true;
    });
  });

  // ═══════════════════════════════════════════════════════
  // DOUBLE INITIALIZATION PREVENTION
  // ═══════════════════════════════════════════════════════

  describe("Double initialization prevention", () => {
    it("rejects re-initialization on proxy", async () => {
      const f = await loadFixture(upgradeableFixture);

      await expect(
        f.ct.initialize(f.usdtAddr, f.treasury.address, f.deployer.address)
      ).to.be.reverted;

      await expect(
        f.registry.initialize(f.ctAddr)
      ).to.be.reverted;

      await expect(
        f.exchange.initialize(
          f.usdtAddr, f.ctAddr, f.registryAddr, f.feeCollector.address, f.treasury.address
        )
      ).to.be.reverted;

      await expect(
        f.oracleRouter.initialize(f.registryAddr, f.usdtAddr, f.treasury.address)
      ).to.be.reverted;

      await expect(
        f.depositRouter.initialize(f.usdtAddr, f.deployer.address)
      ).to.be.reverted;
    });

    it("rejects initialization on implementation contract directly", async () => {
      const f = await loadFixture(upgradeableFixture);

      // Get implementation address
      const implAddr = await upgrades.erc1967.getImplementationAddress(f.exchangeAddr);
      const implContract = await ethers.getContractAt("ExchangeCLOB", implAddr);

      await expect(
        implContract.initialize(
          f.usdtAddr, f.ctAddr, f.registryAddr, f.feeCollector.address, f.treasury.address
        )
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════
  // UPGRADE AUTHORIZATION
  // ═══════════════════════════════════════════════════════

  describe("Upgrade authorization", () => {
    it("allows admin to upgrade ExchangeCLOB", async () => {
      const f = await loadFixture(upgradeableFixture);

      const ExchangeV2 = await ethers.getContractFactory("ExchangeCLOB");
      const upgraded = await upgrades.upgradeProxy(f.exchangeAddr, ExchangeV2, { kind: "uups" });
      expect(await upgraded.getAddress()).to.equal(f.exchangeAddr);
    });

    it("allows admin to upgrade MarketRegistry", async () => {
      const f = await loadFixture(upgradeableFixture);

      const MRV2 = await ethers.getContractFactory("MarketRegistry");
      const upgraded = await upgrades.upgradeProxy(f.registryAddr, MRV2, { kind: "uups" });
      expect(await upgraded.getAddress()).to.equal(f.registryAddr);
    });

    it("allows admin to upgrade ConditionalTokens", async () => {
      const f = await loadFixture(upgradeableFixture);

      const CTV2 = await ethers.getContractFactory("ConditionalTokens");
      const upgraded = await upgrades.upgradeProxy(f.ctAddr, CTV2, { kind: "uups" });
      expect(await upgraded.getAddress()).to.equal(f.ctAddr);
    });

    it("rejects upgrade from non-admin on ExchangeCLOB", async () => {
      const f = await loadFixture(upgradeableFixture);

      const ExchangeV2 = await ethers.getContractFactory("ExchangeCLOB", f.alice);
      await expect(
        upgrades.upgradeProxy(f.exchangeAddr, ExchangeV2, { kind: "uups" })
      ).to.be.reverted;
    });

    it("rejects upgrade from non-admin on ConditionalTokens", async () => {
      const f = await loadFixture(upgradeableFixture);

      const CTV2 = await ethers.getContractFactory("ConditionalTokens", f.alice);
      await expect(
        upgrades.upgradeProxy(f.ctAddr, CTV2, { kind: "uups" })
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════
  // STATE PRESERVATION ACROSS UPGRADE
  // ═══════════════════════════════════════════════════════

  describe("State preservation after upgrade", () => {
    it("preserves ExchangeCLOB state after upgrade", async () => {
      const f = await loadFixture(upgradeableFixture);

      // Set some state
      await f.exchange.setFeeCollector(f.alice.address);
      expect(await f.exchange.feeCollector()).to.equal(f.alice.address);

      // Upgrade
      const ExchangeV2 = await ethers.getContractFactory("ExchangeCLOB");
      const upgraded = await upgrades.upgradeProxy(f.exchangeAddr, ExchangeV2, { kind: "uups" });

      // Verify state preserved
      expect(await upgraded.feeCollector()).to.equal(f.alice.address);
      expect(await upgraded.hasRole(RELAYER_ROLE, f.relayer.address)).to.be.true;
      expect(await upgraded.usdt()).to.equal(f.usdtAddr);
      expect(await upgraded.conditionalTokens()).to.equal(f.ctAddr);
      expect(await upgraded.marketRegistry()).to.equal(f.registryAddr);
    });

    it("preserves MarketRegistry state (markets, profiles) after upgrade", async () => {
      const f = await loadFixture(upgradeableFixture);

      // Create a profile and market
      const profileHash = ethers.keccak256(ethers.toUtf8Bytes("test-profile"));
      await f.registry.setProfile(profileHash, 500, ONE, ONE, 3600, 0, 0, false);

      const now = await time.latest();
      await f.registry.connect(f.marketAdmin).createMarket({
        questionId: ethers.keccak256(ethers.toUtf8Bytes("test-q")),
        endTime: now + 86400,
        profileHash,
        tags: ["test"],
        cutoff: now + 86400 - 3600,
        outcomeSlotCount: 2,
        collateralPerSet: 0,
      });

      const marketBefore = await f.registry.getMarket(1);
      expect(marketBefore.exists).to.be.true;

      // Upgrade
      const MRV2 = await ethers.getContractFactory("MarketRegistry");
      const upgraded = await upgrades.upgradeProxy(f.registryAddr, MRV2, { kind: "uups" });

      // Verify state preserved
      const marketAfter = await upgraded.getMarket(1);
      expect(marketAfter.exists).to.be.true;
      expect(marketAfter.questionId).to.equal(marketBefore.questionId);
      expect(await upgraded.nextMarketId()).to.equal(2);
    });
  });

  // ═══════════════════════════════════════════════════════
  // EIP-712 SIGNATURE COMPATIBILITY
  // ═══════════════════════════════════════════════════════

  describe("EIP-712 signature compatibility", () => {
    it("ExchangeCLOB EIP-712 domain is correct after proxy deployment", async () => {
      const f = await loadFixture(upgradeableFixture);

      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub Exchange",
        version: "1",
        chainId: network.chainId,
        verifyingContract: f.exchangeAddr,
      };

      const order = {
        maker: f.alice.address,
        marketId: 1,
        outcomeIndex: 0,
        side: 0,
        amount: ethers.parseEther("100"),
        price: ethers.parseEther("0.6"),
        nonce: 1,
        deadline: Math.floor(Date.now() / 1000) + 86400,
        orderType: 0,
        salt: 1,
      };

      // Sign with alice
      const sig = await f.alice.signTypedData(domain, ORDER_TYPES, order);

      // Verify via hashOrder (should produce the same digest)
      const digest = await f.exchange.hashOrder(order);
      expect(digest).to.not.equal(ethers.ZeroHash);

      // Verify the signature recovers to alice
      const recovered = ethers.verifyTypedData(domain, ORDER_TYPES, order, sig);
      expect(recovered).to.equal(f.alice.address);
    });

    it("EIP-712 signatures remain valid after ExchangeCLOB upgrade", async () => {
      const f = await loadFixture(upgradeableFixture);

      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub Exchange",
        version: "1",
        chainId: network.chainId,
        verifyingContract: f.exchangeAddr,
      };

      const order = {
        maker: f.alice.address,
        marketId: 1,
        outcomeIndex: 0,
        side: 0,
        amount: ethers.parseEther("100"),
        price: ethers.parseEther("0.6"),
        nonce: 1,
        deadline: Math.floor(Date.now() / 1000) + 86400,
        orderType: 0,
        salt: 42,
      };

      // Sign before upgrade
      const sig = await f.alice.signTypedData(domain, ORDER_TYPES, order);
      const digestBefore = await f.exchange.hashOrder(order);

      // Upgrade
      const ExchangeV2 = await ethers.getContractFactory("ExchangeCLOB");
      const upgraded = await upgrades.upgradeProxy(f.exchangeAddr, ExchangeV2, { kind: "uups" });

      // Verify digest is the same after upgrade
      const digestAfter = await upgraded.hashOrder(order);
      expect(digestAfter).to.equal(digestBefore);

      // Verify signature still valid
      const recovered = ethers.verifyTypedData(domain, ORDER_TYPES, order, sig);
      expect(recovered).to.equal(f.alice.address);
    });

    it("DepositRouter domain separator is correct after proxy deployment", async () => {
      const f = await loadFixture(upgradeableFixture);

      const ds = await f.depositRouter.domainSeparator();
      expect(ds).to.not.equal(ethers.ZeroHash);

      // Compute expected domain separator
      const network = await ethers.provider.getNetwork();
      const expected = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "bytes32", "uint256", "address"],
          [
            ethers.keccak256(ethers.toUtf8Bytes("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")),
            ethers.keccak256(ethers.toUtf8Bytes("GameClub DepositRouter")),
            ethers.keccak256(ethers.toUtf8Bytes("1")),
            network.chainId,
            f.depositRouterAddr,
          ]
        )
      );

      expect(ds).to.equal(expected);
    });
  });

  // ═══════════════════════════════════════════════════════
  // FUNCTIONAL TESTS VIA PROXY
  // ═══════════════════════════════════════════════════════

  describe("Functional tests via proxy", () => {
    it("ConditionalTokens: split and merge via proxy", async () => {
      const f = await loadFixture(upgradeableFixture);

      // Prepare a condition
      const questionId = ethers.keccak256(ethers.toUtf8Bytes("test-condition"));
      await f.ct.prepareCondition(f.deployer.address, questionId, 2);

      const conditionId = await f.ct.getConditionId(f.deployer.address, questionId, 2);

      // Mint USDT to alice and approve
      await f.usdt.mint(f.alice.address, ethers.parseEther("1000"));
      await f.usdt.connect(f.alice).approve(f.ctAddr, ethers.parseEther("1000"));

      // Split
      await f.ct.connect(f.alice).splitPosition(conditionId, ethers.parseEther("100"));

      // Check balance
      const posId0 = await f.ct.getPositionId(
        f.usdtAddr,
        await f.ct.getCollectionId(conditionId, 1)
      );
      expect(await f.ct.balanceOf(f.alice.address, posId0)).to.equal(ethers.parseEther("100"));

      // Approve CT for merge
      await f.ct.connect(f.alice).setApprovalForAll(f.ctAddr, true);

      // Merge
      await f.ct.connect(f.alice).mergePositions(conditionId, ethers.parseEther("50"));
      expect(await f.ct.balanceOf(f.alice.address, posId0)).to.equal(ethers.parseEther("50"));
    });

    it("MarketRegistry: create market via proxy", async () => {
      const f = await loadFixture(upgradeableFixture);

      const profileHash = ethers.keccak256(ethers.toUtf8Bytes("test-profile"));
      await f.registry.setProfile(profileHash, 500, ONE, ONE, 3600, 0, 0, false);

      const now = await time.latest();
      await f.registry.connect(f.marketAdmin).createMarket({
        questionId: ethers.keccak256(ethers.toUtf8Bytes("test-market")),
        endTime: now + 86400,
        profileHash,
        tags: ["test"],
        cutoff: now + 86400 - 3600,
        outcomeSlotCount: 2,
        collateralPerSet: 0,
      });

      const market = await f.registry.getMarket(1);
      expect(market.exists).to.be.true;
      expect(await f.registry.nextMarketId()).to.equal(2);
    });

    it("ExchangeCLOB: admin functions work via proxy", async () => {
      const f = await loadFixture(upgradeableFixture);

      await f.exchange.setFeeCollector(f.alice.address);
      expect(await f.exchange.feeCollector()).to.equal(f.alice.address);

      await f.exchange.emergencyStop();
      expect(await f.exchange.systemMode()).to.equal(1); // EMERGENCY_STOP

      await f.exchange.resume();
      expect(await f.exchange.systemMode()).to.equal(0); // NORMAL
    });
  });
});
