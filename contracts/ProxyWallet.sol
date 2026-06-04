// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @title ProxyWallet — Minimal 1-of-1 proxy wallet (Polymarket-style)
/// @notice Each user gets one proxy wallet. Owner can execute arbitrary calls.
///         Supports EIP-1271 for smart-account signature verification on Exchange.
/// @dev Used as implementation for EIP-1167 minimal proxies created by SafeProxyFactory.
contract ProxyWallet is IERC1271, ERC1155Holder {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── EIP-712 Constants ───
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant HASHED_NAME = keccak256("GameClub ProxyWallet");
    bytes32 private constant HASHED_VERSION = keccak256("1");

    bytes32 public constant EXECUTE_TYPEHASH =
        keccak256("Execute(address target,uint256 value,bytes32 dataHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant EXECUTE_BATCH_TYPEHASH =
        keccak256("ExecuteBatch(bytes32 targetsHash,bytes32 valuesHash,bytes32 datasHash,uint256 nonce,uint256 deadline)");

    // ─── Storage ───
    address public owner;
    bool private initialized;
    mapping(uint256 => bool) public usedNonces;

    // G-4: Cached domain separator
    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;

    // ─── Errors ───
    error AlreadyInitialized();
    error NotOwner();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error CallFailed(bytes returnData);
    error SetupCallFailed(uint256 index, bytes returnData);
    error DeadlineExpired();

    // ─── Events ───
    event Executed(address indexed target, uint256 value, bytes data);
    event ExecutionFailed(uint256 indexed nonce, address indexed target, uint256 value, bytes data, bytes returnData);

    // L-5 v2: Lock implementation contract (prevent initialization of the template)
    constructor() {
        initialized = true;
    }

    // ─── Initializer (called once by factory) ───
    /// @param _owner The EOA that will own this proxy wallet.
    /// @param setupData Optional ABI-encoded (address[], uint256[], bytes[]) executed
    ///        during init — used by the factory to auto-approve Exchange for USDT & CT.
    function initialize(address _owner, bytes calldata setupData) external {
        if (initialized) revert AlreadyInitialized();
        // M-9 v2: Zero-owner check
        require(_owner != address(0), "Zero owner");
        initialized = true;
        owner = _owner;

        // G-4: Cache domain separator after address is known (clone)
        _cacheDomainSeparator();

        if (setupData.length > 0) {
            (
                address[] memory targets,
                uint256[] memory values,
                bytes[] memory datas
            ) = abi.decode(setupData, (address[], uint256[], bytes[]));
            require(targets.length == values.length && values.length == datas.length, "length mismatch");
            for (uint256 i = 0; i < targets.length;) {
                (bool success, bytes memory result) = targets[i].call{value: values[i]}(datas[i]);
                if (!success) revert SetupCallFailed(i, result);
                unchecked { i++; }
            }
        }
    }

    // ─── Execute arbitrary call (owner only) ───
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != owner) revert NotOwner();
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) revert CallFailed(result);
        emit Executed(target, value, data);
        return result;
    }

    // ─── Batch execute ───
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external returns (bytes[] memory results) {
        if (msg.sender != owner) revert NotOwner();
        require(targets.length == values.length && values.length == datas.length, "length mismatch");
        results = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length;) {
            (bool success, bytes memory result) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(result);
            results[i] = result;
            unchecked { i++; }
        }
    }

    // ─── Meta-transaction: executeOnBehalf (relayer submits owner's signed intent) ───
    /// @param target  The address to call
    /// @param value   The ETH value to send
    /// @param data    The calldata to send
    /// @param nonce   A unique nonce for replay protection
    /// @param deadline  Expiration timestamp (0 = no expiry)
    /// @param ownerSignature  The owner's EIP-712 signature
    function executeOnBehalf(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        bytes calldata ownerSignature
    ) external returns (bytes memory) {
        if (usedNonces[nonce]) revert NonceAlreadyUsed();
        if (deadline > 0 && block.timestamp > deadline) revert DeadlineExpired();

        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_TYPEHASH, target, value, keccak256(data), nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(ownerSignature);
        if (signer != owner) revert InvalidSignature();

        usedNonces[nonce] = true;

        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            emit ExecutionFailed(nonce, target, value, data, result);
            return result;
        }
        emit Executed(target, value, data);
        return result;
    }

    // ─── Meta-transaction: executeBatchOnBehalf ───
    /// @notice Batch version of executeOnBehalf.
    /// @dev QGM-49 fix: execution is ATOMIC — a failed subcall reverts the whole
    ///      transaction (matching `executeBatch()`), so earlier subcalls are rolled
    ///      back and the signed `nonce` is NOT consumed. This removes the previous
    ///      partial-execution semantics where a relayer could commit the early
    ///      subcalls of an owner-signed batch while permanently burning the nonce.
    /// @param targets  Array of addresses to call
    /// @param values   Array of ETH values
    /// @param datas    Array of calldata payloads
    /// @param nonce    A unique nonce for replay protection
    /// @param ownerSignature  The owner's EIP-712 signature
    function executeBatchOnBehalf(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        uint256 nonce,
        uint256 deadline,
        bytes calldata ownerSignature
    ) external returns (bytes[] memory results) {
        if (usedNonces[nonce]) revert NonceAlreadyUsed();
        if (deadline > 0 && block.timestamp > deadline) revert DeadlineExpired();
        require(targets.length == values.length && values.length == datas.length, "length mismatch");

        _verifyBatchSignature(targets, values, datas, nonce, deadline, ownerSignature);
        usedNonces[nonce] = true;

        results = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length;) {
            (bool ok, bytes memory res) = targets[i].call{value: values[i]}(datas[i]);
            if (!ok) revert CallFailed(res);
            results[i] = res;
            unchecked { i++; }
        }
    }

    // ─── Internal: batch signature verification (split out to avoid stack-too-deep) ───
    function _verifyBatchSignature(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        uint256 nonce,
        uint256 deadline,
        bytes calldata ownerSignature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_BATCH_TYPEHASH,
                keccak256(abi.encodePacked(targets)),
                keccak256(abi.encodePacked(values)),
                _hashBytesArray(datas),
                nonce,
                deadline
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(ownerSignature);
        if (signer != owner) revert InvalidSignature();
    }

    // ─── EIP-712 Helpers ───
    /// @dev G-4: Cached domain separator with chainId invalidation.
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == _cachedChainId && _cachedDomainSeparator != bytes32(0)) {
            return _cachedDomainSeparator;
        }
        return _computeDomainSeparator();
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, HASHED_NAME, HASHED_VERSION, block.chainid, address(this))
        );
    }

    /// @dev Cache the domain separator after initialization.
    function _cacheDomainSeparator() private {
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _computeDomainSeparator();
    }

    /// @dev Hashes the struct data with the EIP-712 prefix and domain separator.
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), structHash);
    }

    /// @dev Hashes an array of bytes elements for batch struct hashing.
    function _hashBytesArray(bytes[] calldata arr) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length;) {
            hashes[i] = keccak256(arr[i]);
            unchecked { i++; }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    // ─── EIP-1271: Signature verification ───
    /// @dev Validates that the signature was produced by the owner.
    ///      Exchange calls this during settleBatch to verify order signatures.
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return IERC1271.isValidSignature.selector; // 0x1626ba7e
        }
        return bytes4(0xffffffff);
    }

    // ─── Receive ETH/BNB ───
    receive() external payable {}

    // ─── ERC1155 + ERC165 ───
    function supportsInterface(bytes4 interfaceId)
        public view override(ERC1155Holder) returns (bool)
    {
        return interfaceId == type(IERC1271).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
