// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Option C: forward declaration of MarketRegistry hook interface
interface IMarketRegistryOIHook {
    function addOIByCondition(bytes32 conditionId, uint256 oi) external;
    function subtractOIByCondition(bytes32 conditionId, uint256 oi) external;
}

/// @title ConditionalTokens — ERC1155 outcome tokens for prediction markets
/// @notice v2: AccessControl 기반 역할 관리. outcomeSlotCount == 2 only. Gnosis CTF-style.
contract ConditionalTokens is Initializable, ERC1155Upgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ─── Errors ───
    error ConditionAlreadyPrepared(bytes32 conditionId);
    error ConditionNotFound(bytes32 conditionId);
    error InvalidOutcomeSlotCount(uint256 count);
    error ConditionNotResolved(bytes32 conditionId);
    error ConditionAlreadyResolved(bytes32 conditionId);
    error InvalidPayoutsLength(uint256 expected, uint256 actual);
    error ZeroAmount();
    error PayoutBelowMinRedeem(uint256 payout, uint256 minRedeem);
    error InvalidOracleAddress();
    // QGM-37 fix: gate for protocol-owned conditions
    error OnlyRegistryForOfficialCondition();
    // QGM-38 fix: holder approval enforcement
    error HolderApprovalRequired(address holder);

    // ─── Events ───
    event ConditionPrepared(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount
    );
    event ConditionResolved(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256[] payoutNumerators
    );
    event PositionSplit(
        address indexed stakeholder,
        bytes32 indexed conditionId,
        uint256 amount
    );
    event PositionsMerged(
        address indexed stakeholder,
        bytes32 indexed conditionId,
        uint256 amount
    );
    event PayoutRedemption(
        address indexed redeemer,
        bytes32 indexed conditionId,
        uint256[] indexSets,
        uint256 payout
    );
    event DustToTreasury(
        address indexed user,
        bytes32 indexed conditionId,
        uint256 amount
    );
    event ZeroSupplyToTreasury(
        bytes32 indexed conditionId,
        uint256 amount
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ─── Constants ───
    uint256 public constant MIN_REDEEM = 0.001e18; // 0.001 USDT (supports 0.01 USDT markets)

    // ─── Reentrancy Guard (inline — OZ v5 removed ReentrancyGuardUpgradeable) ───
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ─── State ───
    // ⚠️ Storage layout: 아래 3개 변수 순서/타입 절대 변경 금지 (기존 프록시 호환)
    IERC20 public collateralToken; // USDT (was immutable)
    address public treasury;
    address public admin; // V1 upgrade authority — V2에서 deprecated (AccessControl로 대체)

    // conditionId => outcome payouts
    mapping(bytes32 => uint256[]) public payoutNumerators;
    mapping(bytes32 => uint256) public payoutDenominator;

    // conditionId => oracle
    mapping(bytes32 => address) public conditionOracles;
    // conditionId => outcomeSlotCount
    mapping(bytes32 => uint256) public conditionOutcomeSlotCounts;
    // conditionId => resolved
    mapping(bytes32 => bool) public isResolved;

    // reverse mapping: positionId => conditionId + indexSet
    mapping(uint256 => bytes32) public positionConditionId;
    mapping(uint256 => uint256) public positionIndexSet;

    // C-1: Per-condition collateral accounting
    mapping(bytes32 => uint256) public conditionCollateral;

    // ─── Option C: Protocol-wide OI sync (append-only storage) ───
    /// @notice MarketRegistry address — set via initializeVx(). When set, splitPosition / mergePositions
    ///         call the registry's OI sync hooks. When unset (zero), hooks are skipped (back-compat).
    IMarketRegistryOIHook public marketRegistry;
    /// @notice Per-user, per-positionId eligibility for OI decrement.
    ///         Granted on splitPosition mint, moved on ERC1155 transfer, burned on mergePositions / redeem.
    mapping(address => mapping(uint256 => uint256)) public oiEligibleShares;

    // ─── Option C events ───
    event MarketRegistrySet(address indexed registry);
    event OIEligibilityMoved(address indexed from, address indexed to, uint256 indexed posId, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _collateralToken, address _treasury, address _admin) external initializer {
        require(_collateralToken != address(0), "Zero collateralToken");
        require(_treasury != address(0), "Zero treasury");
        require(_admin != address(0), "Zero admin");

        __ERC1155_init("");
        __AccessControl_init();
        _reentrancyStatus = _NOT_ENTERED;

        collateralToken = IERC20(_collateralToken);
        treasury = _treasury;
        admin = _admin;

        // V2: AccessControl 역할 설정
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice V2 마이그레이션: 기존 배포된 프록시에서 AccessControl 활성화.
    ///         reinitializer(2) 보장 — 한 번만 실행 가능.
    ///         기존 admin(=deployer)이 upgradeToAndCall()로 호출.
    /// @param _newAdmin AccessControl의 DEFAULT_ADMIN_ROLE을 받을 주소 (Timelock/Multisig)
    /// @dev QGM-51 fix: `reinitializer` only guarantees once-per-version, not WHO may call it.
    ///      AccessControl is not yet active here, so we authenticate against the V1 upgrade
    ///      authority (`admin`, set in initialize()/V1). This blocks an attacker from
    ///      front-running the migration and granting themselves DEFAULT_ADMIN_ROLE if the
    ///      upgrade and this call are not executed atomically via upgradeToAndCall.
    function migrateToAccessControl(address _newAdmin) external reinitializer(2) {
        require(msg.sender == admin, "Not admin");
        require(_newAdmin != address(0), "Zero admin");
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _newAdmin);
        // 기존 admin 변수는 storage layout 보존을 위해 건드리지 않음.
        // _authorizeUpgrade가 role 기반으로 변경되었으므로 admin 변수는 더 이상 사용되지 않음.
    }

    /// @notice V3 (Option C): wire ConditionalTokens to MarketRegistry for protocol-wide OI sync.
    /// @dev    reinitializer(3) — one-time only. Called after upgrading to V3 implementation.
    ///         Registry must be set BEFORE splitPosition / mergePositions are called for OI tracking.
    ///         If skipped, OI sync is silently disabled (back-compat).
    /// @dev    QGM-51 fix: gated on DEFAULT_ADMIN_ROLE. By the time reinitializer(3) runs,
    ///         AccessControl is always active (set in initialize() or migrateToAccessControl()),
    ///         so this prevents an attacker from front-running the V3 wiring to consume the
    ///         reinitializer slot and point `marketRegistry` at a malicious/inert address.
    function initializeVx(address _marketRegistry) external reinitializer(3) onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_marketRegistry != address(0), "Zero registry");
        marketRegistry = IMarketRegistryOIHook(_marketRegistry);
        emit MarketRegistrySet(_marketRegistry);
    }

    // ─── UUPS Authorization (V2: role 기반) ───
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─── Treasury setter (V2: role 기반) ───

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Zero address");
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    // ─── sweepZeroSupply (V2: role 기반) ───
    // treasury → DEFAULT_ADMIN_ROLE로 변경하여 Timelock이 관리 가능

    // ─── Condition Management ───

    function prepareCondition(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external returns (bytes32) {
        if (oracle == address(0)) revert InvalidOracleAddress();
        if (outcomeSlotCount != 2) revert InvalidOutcomeSlotCount(outcomeSlotCount);

        // QGM-37 fix: official conditions (oracle == MarketRegistry) can only be prepared by the registry.
        // Non-protocol conditions (different oracle) remain permissionless for Gnosis-CTF style usage.
        if (address(marketRegistry) != address(0) && oracle == address(marketRegistry)) {
            if (msg.sender != address(marketRegistry)) revert OnlyRegistryForOfficialCondition();
        }

        bytes32 conditionId = getConditionId(oracle, questionId, outcomeSlotCount);
        if (conditionOutcomeSlotCounts[conditionId] != 0) {
            revert ConditionAlreadyPrepared(conditionId);
        }

        conditionOutcomeSlotCounts[conditionId] = outcomeSlotCount;
        conditionOracles[conditionId] = oracle;

        emit ConditionPrepared(conditionId, oracle, questionId, outcomeSlotCount);
        return conditionId;
    }

    // ─── Split / Merge ───

    function splitPosition(
        bytes32 conditionId,
        uint256 amount
    ) external nonReentrant {
        // QGM-36 fix: nonReentrant added — _mint triggers ERC1155 receiver hook which
        // previously allowed reentrant mergePositions() to read stale oiEligibleShares
        // and bypass OI decrement, leading to currentOI inflation.
        if (amount == 0) revert ZeroAmount();
        if (conditionOutcomeSlotCounts[conditionId] == 0) revert ConditionNotFound(conditionId);
        if (isResolved[conditionId]) revert ConditionAlreadyResolved(conditionId);

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // C-1: Track collateral per condition
        conditionCollateral[conditionId] += amount;

        uint256 outcomeSlotCount = conditionOutcomeSlotCounts[conditionId];
        for (uint256 i = 0; i < outcomeSlotCount;) {
            uint256 indexSet = 1 << i;
            uint256 posId = getPositionId(address(collateralToken), getCollectionId(conditionId, indexSet));

            // Store reverse mapping on first mint
            if (positionConditionId[posId] == bytes32(0)) {
                positionConditionId[posId] = conditionId;
                positionIndexSet[posId] = indexSet;
            }

            // QGM-36 fix (CEI): grant OI eligibility BEFORE _mint so the receiver hook
            // cannot observe a half-initialized state where some outcomes have eligibility
            // and others don't.
            oiEligibleShares[msg.sender][posId] += amount;
            _mint(msg.sender, posId, amount, "");
            unchecked { i++; }
        }

        // Option C: hook into MarketRegistry for protocol-wide OI tracking + maxOI cap
        // No-op when registry is unset (back-compat) or condition is not registered as a market.
        if (address(marketRegistry) != address(0)) {
            marketRegistry.addOIByCondition(conditionId, amount);
        }

        emit PositionSplit(msg.sender, conditionId, amount);
    }

    function mergePositions(
        bytes32 conditionId,
        uint256 amount
    ) external nonReentrant {
        // QGM-36 fix: nonReentrant added (defense in depth alongside CEI).
        if (amount == 0) revert ZeroAmount();
        if (conditionOutcomeSlotCounts[conditionId] == 0) revert ConditionNotFound(conditionId);

        uint256 outcomeSlotCount = conditionOutcomeSlotCounts[conditionId];

        // Option C: compute OI decrement = min(burnAmount, eligibility on each outcome).
        // For binary markets (outcomeSlotCount == 2) we burn `amount` of each outcome,
        // so the OI decrement is bounded by the smaller eligibility across both outcomes.
        uint256 minEligible = type(uint256).max;
        for (uint256 i = 0; i < outcomeSlotCount;) {
            uint256 indexSet = 1 << i;
            uint256 posId = getPositionId(address(collateralToken), getCollectionId(conditionId, indexSet));
            uint256 elig = oiEligibleShares[msg.sender][posId];
            if (elig < minEligible) minEligible = elig;
            unchecked { i++; }
        }
        uint256 oiDecrement = minEligible < amount ? minEligible : amount;

        for (uint256 i = 0; i < outcomeSlotCount;) {
            uint256 indexSet = 1 << i;
            uint256 posId = getPositionId(address(collateralToken), getCollectionId(conditionId, indexSet));
            // QGM-36 fix (CEI): consume eligibility BEFORE _burn so the burn observes
            // the post-decrement state. (Burn itself doesn't trigger receiver hook, but
            // keeping CEI consistent across split/merge simplifies the mental model.)
            if (oiDecrement > 0) {
                oiEligibleShares[msg.sender][posId] -= oiDecrement;
            }
            _burn(msg.sender, posId, amount);
            unchecked { i++; }
        }

        // C-1: Decrement collateral tracking
        conditionCollateral[conditionId] -= amount;

        collateralToken.safeTransfer(msg.sender, amount);

        // QGM-43 fix: skip OI hook after resolution to keep finalized-market OI immutable.
        // addOIByCondition() already has an `if (m.resolved) return;` early-exit; this
        // restores symmetry on the decrement side.
        if (oiDecrement > 0 && !isResolved[conditionId] && address(marketRegistry) != address(0)) {
            marketRegistry.subtractOIByCondition(conditionId, oiDecrement);
        }

        emit PositionsMerged(msg.sender, conditionId, amount);
    }

    // ─── Report Payouts ───

    /// @notice Oracle reports outcome. [1,0] = outcome 0 wins, [0,1] = outcome 1 wins,
    ///         INVALID = [1,1] → 50/50 split.
    function reportPayouts(
        bytes32 questionId,
        uint256[] calldata payouts
    ) external {
        bytes32 conditionId = getConditionId(msg.sender, questionId, 2);
        if (conditionOutcomeSlotCounts[conditionId] == 0) revert ConditionNotFound(conditionId);
        if (isResolved[conditionId]) revert ConditionAlreadyResolved(conditionId);
        if (payouts.length != 2) revert InvalidPayoutsLength(2, payouts.length);

        isResolved[conditionId] = true;
        payoutNumerators[conditionId] = payouts;

        uint256 den;
        for (uint256 i = 0; i < payouts.length;) {
            den += payouts[i];
            unchecked { i++; }
        }
        require(den > 0, "Zero payout denominator");
        payoutDenominator[conditionId] = den;

        emit ConditionResolved(conditionId, msg.sender, questionId, payouts);
    }

    // ─── Redeem ───

    /// @notice Redeem winning positions for collateral.
    /// @dev nonReentrant + CEI. MIN_REDEEM check — dust goes to Treasury.
    ///      Zero Supply: if winning side totalSupply==0, payout → Treasury.
    ///      Rounding floor. 지급≤예치 assert.
    function redeemPositions(
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external nonReentrant returns (uint256 totalPayout) {
        if (!isResolved[conditionId]) revert ConditionNotResolved(conditionId);

        uint256 den = payoutDenominator[conditionId];
        uint256[] memory nums = payoutNumerators[conditionId];

        for (uint256 i = 0; i < indexSets.length;) {
            uint256 indexSet = indexSets[i];
            uint256 posId = getPositionId(address(collateralToken), getCollectionId(conditionId, indexSet));
            uint256 bal = balanceOf(msg.sender, posId);

            if (bal == 0) {
                unchecked { i++; }
                continue;
            }

            // Determine payout for this indexSet
            uint256 payoutNumerator;
            for (uint256 j = 0; j < nums.length;) {
                if (indexSet == (1 << j)) {
                    payoutNumerator = nums[j];
                    break;
                }
                unchecked { j++; }
            }

            // Rounding floor
            uint256 payout = (bal * payoutNumerator) / den;

            // Option C: clear redeemer's OI eligibility on this position before burn.
            // Finalized markets have no OI tracking impact, but we keep state consistent.
            if (oiEligibleShares[msg.sender][posId] > 0) {
                oiEligibleShares[msg.sender][posId] = 0;
            }
            // CEI: burn before transfer
            _burn(msg.sender, posId, bal);

            totalPayout += payout;
            unchecked { i++; }
        }

        if (totalPayout == 0) return 0;

        // C-1: Decrement collateral tracking
        conditionCollateral[conditionId] -= totalPayout;

        // MIN_REDEEM check: dust goes to Treasury (no revert)
        if (totalPayout < MIN_REDEEM) {
            collateralToken.safeTransfer(treasury, totalPayout);
            emit DustToTreasury(msg.sender, conditionId, totalPayout);
            return 0;
        }

        // Assert payout ≤ collateral held (safety)
        assert(totalPayout <= collateralToken.balanceOf(address(this)));

        collateralToken.safeTransfer(msg.sender, totalPayout);

        emit PayoutRedemption(msg.sender, conditionId, indexSets, totalPayout);
    }

    /// @notice Sweep unclaimed collateral for zero-supply outcomes to Treasury.
    /// @dev C-1 v2 fix: ALL winning outcomes (payoutNumerator > 0) must have zero supply.
    ///      This prevents sweep while any redeemable claims remain outstanding.
    function sweepZeroSupply(
        bytes32 conditionId,
        uint256 indexSet,
        uint256 collateralAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isResolved[conditionId]) revert ConditionNotResolved(conditionId);

        uint256 den = payoutDenominator[conditionId];
        require(den > 0, "Not resolved");

        // C-1 v2: Verify ALL winning outcomes have zero supply before allowing any sweep
        uint256[] memory nums = payoutNumerators[conditionId];
        for (uint256 i = 0; i < nums.length;) {
            if (nums[i] > 0) {
                uint256 winPosId = getPositionId(
                    address(collateralToken),
                    getCollectionId(conditionId, 1 << i)
                );
                require(totalSupply(winPosId) == 0, "Winning outcome has outstanding supply");
            }
            unchecked { i++; }
        }

        // Also verify the requested indexSet position
        uint256 posId = getPositionId(address(collateralToken), getCollectionId(conditionId, indexSet));
        require(totalSupply(posId) == 0, "Supply not zero");

        // C-1: Cannot sweep more than condition's own collateral
        require(collateralAmount <= conditionCollateral[conditionId], "Exceeds condition collateral");
        conditionCollateral[conditionId] -= collateralAmount;

        collateralToken.safeTransfer(treasury, collateralAmount);
        emit ZeroSupplyToTreasury(conditionId, collateralAmount);
    }

    // ─── View Helpers ───

    function getConditionId(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(
        bytes32 conditionId,
        uint256 indexSet
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(conditionId, indexSet));
    }

    function getPositionId(
        address collateralAddr,
        bytes32 collectionId
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralAddr, collectionId)));
    }

    /// @notice Decode a positionId back to conditionId + outcomeIndex.
    function decodePositionId(uint256 posId) external view returns (bytes32 conditionId, uint256 outcomeIndex) {
        conditionId = positionConditionId[posId];
        uint256 indexSet = positionIndexSet[posId];
        outcomeIndex = indexSet == 1 ? 0 : 1;
    }

    // ─── ERC1155 Supply Tracking ───
    // Override to track totalSupply per token id for Zero Supply check

    mapping(uint256 => uint256) private _totalSupply;

    function totalSupply(uint256 id) public view returns (uint256) {
        return _totalSupply[id];
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        super._update(from, to, ids, values);

        for (uint256 i = 0; i < ids.length;) {
            if (from == address(0)) {
                // Mint: totalSupply update only. Eligibility is granted by the caller
                // of splitPosition (the caller, not the recipient mintee, holds eligibility).
                _totalSupply[ids[i]] += values[i];
            } else if (to == address(0)) {
                // Burn: totalSupply update only. Eligibility consumption handled by
                // mergePositions / redeemPositions / redeemPositionsFor explicitly.
                _totalSupply[ids[i]] -= values[i];
            } else {
                // Option C: regular transfer — move OI eligibility along with shares
                // up to the lesser of (sender's eligibility, transferred amount).
                uint256 elig = oiEligibleShares[from][ids[i]];
                uint256 moved = elig < values[i] ? elig : values[i];
                if (moved > 0) {
                    oiEligibleShares[from][ids[i]] = elig - moved;
                    oiEligibleShares[to][ids[i]] += moved;
                    emit OIEligibilityMoved(from, to, ids[i], moved);
                }
            }
            unchecked { i++; }
        }
    }

    // ─── ERC165: resolve multiple inheritance ───
    function supportsInterface(bytes4 interfaceId)
    public view override(ERC1155Upgradeable, AccessControlUpgradeable) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN REDEEM (recover CT shares from proxy wallets)
    // ═══════════════════════════════════════════════════════

    event RedeemForUser(address indexed holder, address indexed recipient, bytes32 conditionId, uint256 totalPayout);

    /// @notice Redeem CT shares on behalf of a user (proxy wallet).
    ///         Requires that the holder has approved this contract (isApprovedForAll).
    ///         Burns the holder's shares and sends USDT payout to the specified recipient.
    /// @dev    QGM-38 fix: now enforces the documented `isApprovedForAll` requirement.
    ///         SafeProxyFactory grants this approval automatically at ProxyWallet creation;
    ///         legacy proxies must be backfilled via scripts/backfill-proxy-ct-approval.ts.
    /// @param holder    The address holding CT shares (typically a ProxyWallet)
    /// @param recipient The address to receive the USDT payout
    /// @param conditionId The condition to redeem
    /// @param indexSets  Array of index sets to redeem (e.g., [1] for outcome 0, [2] for outcome 1)
    function redeemPositionsFor(
        address holder,
        address recipient,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 totalPayout) {
        require(holder != address(0), "Zero holder");
        require(recipient != address(0), "Zero recipient");
        if (!isResolved[conditionId]) revert ConditionNotResolved(conditionId);
        // QGM-38 fix: enforce documented approval — holder must have setApprovalForAll(this, true).
        if (!isApprovedForAll(holder, address(this))) revert HolderApprovalRequired(holder);

        uint256 den = payoutDenominator[conditionId];
        uint256[] memory nums = payoutNumerators[conditionId];

        for (uint256 i = 0; i < indexSets.length;) {
            uint256 indexSet = indexSets[i];
            uint256 posId = getPositionId(address(collateralToken), getCollectionId(conditionId, indexSet));
            uint256 bal = balanceOf(holder, posId);

            if (bal == 0) {
                unchecked { i++; }
                continue;
            }

            uint256 payoutNumerator;
            for (uint256 j = 0; j < nums.length;) {
                if (indexSet == (1 << j)) {
                    payoutNumerator = nums[j];
                    break;
                }
                unchecked { j++; }
            }

            uint256 payout = (bal * payoutNumerator) / den;
            // Option C: clear holder's OI eligibility on this position before burn (consistency).
            if (oiEligibleShares[holder][posId] > 0) {
                oiEligibleShares[holder][posId] = 0;
            }
            _burn(holder, posId, bal);
            totalPayout += payout;
            unchecked { i++; }
        }

        if (totalPayout == 0) return 0;

        conditionCollateral[conditionId] -= totalPayout;

        if (totalPayout < MIN_REDEEM) {
            collateralToken.safeTransfer(treasury, totalPayout);
            emit DustToTreasury(holder, conditionId, totalPayout);
            return 0;
        }

        assert(totalPayout <= collateralToken.balanceOf(address(this)));
        collateralToken.safeTransfer(recipient, totalPayout);

        emit RedeemForUser(holder, recipient, conditionId, totalPayout);
    }

    // ─── Storage Gap ───
    // Reduced from 47 → 45 to accommodate Option C storage:
    //   - IMarketRegistryOIHook marketRegistry                                  (1 slot)
    //   - mapping(address => mapping(uint256 => uint256)) oiEligibleShares      (1 slot)
    uint256[45] private __gap;
}
