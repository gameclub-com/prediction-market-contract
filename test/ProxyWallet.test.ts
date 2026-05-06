import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";

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
  const ct = await upgrades.deployProxy(CT, [await usdt.getAddress(), treasury.address, deployer.address], {
    kind: 'uups', initializer: 'initialize',
  });

  const MR = await ethers.getContractFactory("MarketRegistry");
  const registry = await upgrades.deployProxy(MR, [await ct.getAddress()], {
    kind: 'uups', initializer: 'initialize',
  });

  const Exchange = await ethers.getContractFactory("ExchangeCLOB");
  const exchange = await upgrades.deployProxy(Exchange, [
    await usdt.getAddress(), await ct.getAddress(), await registry.getAddress(),
    feeCollector.address, treasury.address
  ], { kind: 'uups', initializer: 'initialize' });

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
    deployer.address,
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
          { name: "deadline", type: "uint256" },
        ],
      };

      const sig = await user.signTypedData(domain, types, {
        target,
        value,
        dataHash: ethers.keccak256(data),
        nonce,
        deadline: 0,
      });

      // Relayer submits
      await proxy.connect(relayer).executeOnBehalf(target, value, data, nonce, 0, sig);

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
          { name: "deadline", type: "uint256" },
        ],
      };
      const sig = await user.signTypedData(domain, types, {
        target,
        value: 0,
        dataHash: ethers.keccak256(data),
        nonce,
        deadline: 0,
      });

      await proxy.connect(relayer).executeOnBehalf(target, 0, data, nonce, 0, sig);

      // Replay with same nonce
      await expect(
        proxy.connect(relayer).executeOnBehalf(target, 0, data, nonce, 0, sig),
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
          { name: "deadline", type: "uint256" },
        ],
      };

      // Sign with otherUser (not the owner)
      const sig = await otherUser.signTypedData(domain, types, {
        target,
        value: 0,
        dataHash: ethers.keccak256(data),
        nonce: 1,
        deadline: 0,
      });

      await expect(
        proxy.connect(relayer).executeOnBehalf(target, 0, data, 1, 0, sig),
      ).to.be.revertedWithCustomError(proxy, "InvalidSignature");
    });
  });

  describe("ExecuteBatchOnBehalf (meta-tx batch)", function () {
    it("relayer can batch-execute with owner's EIP-712 ExecuteBatch signature", async function () {
      const { factory, user, relayer, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      // Mint USDT to proxy
      await usdt.mint(proxyAddr, ethers.parseEther("100"));

      const usdtAddr = await usdt.getAddress();

      // Build batch: [transfer 30 to user, transfer 20 to relayer]
      const data1 = usdt.interface.encodeFunctionData("transfer", [user.address, ethers.parseEther("30")]);
      const data2 = usdt.interface.encodeFunctionData("transfer", [relayer.address, ethers.parseEther("20")]);

      const targets = [usdtAddr, usdtAddr];
      const values = [0n, 0n];
      const datas = [data1, data2];
      const nonce = BigInt(Date.now()); // Same as frontend uses

      // Sign EIP-712 ExecuteBatch — match EXACTLY what the frontend does
      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub ProxyWallet",
        version: "1",
        chainId: network.chainId,
        verifyingContract: proxyAddr,
      };

      const batchTypes = {
        ExecuteBatch: [
          { name: "targetsHash", type: "bytes32" },
          { name: "valuesHash", type: "bytes32" },
          { name: "datasHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };
      const deadline = 0n;

      // Compute hashes the same way as frontend (useProxyWallet.ts)
      // NOTE: Solidity abi.encodePacked(address[]) pads each address to 32 bytes
      const targetsHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
        targets.map(() => "address"),
        targets,
      ));
      const valuesHash = ethers.keccak256(ethers.solidityPacked(
        values.map(() => "uint256"),
        values,
      ));
      const dataHashes = datas.map((d: string) => ethers.keccak256(d));
      const datasHash = ethers.keccak256(ethers.solidityPacked(
        dataHashes.map(() => "bytes32"),
        dataHashes,
      ));

      const sig = await user.signTypedData(domain, batchTypes, {
        targetsHash,
        valuesHash,
        datasHash,
        nonce,
        deadline,
      });

      // Relayer submits batch on behalf
      await proxy.connect(relayer).executeBatchOnBehalf(targets, values, datas, nonce, deadline, sig);

      expect(await usdt.balanceOf(user.address)).to.equal(ethers.parseEther("30"));
      expect(await usdt.balanceOf(relayer.address)).to.equal(ethers.parseEther("20"));
    });

    it("batch on behalf with wrong signer reverts", async function () {
      const { factory, user, relayer, otherUser, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      await usdt.mint(proxyAddr, ethers.parseEther("100"));
      const usdtAddr = await usdt.getAddress();

      const data1 = usdt.interface.encodeFunctionData("transfer", [user.address, ethers.parseEther("10")]);
      const targets = [usdtAddr];
      const values = [0n];
      const datas = [data1];
      const nonce = 999n;

      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub ProxyWallet",
        version: "1",
        chainId: network.chainId,
        verifyingContract: proxyAddr,
      };
      const batchTypes = {
        ExecuteBatch: [
          { name: "targetsHash", type: "bytes32" },
          { name: "valuesHash", type: "bytes32" },
          { name: "datasHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };
      const deadline = 0n;

      const targetsHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address"], targets));
      const valuesHash = ethers.keccak256(ethers.solidityPacked(["uint256"], values));
      const datasHash = ethers.keccak256(ethers.solidityPacked(["bytes32"], [ethers.keccak256(data1)]));

      // Sign with otherUser (not the owner)
      const sig = await otherUser.signTypedData(domain, batchTypes, {
        targetsHash, valuesHash, datasHash, nonce, deadline,
      });

      await expect(
        proxy.connect(relayer).executeBatchOnBehalf(targets, values, datas, nonce, deadline, sig),
      ).to.be.revertedWithCustomError(proxy, "InvalidSignature");
    });

    it("failed batch execution consumes nonce and emits failure event", async function () {
      const { factory, user, relayer, usdt } = await loadFixture(proxyFixture);

      await factory.createProxy(user.address, ethers.ZeroHash);
      const proxyAddr = await factory.proxyOf(user.address);
      const PW = await ethers.getContractFactory("ProxyWallet");
      const proxy = PW.attach(proxyAddr) as any;

      const targets = [await usdt.getAddress()];
      const values = [0n];
      const datas = [
        usdt.interface.encodeFunctionData("transfer", [user.address, ethers.parseEther("1")]),
      ];
      const nonce = 777n;
      const deadline = 0n;

      const network = await ethers.provider.getNetwork();
      const domain = {
        name: "GameClub ProxyWallet",
        version: "1",
        chainId: network.chainId,
        verifyingContract: proxyAddr,
      };
      const batchTypes = {
        ExecuteBatch: [
          { name: "targetsHash", type: "bytes32" },
          { name: "valuesHash", type: "bytes32" },
          { name: "datasHash", type: "bytes32" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };
      const targetsHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address"], targets));
      const valuesHash = ethers.keccak256(ethers.solidityPacked(["uint256"], values));
      const datasHash = ethers.keccak256(ethers.solidityPacked(["bytes32"], [ethers.keccak256(datas[0])]));

      const sig = await user.signTypedData(domain, batchTypes, {
        targetsHash, valuesHash, datasHash, nonce, deadline,
      });

      await expect(
        proxy.connect(relayer).executeBatchOnBehalf(targets, values, datas, nonce, deadline, sig)
      ).to.emit(proxy, "BatchExecutionFailed");

      expect(await proxy.usedNonces(nonce)).to.equal(true);
      await expect(
        proxy.connect(relayer).executeBatchOnBehalf(targets, values, datas, nonce, deadline, sig)
      ).to.be.revertedWithCustomError(proxy, "NonceAlreadyUsed");
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

  // ── Audit v2 M-9: Zero-owner check ──
  describe("Audit v2 M-9. initialize with zero owner", function () {
    it("initialize with zero owner reverts", async function () {
      const { factory } = await loadFixture(proxyFixture);

      await expect(
        factory.createProxy(ethers.ZeroAddress, ethers.ZeroHash),
      ).to.be.revertedWithCustomError(factory, "ZeroAddress");
    });
  });

  // ── Audit v2 L-5: Implementation contract locked ──
  describe("Audit v2 L-5. Implementation contract cannot be re-initialized", function () {
    it("implementation contract cannot be initialized", async function () {
      const { pwImpl, user } = await loadFixture(proxyFixture);

      await expect(
        pwImpl.initialize(user.address, "0x"),
      ).to.be.revertedWithCustomError(pwImpl, "AlreadyInitialized");
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
      const { usdt, ct, deployer } = await loadFixture(proxyFixture);
      const SPF = await ethers.getContractFactory("SafeProxyFactory");

      await expect(
        SPF.deploy(ethers.ZeroAddress, ethers.ZeroAddress, await usdt.getAddress(), await ct.getAddress(), deployer.address),
      ).to.be.revertedWithCustomError(SPF, "ZeroAddress");
    });

    // Audit v2 L-1: Zero-address checks for usdt and conditionalTokens
    it("reverts with zero usdt address", async function () {
      const { pwImpl, exchange, deployer } = await loadFixture(proxyFixture);
      const SPF = await ethers.getContractFactory("SafeProxyFactory");

      await expect(
        SPF.deploy(await pwImpl.getAddress(), await exchange.getAddress(), ethers.ZeroAddress, ethers.ZeroAddress, deployer.address),
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
