import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ---------------------------------------------------------------------------
// Regression tests for the CertiK preliminary (2026-05-29) pending findings:
//   QGM-45  OI accounting desync during the registry-resolved / CT-unresolved window
//   QGM-46  ERC1155 callback TOCTOU aborting complementary settlement
//   QGM-47  emergencyResolve reverting for frozen + unresolved markets
//
// They also pin the previously-resolved findings these fixes touch so a future
// change can't silently reopen them:
//   QGM-39 (frozen cannot be resolved), QGM-43 (post-resolution merge), QGM-30
//   (receiver rejection soft-fail), QGM-04 (split blocked once CT-resolved).
// ---------------------------------------------------------------------------

const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));
const PROPOSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROPOSER_ROLE"));
const COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("COUNCIL_ROLE"));
const SAFETY_COUNCIL_ROLE = ethers.keccak256(ethers.toUtf8Bytes("SAFETY_COUNCIL_ROLE"));

const DISPUTE_WINDOW = 3600;
const DISPUTE_BOND = ethers.parseEther("100");
const TEN_THOUSAND = ethers.parseEther("10000");
const SPLIT = ethers.parseEther("5000");

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

function makeOrder(o: Partial<OrderStruct> & { maker: string }): OrderStruct {
  return {
    marketId: 1,
    outcomeIndex: 0,
    side: 0,
    amount: ethers.parseEther("100"),
    price: ethers.parseEther("0.60"),
    nonce: 1,
    deadline: 0,
    orderType: 0,
    salt: 1,
    ...o,
  };
}

async function signOrder(signer: HardhatEthersSigner, order: OrderStruct, exchange: string) {
  const net = await signer.provider!.getNetwork();
  const domain = { name: "GameClub Exchange", version: "1", chainId: net.chainId, verifyingContract: exchange };
  return signer.signTypedData(domain, ORDER_TYPES, order as unknown as Record<string, unknown>);
}

async function pendingFixture() {
  const [deployer, relayer, proposer, council, marketAdmin, treasury, feeCollector, alice, bob] =
    await ethers.getSigners();

  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const CT = await ethers.getContractFactory("ConditionalTokens");
  const ct = await upgrades.deployProxy(CT, [await usdt.getAddress(), treasury.address, deployer.address], {
    kind: "uups", initializer: "initialize",
  });

  const MR = await ethers.getContractFactory("MarketRegistry");
  const registry = await upgrades.deployProxy(MR, [await ct.getAddress()], {
    kind: "uups", initializer: "initialize",
  });

  const Router = await ethers.getContractFactory("CentralizedOracleRouter");
  const router = await upgrades.deployProxy(
    Router,
    [await registry.getAddress(), await usdt.getAddress(), treasury.address],
    { kind: "uups", initializer: "initialize" },
  );

  const Exchange = await ethers.getContractFactory("ExchangeCLOB");
  const exchange = await upgrades.deployProxy(
    Exchange,
    [await usdt.getAddress(), await ct.getAddress(), await registry.getAddress(), feeCollector.address, treasury.address],
    { kind: "uups", initializer: "initialize" },
  );
  await exchange.initializeV2();

  // Option C: wire CT <-> registry for protocol-wide OI sync hooks.
  await ct.initializeVx(await registry.getAddress());
  await registry.setConditionalTokens(await ct.getAddress());

  // Oracle router (2-step, 24h delay).
  await registry.proposeOracleRouter(await router.getAddress());
  await time.increase(86400);
  await registry.acceptOracleRouter();

  // Roles.
  await router.grantRole(PROPOSER_ROLE, proposer.address);
  await router.grantRole(COUNCIL_ROLE, council.address);
  await router.grantRole(SAFETY_COUNCIL_ROLE, council.address);
  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(SAFETY_COUNCIL_ROLE, council.address);
  await registry.grantRole(RELAYER_ROLE, await exchange.getAddress());
  await exchange.grantRole(RELAYER_ROLE, relayer.address);

  // Dispute-enabled profile (disputeWindow > 0 → propose/earlyResolve leave the market
  // resolved-but-not-finalized: the QGM-45 desync window).
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("dispute-enabled"));
  await registry.setProfile(
    profileHash, 500, ethers.parseEther("10000"), ethers.parseEther("1000000"),
    3600, DISPUTE_WINDOW, DISPUTE_BOND, true,
  );

  // Two markets. Cutoff is far in the future so the market stays tradeable for the
  // QGM-46 settlement tests; QGM-45 uses earlyResolve (no time gate) to open the window.
  const now = await time.latest();
  const endTime = now + 86400 * 7;
  const cutoff = endTime - 3600;
  for (let i = 1; i <= 2; i++) {
    await registry.connect(marketAdmin).createMarket({
      questionId: ethers.keccak256(ethers.toUtf8Bytes("Q" + i)),
      endTime, profileHash, tags: ["t"], cutoff, outcomeSlotCount: 2, collateralPerSet: 0,
    });
  }

  const market1 = await registry.getMarket(1);
  const conditionId = market1.conditionId;
  const collId0 = await ct.getCollectionId(conditionId, 1);
  const posId0 = await ct.getPositionId(await usdt.getAddress(), collId0);

  // Fund alice & bob, give them complete sets + approvals (non-custodial).
  const exchangeAddr = await exchange.getAddress();
  const ctAddr = await ct.getAddress();
  for (const u of [alice, bob]) {
    await usdt.mint(u.address, TEN_THOUSAND);
    await usdt.connect(u).approve(ctAddr, TEN_THOUSAND);
    await ct.connect(u).splitPosition(conditionId, SPLIT);
    await ct.connect(u).setApprovalForAll(exchangeAddr, true);
    await usdt.connect(u).approve(exchangeAddr, TEN_THOUSAND);
  }

  // Malicious contract buyer for QGM-46.
  const MockBuyer = await ethers.getContractFactory("MockMaliciousBuyer");
  const evilBuyer = await MockBuyer.deploy(await usdt.getAddress(), exchangeAddr);
  await usdt.mint(await evilBuyer.getAddress(), TEN_THOUSAND);

  return {
    deployer, relayer, proposer, council, marketAdmin, treasury, feeCollector, alice, bob,
    usdt, ct, registry, router, exchange, evilBuyer,
    conditionId, posId0, exchangeAddr,
  };
}

// ===========================================================================
// QGM-45 — OI desync during the resolved/CT-unresolved (dispute) window
// ===========================================================================
describe("QGM-45 — resolution-state OI desync", function () {
  it("splitPosition reverts during the resolved-but-unfinalized window", async function () {
    const { proposer, alice, ct, registry, router, conditionId } = await loadFixture(pendingFixture);

    await router.connect(proposer).earlyResolve(1, 0); // disputeWindow>0 → PROPOSED, resolved, not finalized

    const m = await registry.getMarket(1);
    expect(m.resolved).to.equal(true);
    expect(m.finalized).to.equal(false);
    expect(await ct.isResolved(conditionId)).to.equal(false); // the desync window

    await expect(
      ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100")),
    ).to.be.revertedWithCustomError(registry, "OIChangeWhileResolving");
  });

  it("mergePositions reverts during the resolved-but-unfinalized window", async function () {
    const { proposer, alice, ct, registry, router, conditionId } = await loadFixture(pendingFixture);

    await router.connect(proposer).earlyResolve(1, 0);

    // alice holds 5000 eligibility from the fixture, so without the fix this merge would
    // decrement currentOI even though no offsetting mint can be tracked → the QGM-45 drain.
    await expect(
      ct.connect(alice).mergePositions(conditionId, ethers.parseEther("100")),
    ).to.be.revertedWithCustomError(registry, "OIChangeWhileResolving");
  });

  it("currentOI cannot be drained by mint+merge inside the window", async function () {
    const { proposer, alice, ct, registry, router, conditionId } = await loadFixture(pendingFixture);

    const oiBefore = (await registry.getMarket(1)).currentOI;
    await router.connect(proposer).earlyResolve(1, 0);

    await expect(ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"))).to.be.reverted;
    await expect(ct.connect(alice).mergePositions(conditionId, ethers.parseEther("100"))).to.be.reverted;

    expect((await registry.getMarket(1)).currentOI).to.equal(oiBefore); // frozen, symmetric
  });

  it("split/merge resume and stay consistent after the proposal is rejected", async function () {
    const { proposer, council, alice, ct, registry, router, conditionId } =
      await loadFixture(pendingFixture);

    const oi0 = (await registry.getMarket(1)).currentOI;

    await router.connect(proposer).earlyResolve(1, 0);
    await router.connect(council).emergencyReject(1); // unresolve → market resumes

    expect((await registry.getMarket(1)).resolved).to.equal(false);

    // OI tracking works again and is exact in both directions.
    await ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100"));
    expect((await registry.getMarket(1)).currentOI).to.equal(oi0 + ethers.parseEther("100"));

    await ct.connect(alice).mergePositions(conditionId, ethers.parseEther("100"));
    expect((await registry.getMarket(1)).currentOI).to.equal(oi0);
  });

  it("RELAYER OI mutators (addVolumeAndOI/subtractOI) are unified under the resolved gate", async function () {
    // QGM-45 completeness: the resolved gate covers ALL OI mutators, not just the CT
    // split/merge hooks — the dispute-window invariant can't be sidestepped via the direct
    // RELAYER path. Both work while the market is open and revert once it is resolved.
    const { deployer, relayer, proposer, registry, router } = await loadFixture(pendingFixture);
    await registry.connect(deployer).grantRole(RELAYER_ROLE, relayer.address);

    // Pre-resolution: the gate is transparent.
    await registry.connect(relayer).addVolumeAndOI(1, ethers.parseEther("10"), ethers.parseEther("10"));
    await registry.connect(relayer).subtractOI(1, ethers.parseEther("1"));

    // Enter the resolved / CT-unresolved window.
    await router.connect(proposer).earlyResolve(1, 0);

    await expect(
      registry.connect(relayer).addVolumeAndOI(1, ethers.parseEther("1"), ethers.parseEther("1")),
    ).to.be.revertedWithCustomError(registry, "OIChangeWhileResolving");
    await expect(
      registry.connect(relayer).subtractOI(1, ethers.parseEther("1")),
    ).to.be.revertedWithCustomError(registry, "OIChangeWhileResolving");
  });

  it("QGM-43 stays resolved: post-finalization merge still skips the OI hook", async function () {
    const { proposer, alice, ct, registry, router, conditionId } = await loadFixture(pendingFixture);

    // No-dispute style finalize: earlyResolve then advance past the dispute window & finalize.
    await router.connect(proposer).earlyResolve(1, 0);
    await time.increase(DISPUTE_WINDOW + 1);
    await router.finalizeOutcome(1);

    expect((await registry.getMarket(1)).finalized).to.equal(true);
    expect(await ct.isResolved(conditionId)).to.equal(true);

    const oiAfterFinal = (await registry.getMarket(1)).currentOI;
    // Post-resolution merge is allowed (CT resolved) and must NOT mutate currentOI (QGM-43),
    // and must NOT hit the new QGM-45 revert (the hook is skipped via !isResolved).
    await ct.connect(alice).mergePositions(conditionId, ethers.parseEther("100"));
    expect((await registry.getMarket(1)).currentOI).to.equal(oiAfterFinal);
  });
});

// ===========================================================================
// QGM-47 — emergencyResolve for frozen + unresolved markets
// ===========================================================================
describe("QGM-47 — emergency resolve of frozen markets", function () {
  it("resolves a frozen + unresolved market (previously reverted)", async function () {
    const { council, registry, router, conditionId, ct } = await loadFixture(pendingFixture);

    await registry.connect(council).freezeMarket(1);
    let m = await registry.getMarket(1);
    expect(m.frozen).to.equal(true);
    expect(m.resolved).to.equal(false);

    await router.connect(council).emergencyResolve(1, 0);

    m = await registry.getMarket(1);
    expect(m.resolved).to.equal(true);
    expect(m.finalized).to.equal(true);
    expect(m.frozen).to.equal(false); // unfrozen as part of the emergency path
    expect(await ct.isResolved(conditionId)).to.equal(true);
    expect(await ct.payoutNumerators(conditionId, 0)).to.equal(1n);
  });

  it("emergencyResolveBatch survives a frozen market in the batch", async function () {
    const { council, registry, router } = await loadFixture(pendingFixture);

    await registry.connect(council).freezeMarket(1); // frozen + unresolved
    // market 2 left untouched (unfrozen + unresolved)

    await router.connect(council).emergencyResolveBatch([1, 2], [0, 1]);

    expect((await registry.getMarket(1)).finalized).to.equal(true);
    expect((await registry.getMarket(2)).finalized).to.equal(true);
  });

  it("QGM-39 stays resolved: the normal propose path still rejects frozen markets", async function () {
    const { council, proposer, registry, router } = await loadFixture(pendingFixture);

    await registry.connect(council).freezeMarket(1);
    // earlyResolve / proposeOutcome must still fail-fast on a frozen market.
    await expect(router.connect(proposer).earlyResolve(1, 0)).to.be.revertedWithCustomError(
      router, "MarketFrozen",
    );
  });

  it("regression: non-frozen emergencyResolve still works", async function () {
    const { council, registry, router } = await loadFixture(pendingFixture);
    await router.connect(council).emergencyResolve(2, 1);
    expect((await registry.getMarket(2)).finalized).to.equal(true);
  });
});

// ===========================================================================
// QGM-48 — ConditionalTokens reset/rotation semantics (documented invariant)
// ===========================================================================
describe("QGM-48 — CT reset is a deliberate, unconditional kill-switch", function () {
  it("emergencyResetConditionalTokens stays callable with open markets (by design)", async function () {
    // The operational invariant is documented (NatSpec), but the reset is intentionally NOT
    // blocked by an on-chain "no open markets" guard: that would neuter the emergency
    // kill-switch in exactly the incident where it must work. Markets 1 & 2 are open here.
    const { deployer, registry } = await loadFixture(pendingFixture);

    await expect(registry.connect(deployer).emergencyResetConditionalTokens())
      .to.emit(registry, "ConditionalTokensReset");
    expect(await registry.conditionalTokensAddress()).to.equal(ethers.ZeroAddress);
  });

  it("after reset, the old CT's OI hooks are de-authorized (kill-switch halts new mints)", async function () {
    const { deployer, alice, ct, registry, conditionId } = await loadFixture(pendingFixture);

    await registry.connect(deployer).emergencyResetConditionalTokens();

    // conditionalTokensAddress is now 0 → onlyConditionalTokens no longer authorizes the CT,
    // so the OI hook call inside splitPosition reverts (NotConditionalTokens) and minting halts.
    await expect(
      ct.connect(alice).splitPosition(conditionId, ethers.parseEther("100")),
    ).to.be.revertedWithCustomError(registry, "NotConditionalTokens");
  });
});

// ===========================================================================
// QGM-46 — ERC1155 callback TOCTOU on complementary settlement
// ===========================================================================
describe("QGM-46 — complementary settlement payment TOCTOU", function () {
  const PRICE = ethers.parseEther("0.60");
  const AMOUNT = ethers.parseEther("100");
  const FILL_VALUE = ethers.parseEther("60"); // 0.60 * 100

  async function buildComplementaryFill(
    buyer: string, seller: HardhatEthersSigner, exchangeAddr: string, salt: number,
  ) {
    const deadline = BigInt((await time.latest()) + 86400);
    const makerOrder = makeOrder({ maker: buyer, side: 0, price: PRICE, amount: AMOUNT, nonce: 1, deadline, salt });
    const takerOrder = makeOrder({ maker: seller.address, side: 1, price: PRICE, amount: AMOUNT, nonce: 1, deadline, salt: salt + 1000 });
    const makerSig = "0x"; // contract buyer accepts via EIP-1271
    const takerSig = await signOrder(seller, takerOrder, exchangeAddr);
    return { makerOrder, takerOrder, makerSig, takerSig, fillAmount: AMOUNT, fee: 0n, matchType: 0 };
  }

  it("REVOKE-allowance buyer no longer aborts settlement; fill settles", async function () {
    const { relayer, bob, evilBuyer, exchange, usdt, ct, posId0, exchangeAddr } =
      await loadFixture(pendingFixture);

    await evilBuyer.approveUsdt(TEN_THOUSAND);
    await evilBuyer.setMode(1); // revoke allowance inside onERC1155Received

    const buyerAddr = await evilBuyer.getAddress();
    const fill = await buildComplementaryFill(buyerAddr, bob, exchangeAddr, 1);

    const buyerUsdtBefore = await usdt.balanceOf(buyerAddr);
    const bobUsdtBefore = await usdt.balanceOf(bob.address);

    await expect(exchange.connect(relayer).settleBatch(1, [fill]))
      .to.emit(exchange, "BatchSettled")
      .withArgs(1, 1, 0, relayer.address); // 1 success, 0 skip

    expect(await ct.balanceOf(buyerAddr, posId0)).to.equal(AMOUNT);
    expect(buyerUsdtBefore - (await usdt.balanceOf(buyerAddr))).to.equal(FILL_VALUE);
    expect((await usdt.balanceOf(bob.address)) - bobUsdtBefore).to.equal(FILL_VALUE);
  });

  it("REVERT receiver soft-fails to a skip and the escrow is refunded (QGM-30 preserved)", async function () {
    const { relayer, bob, evilBuyer, exchange, usdt, ct, posId0, exchangeAddr } =
      await loadFixture(pendingFixture);

    await evilBuyer.approveUsdt(TEN_THOUSAND);
    await evilBuyer.setMode(2); // revert inside onERC1155Received

    const buyerAddr = await evilBuyer.getAddress();
    const fill = await buildComplementaryFill(buyerAddr, bob, exchangeAddr, 1);

    const buyerUsdtBefore = await usdt.balanceOf(buyerAddr);
    const bobSharesBefore = await ct.balanceOf(bob.address, posId0);

    await expect(exchange.connect(relayer).settleBatch(1, [fill]))
      .to.emit(exchange, "BatchSettled")
      .withArgs(1, 0, 1, relayer.address); // 0 success, 1 skip ("rcr")

    expect(await usdt.balanceOf(buyerAddr)).to.equal(buyerUsdtBefore); // escrow refunded
    expect(await ct.balanceOf(buyerAddr, posId0)).to.equal(0n);
    expect(await ct.balanceOf(bob.address, posId0)).to.equal(bobSharesBefore); // seller kept shares
  });

  it("a malicious fill does not abort a good fill in the same batch", async function () {
    const { relayer, alice, bob, evilBuyer, exchange, ct, posId0, exchangeAddr } =
      await loadFixture(pendingFixture);

    await evilBuyer.approveUsdt(TEN_THOUSAND);
    await evilBuyer.setMode(2); // bad fill reverts in receiver hook

    const badFill = await buildComplementaryFill(await evilBuyer.getAddress(), bob, exchangeAddr, 1);
    const goodFill = await buildComplementaryFill(alice.address, bob, exchangeAddr, 2);
    // alice is an EOA buyer; her maker order needs a real signature.
    goodFill.makerSig = await signOrder(alice, goodFill.makerOrder as unknown as OrderStruct, exchangeAddr);

    const aliceSharesBefore = await ct.balanceOf(alice.address, posId0);

    await expect(exchange.connect(relayer).settleBatch(1, [badFill, goodFill]))
      .to.emit(exchange, "BatchSettled")
      .withArgs(1, 1, 1, relayer.address); // good fill succeeds, bad fill skipped

    expect((await ct.balanceOf(alice.address, posId0)) - aliceSharesBefore).to.equal(AMOUNT);
  });
});
