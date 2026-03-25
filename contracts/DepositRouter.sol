// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./Roles.sol";

/// @title DepositRouter — Gasless deposits via EIP-712 signed intents
/// @notice Users approve this contract once for USDT. Subsequent deposits require
///         only an off-chain EIP-712 signature. The Relayer submits the signed intent
///         and this contract transfers USDT from the user's EOA to their ProxyWallet.
/// @dev Only accounts with RELAYER_ROLE can call depositOnBehalf().
///      DEFAULT_ADMIN_ROLE controls role management and emergency functions.
contract DepositRouter is Initializable, AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── EIP-712 Constants ───
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant HASHED_NAME = keccak256("GameClub DepositRouter");
    bytes32 private constant HASHED_VERSION = keccak256("1");

    bytes32 public constant DEPOSIT_TYPEHASH =
        keccak256("Deposit(address from,address to,uint256 amount,uint256 nonce,uint256 deadline)");

    // ─── State ───
    IERC20 public usdt; // was immutable

    /// @notice Per-user nonce for replay protection (monotonically increasing).
    mapping(address => uint256) public nonces;

    // ─── Events ───
    event DepositExecuted(address indexed from, address indexed to, uint256 amount, uint256 nonce);

    // ─── Errors ───
    error InvalidSignature();
    error ExpiredDeadline();
    error ZeroAmount();
    error ZeroAddress();

    // ─── Domain Separator Caching ───
    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdt, address _admin) external initializer {
        if (_usdt == address(0) || _admin == address(0)) revert ZeroAddress();

        __AccessControlEnumerable_init();

        usdt = IERC20(_usdt);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _computeDomainSeparator();
    }

    // ─── UUPS Authorization ───
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─── Core: Gasless Deposit ───

    /// @notice Execute a gasless deposit on behalf of a user.
    /// @dev Only callable by RELAYER_ROLE. Transfers USDT from `from` to `to` (ProxyWallet).
    ///      The user must have approved this contract for sufficient USDT.
    /// @param from     User's EOA (who signed the deposit intent)
    /// @param to       Destination address (user's ProxyWallet)
    /// @param amount   USDT amount (18 decimals)
    /// @param deadline Unix timestamp after which the signature is invalid
    /// @param signature EIP-712 signature from `from`
    function depositOnBehalf(
        address from,
        address to,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external onlyRole(Roles.RELAYER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert ExpiredDeadline();

        uint256 nonce = nonces[from];

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(
            abi.encode(DEPOSIT_TYPEHASH, from, to, amount, nonce, deadline)
        );
        bytes32 digest = _hashTypedData(structHash);
        address signer = digest.recover(signature);

        if (signer != from) revert InvalidSignature();

        // Increment nonce (replay protection)
        nonces[from] = nonce + 1;

        // Transfer USDT from user's EOA to their ProxyWallet
        usdt.safeTransferFrom(from, to, amount);

        emit DepositExecuted(from, to, amount, nonce);
    }

    // ─── View Functions ───

    /// @notice Returns the current nonce for a user (use this when building the signature).
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /// @notice Returns the EIP-712 domain separator.
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == _cachedChainId) {
            return _cachedDomainSeparator;
        }
        return _computeDomainSeparator();
    }

    // ─── Emergency ───

    /// @notice Recover tokens accidentally sent to this contract.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. This contract should never hold tokens.
    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }

    // ─── Internal ───

    function _hashTypedData(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, HASHED_NAME, HASHED_VERSION, block.chainid, address(this))
        );
    }

    // ─── Storage Gap ───
    uint256[49] private __gap;
}
