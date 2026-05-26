// Test suite for gameclub-specific extensions on top of audit v2 minimum-fix model.
// Covers:
//   1. MinimumFix: direct-split → CLOB MERGE → OIUnderflowErr atomic revert
//   2. forceSettleBatch (SAFETY_COUNCIL_ROLE)
//   3. earlyResolve / earlyResolveBatch (PROPOSER_ROLE without time gate)
//   4. redeemPositionsFor (DEFAULT_ADMIN_ROLE)
//   5. recoverOI (DEFAULT_ADMIN_ROLE)

import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
const ORACLE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));
const KEEPER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("KEEPER_ROLE"));
const SAFETY_COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SAFETY_COUNCIL_ROLE"));
const PROPOSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROPOSER_ROLE"));
const COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("COUNCIL_ROLE"));
const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";

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

async function deployFixture() {
  const [
    deployer,
    relayer,
    marketAdmin,
    oracle,
    keeper,
    safetyCouncil,
    council,
    proposer,
    feeCollector,
    treasury,
    alice,
    bob,
    charlie,
    dave,
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

  // Option C: wire ConditionalTokens ↔ MarketRegistry for protocol-wide OI sync
  await ct.initializeVx(await registry.getAddress());
  await registry.setConditionalTokens(await ct.getAddress());

  // Deploy oracle router for earlyResolve tests
  const OracleRouter = await ethers.getContractFactory("CentralizedOracleRouter");
  const oracleRouter = await upgrades.deployProxy(
    OracleRouter,
    [await registry.getAddress(), await usdt.getAddress(), treasury.address],
    { kind: "uups", initializer: "initialize" }
  );

  // Roles
  await exchange.grantRole(RELAYER_ROLE, relayer.address);
  await exchange.grantRole(SAFETY_COUNCIL_ROLE, safetyCouncil.address);

  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(ORACLE_ROLE, oracle.address);
  await registry.grantRole(KEEPER_ROLE, keeper.address);
  await registry.grantRole(SAFETY_COUNCIL_ROLE, safetyCouncil.address);
  await registry.grantRole(RELAYER_ROLE, await exchange.getAddress());

  await oracleRouter.grantRole(PROPOSER_ROLE, proposer.address);
  await oracleRouter.grantRole(COUNCIL_ROLE, council.address);
  await oracleRouter.grantRole(SAFETY_COUNCIL_ROLE, safetyCouncil.address);

  // Initialize oracle router on registry
  await registry.initOracleRouter(await oracleRouter.getAddress());

  // Profile
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("default"));
  await registry.setProfile(
    profileHash,
    500,
    ethers.parseEther("10000"),
    ethers.parseEther("1000000"),
    3600,
    0, // disputeWindow=0 → immediate finalize
    0,
    false
  );

  // Create market
  const now = await time.latest();
  const questionId = ethers.keccak256(ethers.toUtf8Bytes("Will BTC > 100k?"));
  await registry.connect(marketAdmin).createMarket({
    questionId,
    endTime: now + 86400 * 7,
    profileHash,
    tags: ["crypto", "btc"],
    cutoff: now + 86400 * 7 - 3600,
    outcomeSlotCount: 2,
    collateralPerSet: 0,
  });
  const marketId = 1;
  const market = await registry.getMarket(marketId);
  const conditionId = market.conditionId;

  const collectionId0 = await ct.getCollectionId(conditionId, 1);
  const collectionId1 = await ct.getCollectionId(conditionId, 2);
  const posId0 = await ct.getPositionId(await usdt.getAddress(), collectionId0);
  const posId1 = await ct.getPositionId(await usdt.getAddress(), collectionId1);

  const users = [alice, bob, charlie, dave];
  for (const user of users) {
    await usdt.mint(user.address, TEN_THOUSAND);
  }

  const exchangeAddr = await exchange.getAddress();
  const ctAddr = await ct.getAddress();
  const splitAmount = ethers.parseEther("5000");

  for (const user of [alice, bob, charlie, dave]) {
    await usdt.connect(user).approve(ctAddr, splitAmount);
    await ct.connect(user).splitPosition(conditionId, splitAmount);
    await ct.connect(user).setApprovalForAll(exchangeAddr, true);
    await usdt.connect(user).approve(exchangeAddr, TEN_THOUSAND);
  }

  return {
    deployer,
    relayer,
    marketAdmin,
    oracle,
    keeper,
    safetyCouncil,
    council,
    proposer,
    feeCollector,
    treasury,
    alice,
    bob,
    charlie,
    dave,
    usdt,
    ct,
    registry,
    exchange,
    oracleRouter,
    profileHash,
    questionId,
    marketId,
    conditionId,
    posId0,
    posId1,
  };
}

// ═════════════════════════════════════════════════════════════════
// 1. Option C: QGM-03 full closure via ConditionalTokens-driven OI sync
// ═════════════════════════════════════════════════════════════════

describe("GameClub: Option C QGM-03 full closure", function () {
  it("direct-split via CT.splitPosition increases currentOI (Source Tracking)", async function () {
    const { ct, registry, charlie, conditionId, marketId, usdt } =
      await loadFixture(deployFixture);

    // charlie has 5000 of each outcome from fixture splits → OI 5000 already counted
    const oiBefore = (await registry.getMarket(marketId)).currentOI;
    expect(oiBefore).to.equal(ethers.parseEther("20000")); // 4 fixture users × 5000

    // charlie performs an additional direct split of 100 → OI should grow by 100
    const ctAddr = await ct.getAddress();
    await usdt.connect(charlie).approve(ctAddr, ethers.parseEther("100"));
    await ct.connect(charlie).splitPosition(conditionId, ethers.parseEther("100"));

    const oiAfter = (await registry.getMarket(marketId)).currentOI;
    expect(oiAfter).to.equal(oiBefore + ethers.parseEther("100"));
  });

  it("CLOB MERGE on tracked shares (own-minted) decrements OI by exact amount", async function () {
    const { exchange, registry, relayer, alice, bob, marketId } = await loadFixture(deployFixture);
    const exchangeAddr = await exchange.getAddress();
    const deadline = BigInt((await time.latest()) + 86400);

    const oiBefore = (await registry.getMarket(marketId)).currentOI;

    // alice and bob have eligibility on their fixture-split shares (5000 each).
    // CLOB MERGE 100 → ExchangeCLOB receives shares + eligibility via _update hook,
    //                  then mergePositions burns them and calls subtractOIByCondition(100).
    const fillAmount = ethers.parseEther("100");
    const makerOrder = makeOrder({
      maker: alice.address, outcomeIndex: BigInt(0), side: 1,
      amount: fillAmount, price: ethers.parseEther("0.40"),
      nonce: BigInt(1), deadline, salt: BigInt(900001),
    });
    const takerOrder = makeOrder({
      maker: bob.address, outcomeIndex: BigInt(1), side: 1,
      amount: fillAmount, price: ethers.parseEther("0.40"),
      nonce: BigInt(1), deadline, salt: BigInt(900002),
    });
    const makerSig = await signOrder(alice, makerOrder, exchangeAddr);
    const takerSig = await signOrder(bob, takerOrder, exchangeAddr);

    await exchange.connect(relayer).settleBatch(1, [
      { makerOrder, takerOrder, makerSig, takerSig, fillAmount, fee: 0n, matchType: 2 },
    ]);

    const oiAfter = (await registry.getMarket(marketId)).currentOI;
    expect(oiAfter).to.equal(oiBefore - fillAmount);
  });

  it("ERC1155 transfer hook moves eligibility (Source Tracking propagation)", async function () {
    // Option C invariant: when a user transfers shares, eligibility moves with them
    // (up to min(holder_eligibility, transferred_amount)). This guarantees that
    // burn-via-merge always decrements OI by exactly the eligibility owned at burn time.
    const { ct, charlie, dave, conditionId, usdt } = await loadFixture(deployFixture);

    const moveAmount = ethers.parseEther("50");
    const collId0 = await ct.getCollectionId(conditionId, 1);
    const posId0 = await ct.getPositionId(await usdt.getAddress(), collId0);

    // Both charlie and dave each have 5000 eligibility on outcome 0 (from fixture splits)
    const charlieEligBefore = await ct.oiEligibleShares(charlie.address, posId0);
    const daveEligBefore = await ct.oiEligibleShares(dave.address, posId0);
    expect(charlieEligBefore).to.equal(ethers.parseEther("5000"));
    expect(daveEligBefore).to.equal(ethers.parseEther("5000"));

    await ct.connect(charlie).safeTransferFrom(charlie.address, dave.address, posId0, moveAmount, "0x");

    const charlieEligAfter = await ct.oiEligibleShares(charlie.address, posId0);
    const daveEligAfter = await ct.oiEligibleShares(dave.address, posId0);
    expect(charlieEligAfter).to.equal(charlieEligBefore - moveAmount);
    expect(daveEligAfter).to.equal(daveEligBefore + moveAmount);
  });

  it("settleMintSweep still increases OI on top of existing fixture splits", async function () {
    const { exchange, registry, relayer, charlie, dave, marketId } = await loadFixture(deployFixture);
    const exchangeAddr = await exchange.getAddress();
    const deadline = BigInt((await time.latest()) + 86400);

    const oiBefore = (await registry.getMarket(marketId)).currentOI;

    const fillAmount = ethers.parseEther("10");
    const takerOrder = makeOrder({
      maker: charlie.address, outcomeIndex: BigInt(0), side: 0,
      amount: fillAmount, price: ethers.parseEther("0.60"),
      nonce: BigInt(1), deadline, salt: BigInt(910001),
    });
    const makerOrder = makeOrder({
      maker: dave.address, outcomeIndex: BigInt(1), side: 0,
      amount: fillAmount, price: ethers.parseEther("0.40"),
      nonce: BigInt(1), deadline, salt: BigInt(910002),
    });
    const takerSig = await signOrder(charlie, takerOrder, exchangeAddr);
    const makerSig = await signOrder(dave, makerOrder, exchangeAddr);

    await exchange.connect(relayer).settleMintSweep(1, {
      takerOrder, takerSig,
      makerOrders: [makerOrder], makerSigs: [makerSig],
      fillAmounts: [fillAmount], fees: [0n],
    });

    const oiAfter = (await registry.getMarket(marketId)).currentOI;
    expect(oiAfter).to.equal(oiBefore + fillAmount);
  });
});

// ═════════════════════════════════════════════════════════════════
// 2. forceSettleBatch (SAFETY_COUNCIL_ROLE)
// ═════════════════════════════════════════════════════════════════

describe("GameClub: forceSettleBatch", function () {
  it("SAFETY_COUNCIL can force-settle on a resolved market", async function () {
    const { exchange, registry, oracleRouter, safetyCouncil, alice, bob, proposer, marketId } =
      await loadFixture(deployFixture);
    const exchangeAddr = await exchange.getAddress();
    const deadline = BigInt((await time.latest()) + 86400);

    // Build a COMPLEMENTARY fill: alice buys YES from bob
    const fillAmount = ethers.parseEther("10");
    const makerOrder = makeOrder({
      maker: alice.address,
      outcomeIndex: BigInt(0),
      side: 0, // BUY
      amount: fillAmount,
      price: ethers.parseEther("0.60"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(920001),
    });
    const takerOrder = makeOrder({
      maker: bob.address,
      outcomeIndex: BigInt(0),
      side: 1, // SELL
      amount: fillAmount,
      price: ethers.parseEther("0.60"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(920002),
    });
    const makerSig = await signOrder(alice, makerOrder, exchangeAddr);
    const takerSig = await signOrder(bob, takerOrder, exchangeAddr);

    // Resolve the market by advancing time past tradingCutoff and proposing outcome
    await time.increase(86400 * 7);
    await oracleRouter.connect(proposer).proposeOutcome(marketId, 0); // disputeWindow=0 → immediate finalize

    // Verify market is now resolved + finalized
    const market = await registry.getMarket(marketId);
    expect(market.resolved).to.equal(true);
    expect(market.finalized).to.equal(true);

    // settleBatch should fail with market_resolved (mrs) skip
    await expect(
      exchange.connect(safetyCouncil).forceSettleBatch(99, [
        {
          makerOrder,
          takerOrder,
          makerSig,
          takerSig,
          fillAmount,
          fee: 0n,
          matchType: 0, // COMPLEMENTARY
        },
      ])
    ).to.emit(exchange, "ForceSettled").withArgs(99, 1, 0, safetyCouncil.address);
  });

  it("non-SAFETY_COUNCIL cannot force-settle", async function () {
    const { exchange, alice } = await loadFixture(deployFixture);
    await expect(exchange.connect(alice).forceSettleBatch(1, [])).to.be.reverted;
  });

  it("force-settle skips deadline check (allows expired orders)", async function () {
    const { exchange, registry, safetyCouncil, alice, bob, marketId } =
      await loadFixture(deployFixture);
    const exchangeAddr = await exchange.getAddress();
    const expired = BigInt((await time.latest()) - 1);
    const fillAmount = ethers.parseEther("10");

    const makerOrder = makeOrder({
      maker: alice.address,
      outcomeIndex: BigInt(0),
      side: 0,
      amount: fillAmount,
      price: ethers.parseEther("0.60"),
      nonce: BigInt(1),
      deadline: expired,
      salt: BigInt(920101),
    });
    const takerOrder = makeOrder({
      maker: bob.address,
      outcomeIndex: BigInt(0),
      side: 1,
      amount: fillAmount,
      price: ethers.parseEther("0.60"),
      nonce: BigInt(1),
      deadline: expired,
      salt: BigInt(920102),
    });
    const makerSig = await signOrder(alice, makerOrder, exchangeAddr);
    const takerSig = await signOrder(bob, takerOrder, exchangeAddr);

    await expect(
      exchange.connect(safetyCouncil).forceSettleBatch(100, [
        {
          makerOrder,
          takerOrder,
          makerSig,
          takerSig,
          fillAmount,
          fee: 0n,
          matchType: 0,
        },
      ])
    ).to.emit(exchange, "ForceSettled").withArgs(100, 1, 0, safetyCouncil.address);
  });

  it("force-settle still rejects non-existent market", async function () {
    const { exchange, safetyCouncil, alice, bob } = await loadFixture(deployFixture);
    const exchangeAddr = await exchange.getAddress();
    const deadline = BigInt((await time.latest()) + 86400);
    const fillAmount = ethers.parseEther("10");

    const makerOrder = makeOrder({
      maker: alice.address,
      marketId: BigInt(9999), // non-existent
      outcomeIndex: BigInt(0),
      side: 0,
      amount: fillAmount,
      price: ethers.parseEther("0.60"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(920201),
    });
    const takerOrder = { ...makerOrder, maker: bob.address, side: 1, salt: BigInt(920202) };
    const makerSig = await signOrder(alice, makerOrder, exchangeAddr);
    const takerSig = await signOrder(bob, takerOrder, exchangeAddr);

    await expect(
      exchange.connect(safetyCouncil).forceSettleBatch(101, [
        {
          makerOrder,
          takerOrder,
          makerSig,
          takerSig,
          fillAmount,
          fee: 0n,
          matchType: 0,
        },
      ])
    ).to.emit(exchange, "FillSkipped");
  });
});

// ═════════════════════════════════════════════════════════════════
// 3. earlyResolve / earlyResolveBatch (PROPOSER_ROLE without time gate)
// ═════════════════════════════════════════════════════════════════

describe("GameClub: earlyResolve", function () {
  it("PROPOSER can earlyResolve before tradingCutoff", async function () {
    const { oracleRouter, registry, proposer, marketId } = await loadFixture(deployFixture);

    const before = await registry.getMarket(marketId);
    expect(before.resolved).to.equal(false);

    // No time advance — should still work because earlyResolve has no time gate
    await expect(oracleRouter.connect(proposer).earlyResolve(marketId, 0))
      .to.emit(oracleRouter, "OutcomeProposed")
      .and.to.emit(oracleRouter, "OutcomeFinalized");

    const after = await registry.getMarket(marketId);
    expect(after.resolved).to.equal(true);
    expect(after.finalized).to.equal(true);
  });

  it("non-PROPOSER cannot earlyResolve", async function () {
    const { oracleRouter, alice, marketId } = await loadFixture(deployFixture);
    await expect(oracleRouter.connect(alice).earlyResolve(marketId, 0)).to.be.reverted;
  });

  it("earlyResolve rejects invalid outcome index", async function () {
    const { oracleRouter, proposer, marketId } = await loadFixture(deployFixture);
    await expect(
      oracleRouter.connect(proposer).earlyResolve(marketId, 2)
    ).to.be.revertedWithCustomError(oracleRouter, "InvalidOutcome");
  });

  it("earlyResolve rejects already-finalized market", async function () {
    const { oracleRouter, proposer, marketId } = await loadFixture(deployFixture);
    await oracleRouter.connect(proposer).earlyResolve(marketId, 0);
    await expect(
      oracleRouter.connect(proposer).earlyResolve(marketId, 0)
    ).to.be.revertedWithCustomError(oracleRouter, "ProposalAlreadyExists");
  });

  it("earlyResolveBatch resolves multiple markets", async function () {
    const { oracleRouter, registry, proposer, marketAdmin, profileHash } =
      await loadFixture(deployFixture);
    const now = await time.latest();

    // Create 2 more markets
    for (let i = 0; i < 2; i++) {
      await registry.connect(marketAdmin).createMarket({
        questionId: ethers.keccak256(ethers.toUtf8Bytes(`Q${i + 100}`)),
        endTime: now + 86400 * 7,
        profileHash,
        tags: [],
        cutoff: now + 86400 * 7 - 3600,
        outcomeSlotCount: 2,
        collateralPerSet: 0,
      });
    }

    await oracleRouter.connect(proposer).earlyResolveBatch([1, 2, 3], [0, 1, 0]);

    const m1 = await registry.getMarket(1);
    const m2 = await registry.getMarket(2);
    const m3 = await registry.getMarket(3);
    expect(m1.finalized).to.equal(true);
    expect(m2.finalized).to.equal(true);
    expect(m3.finalized).to.equal(true);
  });

  it("earlyResolveBatch length mismatch reverts", async function () {
    const { oracleRouter, proposer } = await loadFixture(deployFixture);
    await expect(oracleRouter.connect(proposer).earlyResolveBatch([1], [0, 1])).to.be.revertedWith(
      "Array length mismatch"
    );
  });
});

// ═════════════════════════════════════════════════════════════════
// 4. redeemPositionsFor (DEFAULT_ADMIN_ROLE)
// ═════════════════════════════════════════════════════════════════

describe("GameClub: redeemPositionsFor", function () {
  it("admin can redeem CT shares on behalf of holder", async function () {
    const { ct, oracleRouter, proposer, alice, treasury, marketId, conditionId, deployer } =
      await loadFixture(deployFixture);

    // Alice approves CT for admin redemption
    const ctAddr = await ct.getAddress();
    await ct.connect(alice).setApprovalForAll(ctAddr, true);

    // Resolve outcome 0 wins
    await oracleRouter.connect(proposer).earlyResolve(marketId, 0);

    // Alice has 5000 of each outcome from fixture splits.
    // Outcome 0 wins → alice's outcome 0 shares are redeemable for 5000 USDT.
    const aliceUsdtBefore = await ct.collateralToken().then((addr: string) =>
      ethers.getContractAt("MockUSDT", addr).then((u) => u.balanceOf(alice.address))
    );

    // indexSets: [1, 2] = both outcomes (1 = outcome 0, 2 = outcome 1)
    await expect(
      ct.connect(deployer).redeemPositionsFor(alice.address, alice.address, conditionId, [1, 2])
    ).to.emit(ct, "RedeemForUser");

    const usdt = await ethers.getContractAt("MockUSDT", await ct.collateralToken());
    const aliceUsdtAfter = await usdt.balanceOf(alice.address);

    // Outcome 0 wins → alice gets 5000 USDT (her outcome 0 shares)
    expect(aliceUsdtAfter - aliceUsdtBefore).to.equal(ethers.parseEther("5000"));
  });

  it("non-admin cannot redeemPositionsFor", async function () {
    const { ct, alice, conditionId } = await loadFixture(deployFixture);
    await expect(
      ct.connect(alice).redeemPositionsFor(alice.address, alice.address, conditionId, [1])
    ).to.be.reverted;
  });

  it("redeemPositionsFor rejects unresolved condition", async function () {
    const { ct, deployer, alice, conditionId } = await loadFixture(deployFixture);
    await expect(
      ct.connect(deployer).redeemPositionsFor(alice.address, alice.address, conditionId, [1])
    ).to.be.revertedWithCustomError(ct, "ConditionNotResolved");
  });

  it("redeemPositionsFor with zero holder reverts", async function () {
    const { ct, deployer, oracleRouter, proposer, marketId, conditionId, alice } =
      await loadFixture(deployFixture);
    await oracleRouter.connect(proposer).earlyResolve(marketId, 0);

    await expect(
      ct.connect(deployer).redeemPositionsFor(
        ethers.ZeroAddress,
        alice.address,
        conditionId,
        [1]
      )
    ).to.be.revertedWith("Zero holder");
  });

  it("redeemPositionsFor sends payout to recipient (not holder)", async function () {
    const { ct, oracleRouter, proposer, alice, charlie, deployer, marketId, conditionId } =
      await loadFixture(deployFixture);

    // QGM-38 fix: holder must opt in to admin redemption via setApprovalForAll(CT, true).
    const ctAddr = await ct.getAddress();
    await ct.connect(alice).setApprovalForAll(ctAddr, true);

    await oracleRouter.connect(proposer).earlyResolve(marketId, 0);

    const usdt = await ethers.getContractAt("MockUSDT", await ct.collateralToken());
    const charlieUsdtBefore = await usdt.balanceOf(charlie.address);

    // Alice's shares burned, Charlie receives payout
    await ct.connect(deployer).redeemPositionsFor(alice.address, charlie.address, conditionId, [1]);

    const charlieUsdtAfter = await usdt.balanceOf(charlie.address);
    expect(charlieUsdtAfter - charlieUsdtBefore).to.equal(ethers.parseEther("5000"));
  });

  it("QGM-38: redeemPositionsFor reverts when holder has not approved CT", async function () {
    const { ct, oracleRouter, proposer, alice, deployer, marketId, conditionId } =
      await loadFixture(deployFixture);

    // Alice deliberately does NOT call setApprovalForAll.
    await oracleRouter.connect(proposer).earlyResolve(marketId, 0);

    await expect(
      ct.connect(deployer).redeemPositionsFor(alice.address, alice.address, conditionId, [1])
    ).to.be.revertedWithCustomError(ct, "HolderApprovalRequired");
  });
});

// ═════════════════════════════════════════════════════════════════
// 5. recoverOI (DEFAULT_ADMIN_ROLE)
// ═════════════════════════════════════════════════════════════════

describe("GameClub: recoverOI", function () {
  it("admin can adjust currentOI to reconcile drift", async function () {
    const { registry, deployer, exchange, relayer, charlie, dave, marketId } =
      await loadFixture(deployFixture);
    const exchangeAddr = await exchange.getAddress();
    const deadline = BigInt((await time.latest()) + 86400);

    // First, mint via exchange to have some OI
    const fillAmount = ethers.parseEther("10");
    const takerOrder = makeOrder({
      maker: charlie.address,
      outcomeIndex: BigInt(0),
      side: 0,
      amount: fillAmount,
      price: ethers.parseEther("0.60"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(940001),
    });
    const makerOrder = makeOrder({
      maker: dave.address,
      outcomeIndex: BigInt(1),
      side: 0,
      amount: fillAmount,
      price: ethers.parseEther("0.40"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(940002),
    });
    const takerSig = await signOrder(charlie, takerOrder, exchangeAddr);
    const makerSig = await signOrder(dave, makerOrder, exchangeAddr);
    await exchange.connect(relayer).settleMintSweep(1, {
      takerOrder,
      takerSig,
      makerOrders: [makerOrder],
      makerSigs: [makerSig],
      fillAmounts: [fillAmount],
      fees: [0n],
    });

    const before = await registry.getMarket(marketId);
    // Option C: fixture creates OI from splits (4 users × 5000) + MINT (10) = 20010.
    // We just verify that some non-zero OI exists, then recover to a smaller value.
    expect(before.currentOI).to.be.gt(0n);

    // Admin reconciles: set OI to (current - 5) as if 5 was burned outside the exchange
    const oiBefore = before.currentOI;
    const newOI = oiBefore - ethers.parseEther("5");
    await expect(registry.connect(deployer).recoverOI(marketId, newOI))
      .to.emit(registry, "OIRecovered")
      .withArgs(marketId, oiBefore, newOI, deployer.address);

    const after = await registry.getMarket(marketId);
    expect(after.currentOI).to.equal(newOI);
  });

  it("non-admin cannot recoverOI", async function () {
    const { registry, alice, marketId } = await loadFixture(deployFixture);
    await expect(registry.connect(alice).recoverOI(marketId, 0)).to.be.reverted;
  });

  it("recoverOI rejects non-existent market", async function () {
    const { registry, deployer } = await loadFixture(deployFixture);
    await expect(
      registry.connect(deployer).recoverOI(9999, 0)
    ).to.be.revertedWithCustomError(registry, "MarketNotFound");
  });

  it("recoverOI rejects finalized market", async function () {
    const { registry, deployer, oracleRouter, proposer, marketId } = await loadFixture(deployFixture);
    await oracleRouter.connect(proposer).earlyResolve(marketId, 0);
    await expect(
      registry.connect(deployer).recoverOI(marketId, 0)
    ).to.be.revertedWithCustomError(registry, "MarketAlreadyFinalized");
  });

  it("recoverOI does NOT bypass other invariants — subtractOI still reverts on underflow after recovery", async function () {
    const { registry, deployer, exchange, relayer, charlie, dave, alice, bob, marketId } =
      await loadFixture(deployFixture);
    const exchangeAddr = await exchange.getAddress();
    const deadline = BigInt((await time.latest()) + 86400);

    // Mint 10 OI via exchange
    const fillAmount = ethers.parseEther("10");
    const takerOrder = makeOrder({
      maker: charlie.address,
      outcomeIndex: BigInt(0),
      side: 0,
      amount: fillAmount,
      price: ethers.parseEther("0.60"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(950001),
    });
    const makerOrder = makeOrder({
      maker: dave.address,
      outcomeIndex: BigInt(1),
      side: 0,
      amount: fillAmount,
      price: ethers.parseEther("0.40"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(950002),
    });
    const takerSig = await signOrder(charlie, takerOrder, exchangeAddr);
    const makerSig = await signOrder(dave, makerOrder, exchangeAddr);
    await exchange.connect(relayer).settleMintSweep(1, {
      takerOrder,
      takerSig,
      makerOrders: [makerOrder],
      makerSigs: [makerSig],
      fillAmounts: [fillAmount],
      fees: [0n],
    });

    // Admin sets OI to 0 (e.g., reconciling after off-chain burns)
    await registry.connect(deployer).recoverOI(marketId, 0);

    // Now any further MERGE via exchange (with non-zero amount) reverts via subtractOI
    const mergeMaker = makeOrder({
      maker: alice.address,
      outcomeIndex: BigInt(0),
      side: 1,
      amount: fillAmount,
      price: ethers.parseEther("0.40"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(950101),
    });
    const mergeTaker = makeOrder({
      maker: bob.address,
      outcomeIndex: BigInt(1),
      side: 1,
      amount: fillAmount,
      price: ethers.parseEther("0.40"),
      nonce: BigInt(1),
      deadline,
      salt: BigInt(950102),
    });
    const mergeMakerSig = await signOrder(alice, mergeMaker, exchangeAddr);
    const mergeTakerSig = await signOrder(bob, mergeTaker, exchangeAddr);

    await expect(
      exchange.connect(relayer).settleBatch(2, [
        {
          makerOrder: mergeMaker,
          takerOrder: mergeTaker,
          makerSig: mergeMakerSig,
          takerSig: mergeTakerSig,
          fillAmount,
          fee: 0n,
          matchType: 2,
        },
      ])
    ).to.be.revertedWithCustomError(registry, "OIUnderflowErr");
  });
});
