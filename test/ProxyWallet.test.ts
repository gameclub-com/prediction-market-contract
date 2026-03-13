import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RELAYER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("RELAYER_ROLE"));
const MARKET_ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MARKET_ADMIN_ROLE"));

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

async function proxyFixture() {
  const [deployer, user, relayer, otherUser, marketAdmin, oracle, keeper, safetyCouncil, feeCollector, treasury] =
    await ethers.getSigners();

  // Deploy core contracts
  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const CT = await ethers.getContractFactory("ConditionalTokens");
  const ct = await CT.deploy(await usdt.getAddress(), treasury.address);

  const MR = await ethers.getContractFactory("MarketRegistry");
  const registry = await MR.deploy(await ct.getAddress());

  const Exchange = await ethers.getContractFactory("ExchangeCLOB");
  const exchange = await Exchange.deploy(
    await usdt.getAddress(),
    await ct.getAddress(),
    await registry.getAddress(),
    feeCollector.address,
    treasury.address,
  );

  await exchange.grantRole(RELAYER_ROLE, relayer.address);
  await registry.grantRole(MARKET_ADMIN_ROLE, marketAdmin.address);
  await registry.grantRole(RELAYER_ROLE, await exchange.getAddress());
  // H-4 v2: 2-step oracle router change
  await registry.proposeOracleRouter(oracle.address);
  await time.increase(86400);
  await registry.acceptOracleRouter();

  // Deploy ProxyWallet implementation (for clones)
  const PW = await ethers.getContractFactory("ProxyWallet");
  const pwImpl = await PW.deploy();

  // Deploy SafeProxyFactory
  const SPF = await ethers.getContractFactory("SafeProxyFactory");
  const factory = await SPF.deploy(
    await pwImpl.getAddress(),
    await exchange.getAddress(),
    await usdt.getAddress(),
    await ct.getAddress(),
  );

  return {
    deployer, user, relayer, otherUser, marketAdmin, oracle, keeper, safetyCouncil, feeCollector, treasury,
    usdt, ct, registry, exchange, pwImpl, factory,
  };
}

// ===========================================================================
// ProxyWallet Tests
// ===========================================================================

describe("ProxyWallet", function () {
  describe("Initialization", function () {
    it("owner is set correctly after initialize", async function () {
      const { factory, user } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr);

      expect(await proxy.owner()).to.equal(user.address);
    });

    it("double initialize reverts", async function () {
      const { factory, user } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr);

      await expect(
        proxy.initialize(user.address, "0x"),
      ).to.be.revertedWithCustomError(proxy, "AlreadyInitialized");
    });
  });

  describe("Auto-approvals", function () {
    it("proxy has max USDT approval for Exchange after creation", async function () {
      const { factory, user, usdt, exchange } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);

      const allowance = await usdt.allowance(proxyAddr, await exchange.getAddress());
      expect(allowance).to.equal(ethers.MaxUint256);
    });

    it("proxy has CT operator approval for Exchange after creation", async function () {
      const { factory, user, ct, exchange } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);

      const approved = await ct.isApprovedForAll(proxyAddr, await exchange.getAddress());
      expect(approved).to.be.true;
    });
  });

  describe("Execute", function () {
    it("owner can execute arbitrary call", async function () {
      const { factory, user, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr);

      // Mint some USDT to the proxy, then transfer via execute
      await usdt.mint(proxyAddr, ethers.parseEther("100"));

      const transferData = usdt.interface.encodeFunctionData("transfer", [
        user.address,
        ethers.parseEther("50"),
      ]);

      await proxy.connect(user).execute(await usdt.getAddress(), 0, transferData);

      expect(await usdt.balanceOf(user.address)).to.equal(ethers.parseEther("50"));
      expect(await usdt.balanceOf(proxyAddr)).to.equal(ethers.parseEther("50"));
    });

    it("non-owner execute reverts", async function () {
      const { factory, user, otherUser, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr);

      await expect(
        proxy.connect(otherUser).execute(await usdt.getAddress(), 0, "0x"),
      ).to.be.revertedWithCustomError(proxy, "NotOwner");
    });
  });

  describe("ExecuteBatch", function () {
    it("owner can batch execute multiple calls", async function () {
      const { factory, user, usdt, otherUser } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr);

      await usdt.mint(proxyAddr, ethers.parseEther("100"));

      const usdtAddr = await usdt.getAddress();
      const targets = [usdtAddr, usdtAddr];
      const values = [0, 0];
      const datas = [
        usdt.interface.encodeFunctionData("transfer", [user.address, ethers.parseEther("30")]),
        usdt.interface.encodeFunctionData("transfer", [otherUser.address, ethers.parseEther("20")]),
      ];

      await proxy.connect(user).executeBatch(targets, values, datas);

      expect(await usdt.balanceOf(user.address)).to.equal(ethers.parseEther("30"));
      expect(await usdt.balanceOf(otherUser.address)).to.equal(ethers.parseEther("20"));
      expect(await usdt.balanceOf(proxyAddr)).to.equal(ethers.parseEther("50"));
    });

    it("non-owner batch execute reverts", async function () {
      const { factory, user, otherUser } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr);

      await expect(
        proxy.connect(otherUser).executeBatch([], [], []),
      ).to.be.revertedWithCustomError(proxy, "NotOwner");
    });
  });

  describe("ExecuteOnBehalf (meta-tx)", function () {
    it("relayer can execute with owner's EIP-712 signature", async function () {
      const { factory, user, relayer, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      await usdt.mint(proxyAddr, ethers.parseEther("100"));

      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [
        user.address,
        ethers.parseEther("50"),
      ]);
      const nonce = 1;

      // Sign EIP-712 typed data
      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub ProxyWallet",
        version: "1",
        chainId: network.chainId,
        verifyingContract: proxyAddr,
      };

      const types = {
        Execute: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "dataHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
        ],
      };

      const sig = await user.signTypedData(domain, types, {
        target,
        value,
        dataHash: ethers.keccak256(data),
        nonce,
      });

      // Relayer submits
      await proxy.connect(relayer).executeOnBehalf(target, value, data, nonce, sig);

      expect(await usdt.balanceOf(user.address)).to.equal(ethers.parseEther("50"));
    });

    it("replay with same nonce reverts", async function () {
      const { factory, user, relayer, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      await usdt.mint(proxyAddr, ethers.parseEther("200"));

      const target = await usdt.getAddress();
      const data = usdt.interface.encodeFunctionData("transfer", [
        user.address,
        ethers.parseEther("10"),
      ]);
      const nonce = 42;

      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub ProxyWallet",
        version: "1",
        chainId: network.chainId,
        verifyingContract: proxyAddr,
      };
      const types = {
        Execute: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "dataHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
        ],
      };
      const sig = await user.signTypedData(domain, types, {
        target,
        value: 0,
        dataHash: ethers.keccak256(data),
        nonce,
      });

      await proxy.connect(relayer).executeOnBehalf(target, 0, data, nonce, sig);

      // Replay with same nonce
      await expect(
        proxy.connect(relayer).executeOnBehalf(target, 0, data, nonce, sig),
      ).to.be.revertedWithCustomError(proxy, "NonceAlreadyUsed");
    });

    it("forged signature reverts", async function () {
      const { factory, user, otherUser, relayer, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      await usdt.mint(proxyAddr, ethers.parseEther("100"));

      const target = await usdt.getAddress();
      const data = usdt.interface.encodeFunctionData("transfer", [
        otherUser.address,
        ethers.parseEther("100"),
      ]);

      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub ProxyWallet",
        version: "1",
        chainId: network.chainId,
        verifyingContract: proxyAddr,
      };
      const types = {
        Execute: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "dataHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
        ],
      };

      // Sign with otherUser (not the owner)
      const sig = await otherUser.signTypedData(domain, types, {
        target,
        value: 0,
        dataHash: ethers.keccak256(data),
        nonce: 1,
      });

      await expect(
        proxy.connect(relayer).executeOnBehalf(target, 0, data, 1, sig),
      ).to.be.revertedWithCustomError(proxy, "InvalidSignature");
    });
  });

  describe("EIP-1271 isValidSignature", function () {
    it("returns magic value for owner's signature", async function () {
      const { factory, user } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      const hash = ethers.keccak256(ethers.toUtf8Bytes("test message"));
      const sig = await user.signMessage(ethers.getBytes(hash));
      // EIP-191 wraps with personal_sign prefix
      const ethSignedHash = ethers.hashMessage(ethers.getBytes(hash));

      const result = await proxy.isValidSignature(ethSignedHash, sig);
      expect(result).to.equal("0x1626ba7e"); // EIP-1271 magic value
    });

    it("returns 0xffffffff for non-owner signature", async function () {
      const { factory, user, otherUser } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      const hash = ethers.keccak256(ethers.toUtf8Bytes("test message"));
      const sig = await otherUser.signMessage(ethers.getBytes(hash));
      const ethSignedHash = ethers.hashMessage(ethers.getBytes(hash));

      const result = await proxy.isValidSignature(ethSignedHash, sig);
      expect(result).to.equal("0xffffffff");
    });
  });

  describe("Receive ETH", function () {
    it("can receive ETH/BNB", async function () {
      const { factory, user, deployer } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);

      await deployer.sendTransaction({ to: proxyAddr, value: ethers.parseEther("1") });
      const bal = await ethers.provider.getBalance(proxyAddr);
      expect(bal).to.equal(ethers.parseEther("1"));
    });
  });
});

// ===========================================================================
// SafeProxyFactory Tests
// ===========================================================================

describe("SafeProxyFactory", function () {
  describe("Deployment", function () {
    it("stores immutables correctly", async function () {
      const { factory, pwImpl, exchange, usdt, ct } = await loadFixture(proxyFixture);
      expect(await factory.implementation()).to.equal(await pwImpl.getAddress());
      expect(await factory.exchange()).to.equal(await exchange.getAddress());
      expect(await factory.usdt()).to.equal(await usdt.getAddress());
      expect(await factory.conditionalTokens()).to.equal(await ct.getAddress());
    });

    it("reverts with zero address for implementation or exchange", async function () {
      const { usdt, ct } = await loadFixture(proxyFixture);
      const SPF = await ethers.getContractFactory("SafeProxyFactory");

      await expect(
        SPF.deploy(ethers.ZeroAddress, ethers.ZeroAddress, await usdt.getAddress(), await ct.getAddress()),
      ).to.be.revertedWithCustomError(SPF, "ZeroAddress");
    });
  });

  describe("createProxy", function () {
    it("creates proxy and emits ProxyCreated", async function () {
      const { factory, user } = await loadFixture(proxyFixture);

      await expect(factory.createProxy(user.address, ethers.ZeroHash))
        .to.emit(factory, "ProxyCreated");

      expect(await factory.hasProxy(user.address)).to.be.true;
    });

    it("deterministic address matches getProxyAddress", async function () {
      const { factory, user } = await loadFixture(proxyFixture);

      const predicted = await factory.getProxyAddress(user.address, ethers.ZeroHash);
      await factory.createProxy(user.address, ethers.ZeroHash);
      const actual = await factory.proxyOf(user.address);

      expect(actual).to.equal(predicted);
    });

    it("reverts for zero address owner", async function () {
      const { factory } = await loadFixture(proxyFixture);

      await expect(
        factory.createProxy(ethers.ZeroAddress, ethers.ZeroHash),
      ).to.be.revertedWithCustomError(factory, "ZeroAddress");
    });

    it("reverts on duplicate proxy for same owner", async function () {
      const { factory, user } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);

      await expect(
        factory.createProxy(user.address, ethers.ZeroHash),
      ).to.be.revertedWithCustomError(factory, "ProxyAlreadyExists");
    });

    it("different owners get different proxy addresses", async function () {
      const { factory, user, otherUser } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      await factory.createProxy(otherUser.address, ethers.ZeroHash);

      const proxy1 = await factory.proxyOf(user.address);
      const proxy2 = await factory.proxyOf(otherUser.address);

      expect(proxy1).to.not.equal(proxy2);
    });
  });

  describe("hasProxy", function () {
    it("returns false before creation", async function () {
      const { factory, user } = await loadFixture(proxyFixture);
      expect(await factory.hasProxy(user.address)).to.be.false;
    });

    it("returns true after creation", async function () {
      const { factory, user } = await loadFixture(proxyFixture);
      await factory.createProxy(user.address, ethers.ZeroHash);
      expect(await factory.hasProxy(user.address)).to.be.true;
    });
  });
});
