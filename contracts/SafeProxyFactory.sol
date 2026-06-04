// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "./ProxyWallet.sol";
import "./ConditionalTokens.sol";

/// @title SafeProxyFactory — Deterministic proxy wallet factory (Polymarket-style)
/// @notice Creates EIP-1167 minimal proxy wallets for each user via CREATE2.
///         Each proxy is a ProxyWallet (1-of-1 owner, EIP-1271 signatures).
/// @dev Addresses are deterministic: getProxyAddress(owner, salt) == createProxy(owner, salt).
contract SafeProxyFactory {
    using Clones for address;

    // ─── State ───
    address public immutable implementation;
    address public immutable exchange;
    address public immutable deployer;
    IERC20 public immutable usdt;
    ConditionalTokens public immutable conditionalTokens;

    mapping(address => address) public proxyOf; // owner => proxy (1:1 mapping)

    // ─── Events ───
    event ProxyCreated(address indexed proxy, address indexed owner, bytes32 salt);

    // ─── Errors ───
    error ProxyAlreadyExists(address owner, address existing);
    error ZeroAddress();
    error Unauthorized();
    // QGM-53 fix: enforce the documented EOA-owner model.
    error OwnerNotEOA(address owner);

    constructor(
        address _implementation,
        address _exchange,
        address _usdt,
        address _conditionalTokens,
        address _deployer
    ) {
        // L-1 v2: Zero-address checks for all params
        if (_implementation == address(0) || _exchange == address(0) || _usdt == address(0) || _conditionalTokens == address(0) || _deployer == address(0)) revert ZeroAddress();
        implementation = _implementation;
        exchange = _exchange;
        deployer = _deployer;
        usdt = IERC20(_usdt);
        conditionalTokens = ConditionalTokens(_conditionalTokens);
    }

    /// @notice Create a proxy wallet for `owner` with deterministic address.
    /// @param owner The EOA that will own the proxy wallet.
    /// @param salt Retained for ABI/back-compat ONLY — it does NOT affect the deployed
    ///        address (QGM-50: one canonical proxy per owner). Pass 0.
    /// @return proxy The deployed proxy wallet address.
    /// @dev QGM-50 fix: the CREATE2 salt is derived solely from `owner`, so there is exactly
    ///      one deployable address per owner and getProxyAddress(owner, *) always predicts it.
    ///      QGM-53 (partial, on-chain): `owner` must have no contract code, which blocks the
    ///      common case of an already-deployed contract wallet being set as owner. This is a
    ///      BEST-EFFORT EOA check, NOT a guarantee: an address mid-construction, or a not-yet-
    ///      deployed CREATE2 address, has zero code at call time and can still pass. Therefore
    ///      the authoritative control for beneficial-owner sanctions remains OPERATIONAL — the
    ///      RELAYER (settleBatch is RELAYER_ROLE-gated) must screen the beneficial owner of
    ///      proxy makers off-chain (see ExchangeCLOB._validateOrder QGM-53 note).
    function createProxy(address owner, bytes32 salt) external returns (address proxy) {
        if (msg.sender != owner && msg.sender != deployer) revert Unauthorized();
        if (owner == address(0)) revert ZeroAddress();
        if (owner.code.length != 0) revert OwnerNotEOA(owner);
        if (proxyOf[owner] != address(0)) revert ProxyAlreadyExists(owner, proxyOf[owner]);

        bytes32 finalSalt = keccak256(abi.encodePacked(owner));
        proxy = implementation.cloneDeterministic(finalSalt);

        // Encode auto-approve setup data so the proxy grants:
        //   [0] USDT max allowance to Exchange (for buy-side settlement debits)
        //   [1] ERC1155 operator approval to Exchange (for share transfers during fills)
        //   [2] ERC1155 operator approval to ConditionalTokens itself (QGM-38 fix: enables
        //       admin `redeemPositionsFor` recovery flow now that the function enforces
        //       `isApprovedForAll(holder, address(this))`).
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory datas = new bytes[](3);

        targets[0] = address(usdt);
        values[0] = 0;
        datas[0] = abi.encodeWithSelector(IERC20.approve.selector, exchange, type(uint256).max);

        targets[1] = address(conditionalTokens);
        values[1] = 0;
        datas[1] = abi.encodeWithSelector(
            IERC1155.setApprovalForAll.selector,
            exchange,
            true
        );

        // QGM-38 fix: opt-in to admin redeem path at proxy creation. ProxyWallet
        // approves the ConditionalTokens contract itself as an operator so that
        // `ConditionalTokens.redeemPositionsFor(...)` can burn the proxy's shares.
        targets[2] = address(conditionalTokens);
        values[2] = 0;
        datas[2] = abi.encodeWithSelector(
            IERC1155.setApprovalForAll.selector,
            address(conditionalTokens),
            true
        );

        bytes memory setupData = abi.encode(targets, values, datas);

        // Initialize with owner + auto-approvals
        ProxyWallet(payable(proxy)).initialize(owner, setupData);

        // Store mapping
        proxyOf[owner] = proxy;

        emit ProxyCreated(proxy, owner, salt);
    }

    /// @notice Predict the proxy address without deploying.
    /// @dev QGM-50 fix: `salt` is ignored (canonical, owner-only derivation). Once a proxy
    ///      has been created, returns the actually-deployed address so the prediction always
    ///      reflects the single deployable/deployed proxy for the owner.
    function getProxyAddress(address owner, bytes32 /* salt */) external view returns (address) {
        address existing = proxyOf[owner];
        if (existing != address(0)) return existing;
        return implementation.predictDeterministicAddress(keccak256(abi.encodePacked(owner)), address(this));
    }

    /// @notice Check if a proxy exists for the given owner.
    function hasProxy(address owner) external view returns (bool) {
        return proxyOf[owner] != address(0);
    }
}
