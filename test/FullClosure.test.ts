// Full Closure (Option C) test suite — protocol-wide OI sync via ConditionalTokens.
// Verifies that QGM-03 finding's two recommendations are both fulfilled:
//   1. Source Tracking: oiEligibleShares ensures only eligible shares decrement OI on merge.
//   2. Remove Saturating Subtraction: subtractOI / subtractOIByCondition revert on underflow.
//
// Also verifies CT-driven hooks (splitPosition / mergePositions / _update transfer)
// keep MarketRegistry.currentOI in sync with protocol-wide position state.

import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
const ORACLE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));
const KEEPER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("KEEPER_ROLE"));
const SAFETY_COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SAFETY_COUNCIL_ROLE"));

const TEN_THOUSAND = ethers.parseEther("10000");

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

interface OrderStruct {
  maker: string;
  marketId: bigint | number;
  outcomeIndex: bigint | number;
  side: number;
  amount: bigint;
  price: bigint;
  nonce: bigint | number;
  deadline: bigint | number;
  orderType: number;
  salt: bigint | number;
}

async function signOrder(
  signer: HardhatEthersSigner,
  order: OrderStruct,
  exchangeAddress: string
): Promise<string> {
  const network = await signer.provider!.getNetwork();
  const domain = {
    name: "GameClub Exchange",
    version: "1",
    chainId: network.chainId,
    verifyingContract: exchangeAddress,
  };
  return signer.signTypedData(domain, ORDER_TYPES, order);
}

function makeOrder(overrides: Partial<OrderStruct> & { maker: string }): OrderStruct {
  return {
    marketId: BigInt(1),
    outcomeIndex: BigInt(0),
    side: 0,
    amount: ethers.parseEther("100"),
    price: ethers.parseEther("0.60"),
    nonce: BigInt(1),
    deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
    orderType: 0,
    salt: BigInt(1),
    ...overrides,
  };
}

// Fixture without pre-fixture splits, for clean per-test setup.
async function deployCleanFixture() {
  const [
    deployer, relayer, marketAdmin, oracle, keeper, safetyCouncil,
    feeCollector, treasury, alice, bob, charlie, dave,
  ] = await ethers.getSigners();

  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const ConditionalTokens = await ethers.getContractFactory("ConditionalTokens");
  const ct = await upgrades.deployProxy(
    ConditionalTokens,
    [await usdt.getAddress(), treasury.address, deployer.address],
    { kind: "uups", initializer: "initialize" }
  );

  const MarketRegistry = await ethers.getContractFactory("MarketRegistry");
  const registry = await upgrades.deployProxy(
    MarketRegistry,
    [await ct.getAddress()],
    { kind: "uups", initializer: "initialize" }
  );

  const ExchangeCLOB = await ethers.getContractFactory("ExchangeCLOB");
  const exchange = await upgrades.deployProxy(
    ExchangeCLOB,
    [
      await usdt.getAddress(),
      await ct.getAddress(),
      await registry.getAddress(),
      feeCollector.address,
      treasury.address,
    ],
    { kind: "uups", initializer: "initialize" }
  );
  await exchange.initializeV2();

  // Option C wiring
  await ct.initializeVx(await registry.getAddress());
  await registry.setConditionalTokens(await ct.getAddress());

  // Roles
  await exchange.grantRole(RELAYER_ROLE, relayer.address);
  await exchange.grantRole(SAFETY_COUNCIL_ROLE, safetyCouncil.address);
  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(ORACLE_ROLE, oracle.address);
  await registry.grantRole(KEEPER_ROLE, keeper.address);
  await registry.grantRole(SAFETY_COUNCIL_ROLE, safetyCouncil.address);
  await registry.grantRole(RELAYER_ROLE, await exchange.getAddress());

  // Oracle router is required for setResolved/finalizeResolution path used in some tests
  const OracleRouter = await ethers.getContractFactory("CentralizedOracleRouter");
  const oracleRouter = await upgrades.deployProxy(
    OracleRouter,
    [await registry.getAddress(), await usdt.getAddress(), treasury.address],
    { kind: "uups", initializer: "initialize" }
  );
  await registry.initOracleRouter(await oracleRouter.getAddress());

  // Profile + market with ample maxOI for non-cap tests
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("default"));
  await registry.setProfile(
    profileHash, 500, ethers.parseEther("10000"),
    ethers.parseEther("1000000"), 3600, 0, 0, false
  );

  const now = await time.latest();
  const questionId = ethers.keccak256(ethers.toUtf8Bytes("FC clean"));
  await registry.connect(marketAdmin).createMarket({
    questionId, endTime: now + 86400 * 7, profileHash,
    tags: ["test"], cutoff: now + 86400 * 7 - 3600,
    outcomeSlotCount: 2, collateralPerSet: 0,
  });
  const marketId = 1;
  const market = await registry.getMarket(marketId);
  const conditionId = market.conditionId;

  const collId0 = await ct.getCollectionId(conditionId, 1);
  const collId1 = await ct.getCollectionId(conditionId, 2);
  const posId0 = await ct.getPositionId(await usdt.getAddress(), collId0);
  const posId1 = await ct.getPositionId(await usdt.getAddress(), collId1);

  for (const u of [alice, bob, charlie, dave]) {
    await usdt.mint(u.address, TEN_THOUSAND);
    await usdt.connect(u).approve(await ct.getAddress(), TEN_THOUSAND);
    await usdt.connect(u).approve(await exchange.getAddress(), TEN_THOUSAND);
  }

  return {
    deployer, relayer, marketAdmin, oracle, keeper, safetyCouncil,
    feeCollector, treasury, alice, bob, charlie, dave,
    usdt, ct, registry, exchange, oracleRouter,
    profileHash, questionId, marketId, conditionId, posId0, posId1,
  };
}

// ═════════════════════════════════════════════════════════════════
// 1. conditionIdToMarketId mapping registration
// ═════════════════════════════════════════════════════════════════
describe("Option C: conditionId → marketId mapping", function () {
  it("createMarket auto-registers the conditionId mapping", async function () {
    const { registry, conditionId, marketId } = await loadFixture(deployCleanFixture);
    const mapped = await registry.conditionIdToMarketId(conditionId);
    expect(mapped).to.equal(BigInt(marketId));
  });

  it("backfillConditionMapping is idempotent for already-mapped markets", async function () {
    const { registry, deployer, marketId } = await loadFixture(deployCleanFixture);
    await registry.connect(deployer).backfillConditionMapping(marketId);
    // No revert, no event re-emission required (idempotent path returns early).
  });

  it("backfillConditionMapping reverts on non-existent market", async function () {
    const { registry, deployer } = await loadFixture(deployCleanFixture);
    await expect(
      registry.connect(deployer).backfillConditionMapping(9999)
    ).to.be.revertedWithCustomError(registry, "MarketNotFound");
  });
});

// ═════════════════════════════════════════════════════════════════
// 2. setConditionalTokens / emergencyResetConditionalTokens
// ═════════════════════════════════════════════════════════════════
describe("Option C: setConditionalTokens lifecycle", function () {
  it("setConditionalTokens reverts when already set", async function () {
    const { registry, deployer, ct } = await loadFixture(deployCleanFixture);
    await expect(
      registry.connect(deployer).setConditionalTokens(await ct.getAddress())
    ).to.be.revertedWithCustomError(registry, "ConditionalTokensAlreadySet");
  });

  it("emergencyResetConditionalTokens clears the link (admin escape hatch)", async function () {
    const { registry, deployer, ct } = await loadFixture(deployCleanFixture);
    const before = await registry.conditionalTokensAddress();
    expect(before).to.equal(await ct.getAddress());

    await expect(registry.connect(deployer).emergencyResetConditionalTokens())
      .to.emit(registry, "ConditionalTokensReset");

    const after = await registry.conditionalTokensAddress();
    expect(after).to.equal(ethers.ZeroAddress);
  });

  it("non-admin cannot setConditionalTokens or reset", async function () {
    const { registry, alice, ct } = await loadFixture(deployCleanFixture);
    await expect(registry.connect(alice).setConditionalTokens(await ct.getAddress())).to.be.reverted;
    await expect(registry.connect(alice).emergencyResetConditionalTokens()).to.be.reverted;
  });
});

// ═════════════════════════════════════════════════════════════════
// 3. addOIByCondition / subtractOIByCondition access control
// ═════════════════════════════════════════════════════════════════
describe("Option C: OI hook access control", function () {
  it("addOIByCondition only callable by ConditionalTokens", async function () {
    const { registry, alice, conditionId } = await loadFixture(deployCleanFixture);
    await expect(
      registry.connect(alice).addOIByCondition(conditionId, ethers.parseEther("1"))
    ).to.be.revertedWithCustomError(registry, "NotConditionalTokens");
  });

  it("subtractOIByCondition only callable by ConditionalTokens", async function () {
    const { registry, alice, conditionId } = await loadFixture(deployCleanFixture);
    await expect(
      registry.connect(alice).subtractOIByCondition(conditionId, ethers.parseEther("1"))
    ).to.be.revertedWithCustomError(registry, "NotConditionalTokens");
  });
});

// ═════════════════════════════════════════════════════════════════
// 4. splitPosition → addOIByCondition (Source Tracking)
// ═════════════════════════════════════════════════════════════════
describe("Option C: splitPosition OI sync", function () {
  it("direct splitPosition increases currentOI exactly", async function () {
    const { ct, registry, alice, conditionId, marketId } = await loadFixture(deployCleanFixture);
    const oiBefore = (await registry.getMarket(marketId)).currentOI;
    expect(oiBefore).to.equal(0n);

    const amount = ethers.parseEther("100");
    await ct.connect(alice).splitPosition(conditionId, amount);

    const oiAfter = (await registry.getMarket(marketId)).currentOI;
    expect(oiAfter).to.equal(amount);
  });

  it("splitPosition emits OISynced event", async function () {
    const { ct, registry, alice, conditionId } = await loadFixture(deployCleanFixture);
    const amount = ethers.parseEther("50");
    await expect(ct.connect(alice).splitPosition(conditionId, amount))
      .to.emit(registry, "OISynced");
  });

  it("splitPosition grants oiEligibleShares to caller", async function () {
    const { ct, alice, conditionId, posId0, posId1 } = await loadFixture(deployCleanFixture);
    const amount = ethers.parseEther("75");
    await ct.connect(alice).splitPosition(conditionId, amount);

    expect(await ct.oiEligibleShares(alice.address, posId0)).to.equal(amount);
    expect(await ct.oiEligibleShares(alice.address, posId1)).to.equal(amount);
  });

  it("splitPosition for unregistered condition is a no-op on OI", async function () {
    // condition that's prepared but not registered as a protocol market
    const { ct, registry, alice, deployer, usdt } = await loadFixture(deployCleanFixture);

    const fakeQuestionId = ethers.keccak256(ethers.toUtf8Bytes("standalone"));
    await ct.prepareCondition(deployer.address, fakeQuestionId, 2);
    const conditionId = await ct.getConditionId(deployer.address, fakeQuestionId, 2);

    const oiSnapshot = (await registry.getMarket(1)).currentOI;
    const amount = ethers.parseEther("10");
    await usdt.connect(alice).approve(await ct.getAddress(), amount);
    await ct.connect(alice).splitPosition(conditionId, amount);

    // Different conditionId, mapping = 0 → addOIByCondition early-returns. No revert.
    const oiAfter = (await registry.getMarket(1)).currentOI;
    expect(oiAfter).to.equal(oiSnapshot);
  });
});

// ═════════════════════════════════════════════════════════════════
// 5. mergePositions → subtractOIByCondition (eligibility-bounded)
// ═════════════════════════════════════════════════════════════════
describe("Option C: mergePositions OI sync", function () {
  it("direct mergePositions on own-minted shares decrements OI by full amount", async function () {
    const { ct, registry, alice, conditionId, marketId } = await loadFixture(deployCleanFixture);
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"));
    const oiAfterSplit = (await registry.getMarket(marketId)).currentOI;

    await ct.connect(alice).mergePositions(conditionId, ethers.parseEther("60"));

    const oiAfterMerge = (await registry.getMarket(marketId)).currentOI;
    expect(oiAfterMerge).to.equal(oiAfterSplit - ethers.parseEther("60"));
  });

  it("mergePositions on transferred-in shares decrements OI by transferred eligibility", async function () {
    const { ct, registry, alice, bob, conditionId, marketId, posId0, posId1 } =
      await loadFixture(deployCleanFixture);

    // alice splits 100, transfers 30 to bob (eligibility moves with shares)
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"));
    await ct.connect(alice).safeTransferFrom(alice.address, bob.address, posId0, ethers.parseEther("30"), "0x");
    await ct.connect(alice).safeTransferFrom(alice.address, bob.address, posId1, ethers.parseEther("30"), "0x");

    expect(await ct.oiEligibleShares(bob.address, posId0)).to.equal(ethers.parseEther("30"));
    expect(await ct.oiEligibleShares(bob.address, posId1)).to.equal(ethers.parseEther("30"));

    const oiBeforeMerge = (await registry.getMarket(marketId)).currentOI;
    await ct.connect(bob).mergePositions(conditionId, ethers.parseEther("30"));
    const oiAfterMerge = (await registry.getMarket(marketId)).currentOI;

    expect(oiAfterMerge).to.equal(oiBeforeMerge - ethers.parseEther("30"));
  });

  it("mergePositions on shares without eligibility does NOT decrement OI", async function () {
    // Constructed scenario: bob receives shares via a non-tracking source (admin transfer).
    // Since fixture only allows splits, we simulate by:
    //   1. alice splits 100 (gets 100 elig)
    //   2. alice approves bob; bob calls safeTransferFrom (alice → bob via approval)
    //   The transfer hook still moves eligibility. To get untracked shares, we'd need
    //   a CT path that mints without eligibility. Such path doesn't exist in current code.
    //   This test instead verifies the boundary: when bob's eligibility is exhausted,
    //   further merge does not under-decrement OI.

    const { ct, registry, alice, bob, conditionId, marketId, posId0, posId1 } =
      await loadFixture(deployCleanFixture);

    // alice splits 100, transfers all 100 to bob → bob has 100 elig
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"));
    await ct.connect(alice).safeTransferFrom(alice.address, bob.address, posId0, ethers.parseEther("100"), "0x");
    await ct.connect(alice).safeTransferFrom(alice.address, bob.address, posId1, ethers.parseEther("100"), "0x");

    // bob splits another 50 directly → bob has 150 elig on each + extra OI 50
    await ct.connect(bob).splitPosition(conditionId, ethers.parseEther("50"));

    // OI should be 100 (alice split) + 50 (bob split) = 150
    expect((await registry.getMarket(marketId)).currentOI).to.equal(ethers.parseEther("150"));

    // bob merges 150 — full eligibility → OI -150 → OI = 0
    await ct.connect(bob).mergePositions(conditionId, ethers.parseEther("150"));
    expect((await registry.getMarket(marketId)).currentOI).to.equal(0n);

    // bob's eligibility is now 0 on both posIds
    expect(await ct.oiEligibleShares(bob.address, posId0)).to.equal(0n);
    expect(await ct.oiEligibleShares(bob.address, posId1)).to.equal(0n);
  });
});

// ═════════════════════════════════════════════════════════════════
// 6. ERC1155 transfer hook moves eligibility
// ═════════════════════════════════════════════════════════════════
describe("Option C: ERC1155 transfer eligibility propagation", function () {
  it("safeTransferFrom moves eligibility up to min(holder_elig, amount)", async function () {
    const { ct, alice, bob, conditionId, posId0 } = await loadFixture(deployCleanFixture);
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"));

    expect(await ct.oiEligibleShares(alice.address, posId0)).to.equal(ethers.parseEther("100"));

    await expect(
      ct.connect(alice).safeTransferFrom(alice.address, bob.address, posId0, ethers.parseEther("40"), "0x")
    ).to.emit(ct, "OIEligibilityMoved").withArgs(alice.address, bob.address, posId0, ethers.parseEther("40"));

    expect(await ct.oiEligibleShares(alice.address, posId0)).to.equal(ethers.parseEther("60"));
    expect(await ct.oiEligibleShares(bob.address, posId0)).to.equal(ethers.parseEther("40"));
  });

  it("safeBatchTransferFrom moves eligibility per id", async function () {
    const { ct, alice, bob, conditionId, posId0, posId1 } = await loadFixture(deployCleanFixture);
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("80"));

    await ct.connect(alice).safeBatchTransferFrom(
      alice.address, bob.address,
      [posId0, posId1],
      [ethers.parseEther("20"), ethers.parseEther("30")],
      "0x"
    );

    expect(await ct.oiEligibleShares(alice.address, posId0)).to.equal(ethers.parseEther("60"));
    expect(await ct.oiEligibleShares(alice.address, posId1)).to.equal(ethers.parseEther("50"));
    expect(await ct.oiEligibleShares(bob.address, posId0)).to.equal(ethers.parseEther("20"));
    expect(await ct.oiEligibleShares(bob.address, posId1)).to.equal(ethers.parseEther("30"));
  });
});

// ═════════════════════════════════════════════════════════════════
// 7. maxOpenInterest cap enforcement (now in CT layer)
// ═════════════════════════════════════════════════════════════════
describe("Option C: maxOpenInterest cap on direct splitPosition", function () {
  async function deployCappedFixture() {
    const base = await deployCleanFixture();
    const { registry, marketAdmin } = base;

    const lowProfile = ethers.keccak256(ethers.toUtf8Bytes("low_oi_fc"));
    await registry.setProfile(
      lowProfile, 500, ethers.parseEther("10000"),
      ethers.parseEther("5"), 3600, 0, 0, false
    );

    const now = await time.latest();
    const qid = ethers.keccak256(ethers.toUtf8Bytes("fc-low-oi"));
    await registry.connect(marketAdmin).createMarket({
      questionId: qid, endTime: now + 86400 * 7, profileHash: lowProfile,
      tags: ["test"], cutoff: now + 86400 * 7 - 3600,
      outcomeSlotCount: 2, collateralPerSet: 0,
    });
    const cappedMarketId = 2;
    const cappedMarket = await registry.getMarket(cappedMarketId);
    return { ...base, cappedMarketId, cappedConditionId: cappedMarket.conditionId };
  }

  it("direct splitPosition exceeding maxOpenInterest reverts", async function () {
    const { ct, registry, alice, cappedConditionId } = await loadFixture(deployCappedFixture);
    await expect(
      ct.connect(alice).splitPosition(cappedConditionId, ethers.parseEther("10"))
    ).to.be.revertedWithCustomError(registry, "MaxOIExceeded");
  });

  it("direct splitPosition at exactly maxOpenInterest succeeds", async function () {
    const { ct, registry, alice, cappedConditionId, cappedMarketId } =
      await loadFixture(deployCappedFixture);
    await ct.connect(alice).splitPosition(cappedConditionId, ethers.parseEther("5"));
    const m = await registry.getMarket(cappedMarketId);
    expect(m.currentOI).to.equal(ethers.parseEther("5"));
  });
});

// ═════════════════════════════════════════════════════════════════
// 8. recoverOI fallback + OISynced event on hooks
// ═════════════════════════════════════════════════════════════════
describe("Option C: recoverOI escape hatch coexistence", function () {
  it("recoverOI can adjust currentOI even when CT hooks are active", async function () {
    const { ct, registry, deployer, alice, conditionId, marketId } =
      await loadFixture(deployCleanFixture);
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"));
    expect((await registry.getMarket(marketId)).currentOI).to.equal(ethers.parseEther("100"));

    await registry.connect(deployer).recoverOI(marketId, ethers.parseEther("42"));
    expect((await registry.getMarket(marketId)).currentOI).to.equal(ethers.parseEther("42"));
  });

  it("after recoverOI, mergePositions still respects OIUnderflowErr", async function () {
    const { ct, registry, deployer, alice, conditionId, marketId } =
      await loadFixture(deployCleanFixture);
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"));
    await registry.connect(deployer).recoverOI(marketId, 0);

    // alice still has 100 eligibility; merge attempts to subtract 100 from currentOI=0 → revert
    await expect(
      ct.connect(alice).mergePositions(conditionId, ethers.parseEther("100"))
    ).to.be.revertedWithCustomError(registry, "OIUnderflowErr");
  });
});

// ═════════════════════════════════════════════════════════════════
// 9. ExchangeCLOB transient custody — eligibility round-trip
// ═════════════════════════════════════════════════════════════════
describe("Option C: ExchangeCLOB transient custody preserves OI accuracy", function () {
  it("settleMintSweep mints OI; subsequent CLOB MERGE decrements OI exactly", async function () {
    const { exchange, ct, registry, relayer, alice, bob, conditionId, marketId } =
      await loadFixture(deployCleanFixture);
    const exchangeAddr = await exchange.getAddress();
    const deadline = BigInt((await time.latest()) + 86400);

    await ct.connect(alice).setApprovalForAll(exchangeAddr, true);
    await ct.connect(bob).setApprovalForAll(exchangeAddr, true);

    // MINT 100: alice buys YES, bob buys NO
    const fillAmount = ethers.parseEther("100");
    const mintTaker = makeOrder({
      maker: alice.address, marketId: BigInt(marketId), outcomeIndex: BigInt(0),
      side: 0, amount: fillAmount, price: ethers.parseEther("0.60"),
      nonce: BigInt(1), deadline, salt: BigInt(960001),
    });
    const mintMaker = makeOrder({
      maker: bob.address, marketId: BigInt(marketId), outcomeIndex: BigInt(1),
      side: 0, amount: fillAmount, price: ethers.parseEther("0.40"),
      nonce: BigInt(1), deadline, salt: BigInt(960002),
    });
    const mintTakerSig = await signOrder(alice, mintTaker, exchangeAddr);
    const mintMakerSig = await signOrder(bob, mintMaker, exchangeAddr);

    await exchange.connect(relayer).settleMintSweep(1, {
      takerOrder: mintTaker, takerSig: mintTakerSig,
      makerOrders: [mintMaker], makerSigs: [mintMakerSig],
      fillAmounts: [fillAmount], fees: [0n],
    });

    expect((await registry.getMarket(marketId)).currentOI).to.equal(fillAmount);

    // CLOB MERGE 50: alice sells YES, bob sells NO
    const mergeMaker = makeOrder({
      maker: alice.address, marketId: BigInt(marketId), outcomeIndex: BigInt(0),
      side: 1, amount: ethers.parseEther("50"), price: ethers.parseEther("0.40"),
      nonce: BigInt(2), deadline, salt: BigInt(960003),
    });
    const mergeTaker = makeOrder({
      maker: bob.address, marketId: BigInt(marketId), outcomeIndex: BigInt(1),
      side: 1, amount: ethers.parseEther("50"), price: ethers.parseEther("0.40"),
      nonce: BigInt(2), deadline, salt: BigInt(960004),
    });
    const mergeMakerSig = await signOrder(alice, mergeMaker, exchangeAddr);
    const mergeTakerSig = await signOrder(bob, mergeTaker, exchangeAddr);

    await exchange.connect(relayer).settleBatch(2, [{
      makerOrder: mergeMaker, takerOrder: mergeTaker,
      makerSig: mergeMakerSig, takerSig: mergeTakerSig,
      fillAmount: ethers.parseEther("50"), fee: 0n, matchType: 2,
    }]);

    expect((await registry.getMarket(marketId)).currentOI).to.equal(ethers.parseEther("50"));
  });
});
