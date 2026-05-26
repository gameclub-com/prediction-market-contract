// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Roles.sol";
import "./ConditionalTokens.sol";

/// @title MarketRegistry — Market creation, lifecycle, and resolution management
contract MarketRegistry is Initializable, AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    // ─── Errors ───
    error QuestionIdAlreadyUsed(bytes32 questionId);
    error InvalidOutcomeSlotCount(uint256 count);
    error TooManyTags(uint256 count, uint256 max);
    error MarketNotFound(uint256 marketId);
    error MarketAlreadyResolved(uint256 marketId);
    error MarketAlreadyFinalized(uint256 marketId);
    error MarketNotResolved(uint256 marketId);
    error MarketFrozen(uint256 marketId);
    error MarketNotFrozen(uint256 marketId);
    error MarketAlreadyFinalizedErr(uint256 marketId);
    error TooManyBatchMarkets(uint256 count, uint256 max);
    error MarketIdAlreadyUsed(uint256 marketId);
    error ProfileNotFound(bytes32 profileHash);
    error Unauthorized();
    error InvalidEndTime();
    error SCDeadlineNotPassed();
    error NotOracleRouter();
    error MarketNotYetResolved(uint256 marketId);
    error OIUnderflowErr(uint256 marketId, uint256 currentOI, uint256 requestedOI);
    error CollateralPerSetImmutable(uint256 marketId);
    // Option C: ConditionalTokens link + protocol-wide OI sync
    error NotConditionalTokens();
    error MaxOIExceeded(uint256 marketId, uint256 currentOI, uint256 attempted, uint256 max);
    error ConditionalTokensAlreadySet();
    error ConditionIdAlreadyMapped(bytes32 conditionId, uint256 existingMarketId);
    // QGM-37 fix: createMarket rejects adoption of pre-prepared official conditions
    error ConditionPrePrepared(bytes32 conditionId);
    // QGM-40 fix: explicit error for lifecycle calls when CT reference is unset
    error ConditionalTokensNotSet();

    // ─── Events ───
    event MarketCreated(
        uint256 indexed marketId,
        uint256 indexed eventId,
        bytes32 indexed questionId,
        bytes32 conditionId,
        uint256 endTime,
        uint256 tradingCutoff,
        uint256 maxOpenInterest
    );
    event MarketCreationSkipped(bytes32 indexed questionId, string reason);
    event MarketBatchCreated(uint256 indexed eventId, uint256 batchCount, uint256 successCount, uint256 skipCount);
    event MarketExtended(uint256 indexed marketId, uint256 newEndTime);
    event MarketResolved(uint256 indexed marketId);
    event MarketFinalized(uint256 indexed marketId, uint256 outcomeIndex);
    event MarketFreezeToggled(uint256 indexed marketId, bool frozen, address by);
    event MarketExpired(uint256 indexed marketId);
    event MarketUnresolved(uint256 indexed marketId);
    event OIUnderflow(uint256 indexed marketId, uint256 currentOI, uint256 subtractedOI);
    event OIRecovered(uint256 indexed marketId, uint256 oldOI, uint256 newOI, address indexed by);
    // Option C events
    event ConditionalTokensSet(address indexed ct);
    event ConditionalTokensReset(address indexed previousCt, address indexed by);
    event ConditionIdMapped(uint256 indexed marketId, bytes32 indexed conditionId);
    event OISynced(uint256 indexed marketId, bytes32 indexed conditionId, int256 delta, uint256 newOI);
    event OracleRouterUpdated(address indexed oldRouter, address indexed newRouter);
    // H-4 v2: 2-step oracle router change events
    event OracleRouterChangeProposed(address indexed newRouter, uint256 executeAfter);
    event OracleRouterChangeCancelled(address indexed cancelledRouter);

    // ─── Constants ───
    uint256 public constant MAX_TAGS = 5;
    uint256 public constant MAX_BATCH_MARKETS = 20;

    // ─── Structs ───
    struct Market {
        bytes32 questionId;
        bytes32 conditionId;
        bytes32 profileHash;
        uint256 endTime;
        uint256 originalEndTime;
        uint256 tradingCutoff;
        uint256 maxOpenInterest;
        uint256 outcomeSlotCount;
        uint256 totalVolume;
        uint256 currentOI;
        uint256 collateralPerSet; // USDT per full set of outcome tokens (default 1e18 = 1 USDT)
        bool resolved;
        bool finalized;
        bool frozen;
        bool exists;
    }

    struct CreateMarketParams {
        bytes32 questionId;
        uint256 endTime;
        bytes32 profileHash;
        string[] tags;
        uint256 cutoff;
        uint256 outcomeSlotCount;
        uint256 collateralPerSet; // 0 = default (1e18), or 1e18 / 1e17 / 1e16
    }

    struct ArbitrationProfile {
        uint256 maxDeviationBps;
        uint256 maxBondCap;
        uint256 maxOpenInterest;
        uint32 oracleHeartbeat;
        bool exists;
        // ─── Dispute config ───
        uint256 disputeWindow;        // seconds (0 = immediate finalization)
        uint256 disputeBondAmount;    // bond required to dispute (in collateral token)
        bool disputeEnabled;          // whether disputes are allowed for this profile
    }

    // ─── State ───
    mapping(uint256 => Market) public markets;
    mapping(uint256 => uint256) public marketEventId; // marketId => eventId
    mapping(bytes32 => uint256) public questionIdToMarketId;
    mapping(bytes32 => ArbitrationProfile) public profiles;
    uint256 public nextMarketId;

    ConditionalTokens public conditionalTokens; // was immutable
    address public oracleRouter;

    // H-4 v2: 2-step oracle router change with delay
    address public pendingOracleRouter;
    uint256 public oracleRouterChangeTime;
    uint256 public constant ROUTER_CHANGE_DELAY = 24 hours;

    // Option C: protocol-wide OI sync via ConditionalTokens
    mapping(bytes32 => uint256) public conditionIdToMarketId;
    address public conditionalTokensAddress;

    // ─── Modifiers ───
    modifier onlyOracleRouter() {
        if (msg.sender != oracleRouter) revert NotOracleRouter();
        _;
    }

    modifier onlyConditionalTokens() {
        if (msg.sender != conditionalTokensAddress) revert NotConditionalTokens();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _conditionalTokens) external initializer {
        __AccessControlEnumerable_init();

        conditionalTokens = ConditionalTokens(_conditionalTokens);
        nextMarketId = 1;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ─── UUPS Authorization ───
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // H-4 v3: 최초 배포 시 딜레이 없이 oracleRouter 초기화 (oracleRouter == address(0) 일 때만 가능)
    function initOracleRouter(address _router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(oracleRouter == address(0), "Already initialized");
        require(_router != address(0), "Zero address");
        oracleRouter = _router;
        emit OracleRouterUpdated(address(0), _router);
    }

    // H-4 v2: 2-step oracle router change with 24h delay
    function proposeOracleRouter(address _newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newRouter != address(0), "Zero address");
        pendingOracleRouter = _newRouter;
        oracleRouterChangeTime = block.timestamp + ROUTER_CHANGE_DELAY;
        emit OracleRouterChangeProposed(_newRouter, oracleRouterChangeTime);
    }

    function acceptOracleRouter() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingOracleRouter != address(0), "No pending change");
        require(block.timestamp >= oracleRouterChangeTime, "Delay not passed");
        address old = oracleRouter;
        oracleRouter = pendingOracleRouter;
        pendingOracleRouter = address(0);
        oracleRouterChangeTime = 0;
        emit OracleRouterUpdated(old, oracleRouter);
    }

    function cancelOracleRouterChange() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingOracleRouter != address(0), "No pending change");
        address cancelled = pendingOracleRouter;
        pendingOracleRouter = address(0);
        oracleRouterChangeTime = 0;
        emit OracleRouterChangeCancelled(cancelled);
    }

    // ─── Profile Management ───

    function setProfile(
        bytes32 profileHash,
        uint256 maxDeviationBps,
        uint256 maxBondCap,
        uint256 maxOpenInterest,
        uint32 oracleHeartbeat,
        uint256 disputeWindow,
        uint256 disputeBondAmount,
        bool disputeEnabled
    ) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(Roles.MARKET_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        profiles[profileHash] = ArbitrationProfile({
            maxDeviationBps: maxDeviationBps,
            maxBondCap: maxBondCap,
            maxOpenInterest: maxOpenInterest,
            oracleHeartbeat: oracleHeartbeat,
            exists: true,
            disputeWindow: disputeWindow,
            disputeBondAmount: disputeBondAmount,
            disputeEnabled: disputeEnabled
        });
    }

    // ─── Market Creation ───

    function createMarket(
        CreateMarketParams calldata params
    ) external onlyRole(Roles.MARKET_ADMIN_ROLE) returns (uint256) {
        return _createMarketInternal(params, 0, 0);
    }

    /// @notice Create a market with a specific ID (for DB ID = on-chain ID alignment).
    /// @param customId  The desired on-chain market ID (must not already exist).
    function createMarketWithId(
        uint256 customId,
        CreateMarketParams calldata params
    ) external onlyRole(Roles.MARKET_ADMIN_ROLE) returns (uint256) {
        if (customId == 0) revert MarketNotFound(0);
        return _createMarketInternal(params, 0, customId);
    }

    /// @notice Batch create markets for a single event. Per-market skip on failure.
    function createMarketBatch(
        uint256 eventId,
        CreateMarketParams[] calldata params
    ) external onlyRole(Roles.MARKET_ADMIN_ROLE) {
        if (params.length > MAX_BATCH_MARKETS) {
            revert TooManyBatchMarkets(params.length, MAX_BATCH_MARKETS);
        }

        uint256 successCount;
        uint256 skipCount;

        // L-3 v2: unchecked loop counter
        for (uint256 i = 0; i < params.length;) {
            // Pre-validate to skip gracefully instead of reverting
            bool skip = false;
            if (questionIdToMarketId[params[i].questionId] != 0) {
                emit MarketCreationSkipped(params[i].questionId, "duplicate_question");
                skip = true;
            } else if (params[i].tags.length > MAX_TAGS) {
                emit MarketCreationSkipped(params[i].questionId, "too_many_tags");
                skip = true;
            } else if (params[i].outcomeSlotCount != 2) {
                emit MarketCreationSkipped(params[i].questionId, "invalid_outcome_count");
                skip = true;
            } else if (params[i].endTime <= block.timestamp) {
                emit MarketCreationSkipped(params[i].questionId, "invalid_end_time");
                skip = true;
            // M-4 v2: Cutoff invariant
            } else if (params[i].cutoff == 0 || params[i].cutoff > params[i].endTime || params[i].cutoff <= block.timestamp) {
                emit MarketCreationSkipped(params[i].questionId, "invalid_cutoff");
                skip = true;
            } else if (!profiles[params[i].profileHash].exists) {
                emit MarketCreationSkipped(params[i].questionId, "profile_not_found");
                skip = true;
            }

            if (skip) {
                skipCount++;
            } else {
                _createMarketInternal(params[i], eventId, 0);
                successCount++;
            }
            unchecked { i++; }
        }

        emit MarketBatchCreated(eventId, params.length, successCount, skipCount);
    }

    /// @notice Batch create markets with specific IDs for DB alignment.
    /// @param ids  Array of desired on-chain market IDs (must match params length).
    function createMarketBatchWithIds(
        uint256 eventId,
        uint256[] calldata ids,
        CreateMarketParams[] calldata params
    ) external onlyRole(Roles.MARKET_ADMIN_ROLE) {
        require(ids.length == params.length, "length_mismatch");
        if (params.length > MAX_BATCH_MARKETS) {
            revert TooManyBatchMarkets(params.length, MAX_BATCH_MARKETS);
        }

        uint256 successCount;
        uint256 skipCount;

        for (uint256 i = 0; i < params.length;) {
            bool skip = false;
            if (ids[i] == 0) {
                emit MarketCreationSkipped(params[i].questionId, "invalid_custom_id");
                skip = true;
            } else if (markets[ids[i]].exists) {
                emit MarketCreationSkipped(params[i].questionId, "market_id_taken");
                skip = true;
            } else if (questionIdToMarketId[params[i].questionId] != 0) {
                emit MarketCreationSkipped(params[i].questionId, "duplicate_question");
                skip = true;
            } else if (params[i].tags.length > MAX_TAGS) {
                emit MarketCreationSkipped(params[i].questionId, "too_many_tags");
                skip = true;
            } else if (params[i].outcomeSlotCount != 2) {
                emit MarketCreationSkipped(params[i].questionId, "invalid_outcome_count");
                skip = true;
            } else if (params[i].endTime <= block.timestamp) {
                emit MarketCreationSkipped(params[i].questionId, "invalid_end_time");
                skip = true;
            } else if (params[i].cutoff == 0 || params[i].cutoff > params[i].endTime || params[i].cutoff <= block.timestamp) {
                emit MarketCreationSkipped(params[i].questionId, "invalid_cutoff");
                skip = true;
            } else if (!profiles[params[i].profileHash].exists) {
                emit MarketCreationSkipped(params[i].questionId, "profile_not_found");
                skip = true;
            }

            if (skip) {
                skipCount++;
            } else {
                _createMarketInternal(params[i], eventId, ids[i]);
                successCount++;
            }
            unchecked { i++; }
        }

        emit MarketBatchCreated(eventId, params.length, successCount, skipCount);
    }

    function _createMarketInternal(
        CreateMarketParams calldata params,
        uint256 eventId,
        uint256 customId
    ) internal returns (uint256 marketId) {
        if (questionIdToMarketId[params.questionId] != 0) {
            revert QuestionIdAlreadyUsed(params.questionId);
        }
        if (params.outcomeSlotCount != 2) {
            revert InvalidOutcomeSlotCount(params.outcomeSlotCount);
        }
        if (params.tags.length > MAX_TAGS) {
            revert TooManyTags(params.tags.length, MAX_TAGS);
        }
        if (params.endTime <= block.timestamp) {
            revert InvalidEndTime();
        }
        // M-4 v2: Cutoff invariant validation
        require(params.cutoff > 0 && params.cutoff <= params.endTime, "Invalid cutoff");
        require(params.cutoff > block.timestamp, "Cutoff in past");

        ArbitrationProfile storage profile = profiles[params.profileHash];
        if (!profile.exists) revert ProfileNotFound(params.profileHash);

        // Prepare condition on ConditionalTokens
        bytes32 conditionId = conditionalTokens.getConditionId(
            address(this), params.questionId, params.outcomeSlotCount
        );

        // Validate collateralPerSet (0 = default 1e18, or must be 1e18/1e17/1e16)
        uint256 cps = params.collateralPerSet;
        if (cps == 0) cps = 1e18;
        require(cps == 1e18 || cps == 1e17 || cps == 1e16, "Invalid collateralPerSet");

        if (customId > 0) {
            if (markets[customId].exists) revert MarketIdAlreadyUsed(customId);
            marketId = customId;
            // Keep nextMarketId ahead of any custom ID to avoid future collisions
            if (customId >= nextMarketId) nextMarketId = customId + 1;
        } else {
            marketId = nextMarketId++;
        }
        markets[marketId] = Market({
            questionId: params.questionId,
            conditionId: conditionId,
            profileHash: params.profileHash,
            endTime: params.endTime,
            originalEndTime: params.endTime,
            tradingCutoff: params.cutoff,
            maxOpenInterest: profile.maxOpenInterest,
            outcomeSlotCount: params.outcomeSlotCount,
            totalVolume: 0,
            currentOI: 0,
            collateralPerSet: cps,
            resolved: false,
            finalized: false,
            frozen: false,
            exists: true
        });
        if (eventId != 0) {
            marketEventId[marketId] = eventId;
        }

        questionIdToMarketId[params.questionId] = marketId;

        // Option C: register conditionId → marketId reverse mapping for OI sync hooks
        if (conditionIdToMarketId[conditionId] == 0) {
            conditionIdToMarketId[conditionId] = marketId;
            emit ConditionIdMapped(marketId, conditionId);
        }

        // QGM-37 fix: reject pre-prepared official conditions. Combined with
        //   ConditionalTokens.prepareCondition()'s registry-only gate, this guarantees
        //   that protocol conditions cannot exist before createMarket maps them.
        //   Therefore no untracked split/supply can hide under an official conditionId.
        if (conditionalTokens.conditionOutcomeSlotCounts(conditionId) != 0) {
            revert ConditionPrePrepared(conditionId);
        }
        conditionalTokens.prepareCondition(address(this), params.questionId, params.outcomeSlotCount);

        emit MarketCreated(
            marketId,
            eventId,
            params.questionId,
            conditionId,
            params.endTime,
            params.cutoff,
            profile.maxOpenInterest
        );
    }

    // ─── Market Lifecycle ───

    function extendMarket(uint256 marketId, uint256 newEndTime) external {
        if (!hasRole(Roles.ORACLE_ROLE, msg.sender) && !hasRole(Roles.KEEPER_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);
        require(newEndTime > m.endTime, "Must extend");
        require(newEndTime > block.timestamp, "Must be in future");

        m.endTime = newEndTime;
        emit MarketExtended(marketId, newEndTime);
    }

    function setResolved(uint256 marketId) external onlyOracleRouter {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        // QGM-39 fix: frozen markets cannot enter resolved state. This keeps
        // setResolved consistent with finalizeResolution / finalizeResolutionInvalid
        // and prevents the "PROPOSED but un-finalizable" stuck intermediate state.
        if (m.frozen) revert MarketFrozen(marketId);

        m.resolved = true;
        emit MarketResolved(marketId);
    }

    function finalizeResolution(uint256 marketId, uint256 outcomeIndex) external onlyOracleRouter {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (!m.resolved) revert MarketNotResolved(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);
        if (m.frozen) revert MarketFrozen(marketId);

        m.finalized = true;

        // NCA: Report payouts to ConditionalTokens so shares can be redeemed
        // Oracle = address(this) because prepareCondition was called with address(this)
        // QGM-40 fix: explicit guard with clear error instead of silent zero-address call.
        if (address(conditionalTokens) == address(0)) revert ConditionalTokensNotSet();
        uint256[] memory payouts = new uint256[](2);
        payouts[outcomeIndex] = 1;
        conditionalTokens.reportPayouts(m.questionId, payouts);

        emit MarketFinalized(marketId, outcomeIndex);
    }

    // H-3 v2: overrideOutcome REMOVED — all resolution goes through OracleRouter.
    // SAFETY_COUNCIL uses CentralizedOracleRouter.emergencyResolve() instead.

    /// @notice Finalize as INVALID — 50/50 split (payouts = [1,1]).
    /// @dev Used by OptimisticOracle for INVALID data feed outcomes.
    function finalizeResolutionInvalid(uint256 marketId) external onlyOracleRouter {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (!m.resolved) revert MarketNotResolved(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);
        if (m.frozen) revert MarketFrozen(marketId);

        m.finalized = true;

        // QGM-40 fix: explicit guard with clear error instead of silent zero-address call.
        if (address(conditionalTokens) == address(0)) revert ConditionalTokensNotSet();
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 1;
        conditionalTokens.reportPayouts(m.questionId, payouts);

        emit MarketFinalized(marketId, type(uint256).max); // max indicates INVALID
    }

    function freezeMarket(uint256 marketId) external {
        if (msg.sender != oracleRouter && !hasRole(Roles.SAFETY_COUNCIL_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.frozen) revert MarketFrozen(marketId);

        m.frozen = true;
        emit MarketFreezeToggled(marketId, true, msg.sender);
    }

    function unfreezeMarket(uint256 marketId) external {
        if (msg.sender != oracleRouter && !hasRole(Roles.SAFETY_COUNCIL_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (!m.frozen) revert MarketNotFrozen(marketId);

        m.frozen = false;
        emit MarketFreezeToggled(marketId, false, msg.sender);
    }

    /// @notice Expire a market — resolves as INVALID (50:50 refund) so users can redeem.
    /// @dev MED-4 fix: also finalizes and reports payouts to CT.
    ///      QGM-42 fix: frozen markets cannot be auto-expired. Council must explicitly
    ///      unfreezeMarket() first. This is consistent with finalize* paths and prevents
    ///      keeper from forcing a 50/50 INVALID outcome during an active emergency pause.
    function expireMarket(uint256 marketId) external onlyRole(Roles.KEEPER_ROLE) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.finalized) revert MarketAlreadyFinalizedErr(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        if (m.frozen) revert MarketFrozen(marketId);
        require(block.timestamp > m.endTime, "Market not expired yet");

        m.resolved = true;
        m.finalized = true;

        // INVALID result: 50/50 split so users can redeem half their collateral
        // QGM-40 fix: explicit guard with clear error instead of silent zero-address call.
        if (address(conditionalTokens) == address(0)) revert ConditionalTokensNotSet();
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 1;
        conditionalTokens.reportPayouts(m.questionId, payouts);

        emit MarketExpired(marketId);
    }

    // ─── Exchange Integration ───

    function addVolumeAndOI(
        uint256 marketId,
        uint256 volume,
        uint256 oi
    ) external onlyRole(Roles.RELAYER_ROLE) {
        Market storage m = markets[marketId];
        // M-5 v2: Validate market exists
        if (!m.exists) revert MarketNotFound(marketId);
        m.totalVolume += volume;
        m.currentOI += oi;
    }

    /// @notice M-4 fix: Volume tracking without OI change (for COMPLEMENTARY fills).
    function addVolume(
        uint256 marketId,
        uint256 volume
    ) external onlyRole(Roles.RELAYER_ROLE) {
        // M-5 v2: Validate market exists
        if (!markets[marketId].exists) revert MarketNotFound(marketId);
        markets[marketId].totalVolume += volume;
    }

    /// @notice MED-2 fix: Decrease OI when positions are redeemed/merged/cancelled.
    function subtractOI(
        uint256 marketId,
        uint256 oi
    ) external onlyRole(Roles.RELAYER_ROLE) {
        Market storage m = markets[marketId];
        // M-5 v2: Validate market exists
        if (!m.exists) revert MarketNotFound(marketId);
        if (oi > m.currentOI) revert OIUnderflowErr(marketId, m.currentOI, oi);
        m.currentOI -= oi;
    }

    /// @notice Admin escape hatch — set currentOI directly to reconcile with reality.
    /// @dev    Used when off-chain operations (direct splits/merges/transfers) cause drift.
    ///         Does NOT bypass any other security invariant. Only currentOI value.
    ///         Should be governed by Timelock/Multisig in production.
    function recoverOI(uint256 marketId, uint256 newOI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);
        uint256 oldOI = m.currentOI;
        m.currentOI = newOI;
        emit OIRecovered(marketId, oldOI, newOI, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // OPTION C: ConditionalTokens-driven OI sync
    // ═══════════════════════════════════════════════════════

    /// @notice One-time setter for ConditionalTokens address. Required for OI sync hooks.
    /// @dev    Called once during deployment after both contracts exist.
    ///         Use emergencyResetConditionalTokens() if reset is required (admin-gated).
    ///         QGM-40 fix: updates BOTH `conditionalTokens` (lifecycle reference) and
    ///         `conditionalTokensAddress` (OI hook authorization) atomically to prevent
    ///         split-brain operation.
    function setConditionalTokens(address _ct) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (conditionalTokensAddress != address(0)) revert ConditionalTokensAlreadySet();
        require(_ct != address(0), "Zero CT");
        conditionalTokensAddress = _ct;
        conditionalTokens = ConditionalTokens(_ct);
        emit ConditionalTokensSet(_ct);
    }

    /// @notice Emergency reset of ConditionalTokens link — for rollback / migration scenarios.
    /// @dev    Disables OI sync hooks AND lifecycle calls. Operator must re-call
    ///         setConditionalTokens to re-enable.
    ///         QGM-40 fix: clears BOTH references atomically; lifecycle functions
    ///         (`finalizeResolution`, `finalizeResolutionInvalid`, `expireMarket`)
    ///         will revert with `ConditionalTokensNotSet` until re-wired.
    function emergencyResetConditionalTokens() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address prev = conditionalTokensAddress;
        conditionalTokensAddress = address(0);
        conditionalTokens = ConditionalTokens(address(0));
        emit ConditionalTokensReset(prev, msg.sender);
    }

    /// @notice Backfill conditionId → marketId mapping for markets created before Option C.
    /// @dev    Idempotent — skips already-mapped conditions. Admin-only.
    ///         QGM-03 fix: reconciles pre-existing supply into `currentOI` at backfill time.
    ///         For binary markets, `totalSupply(outcome 0)` reflects the live OI floor —
    ///         any complete set ever minted contributes equal supply to both outcomes.
    ///         Reverts if pre-existing supply exceeds the market's `maxOpenInterest`.
    function backfillConditionMapping(uint256 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        bytes32 cid = m.conditionId;
        uint256 existing = conditionIdToMarketId[cid];
        if (existing == marketId) return; // already mapped, idempotent
        if (existing != 0) revert ConditionIdAlreadyMapped(cid, existing);

        // QGM-03 fix: reconcile pre-existing supply before activating the mapping.
        // Without this, any condition that was split before backfill would have live
        // outcome tokens that bypass currentOI tracking and maxOpenInterest enforcement.
        if (conditionalTokensAddress != address(0)) {
            ConditionalTokens ct = ConditionalTokens(conditionalTokensAddress);
            bytes32 collectionId0 = ct.getCollectionId(cid, 1);
            uint256 posId0 = ct.getPositionId(address(ct.collateralToken()), collectionId0);
            uint256 existingSupply = ct.totalSupply(posId0);
            if (existingSupply > 0) {
                if (m.maxOpenInterest > 0 && existingSupply > m.maxOpenInterest) {
                    revert MaxOIExceeded(marketId, 0, existingSupply, m.maxOpenInterest);
                }
                m.currentOI = existingSupply;
                emit OISynced(marketId, cid, int256(existingSupply), existingSupply);
            }
        }

        conditionIdToMarketId[cid] = marketId;
        emit ConditionIdMapped(marketId, cid);
    }

    /// @notice OI increase hook — called by ConditionalTokens.splitPosition().
    /// @dev    No-ops for unregistered conditions (CT used outside protocol markets).
    ///         Reverts on maxOpenInterest cap breach.
    function addOIByCondition(bytes32 conditionId, uint256 oi) external onlyConditionalTokens {
        if (oi == 0) return;
        uint256 marketId = conditionIdToMarketId[conditionId];
        if (marketId == 0) return; // condition not registered as a protocol market
        Market storage m = markets[marketId];
        if (!m.exists) return;
        if (m.resolved) return; // post-resolution mints (QGM-04 guarded elsewhere)

        uint256 newOI = m.currentOI + oi;
        if (m.maxOpenInterest > 0 && newOI > m.maxOpenInterest) {
            revert MaxOIExceeded(marketId, m.currentOI, newOI, m.maxOpenInterest);
        }
        m.currentOI = newOI;
        emit OISynced(marketId, conditionId, int256(oi), newOI);
    }

    /// @notice OI decrease hook — called by ConditionalTokens.mergePositions().
    /// @dev    No-ops for unregistered conditions. Reverts on underflow (exact accounting).
    function subtractOIByCondition(bytes32 conditionId, uint256 oi) external onlyConditionalTokens {
        if (oi == 0) return;
        uint256 marketId = conditionIdToMarketId[conditionId];
        if (marketId == 0) return;
        Market storage m = markets[marketId];
        if (!m.exists) return;

        if (oi > m.currentOI) revert OIUnderflowErr(marketId, m.currentOI, oi);
        m.currentOI -= oi;
        emit OISynced(marketId, conditionId, -int256(oi), m.currentOI);
    }

    // ─── OracleRouter Integration ───

    /// @notice Roll back resolved status (used when OracleRouter rejects a proposal).
    /// @dev Cannot unresolve a finalized market (reportPayouts is irreversible).
    function unresolve(uint256 marketId) external onlyOracleRouter {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);
        if (!m.resolved) revert MarketNotYetResolved(marketId);

        m.resolved = false;
        emit MarketUnresolved(marketId);
    }

    /// @notice Reset tradingCutoff after unresolve so the market can resume trading.
    function resetTradingCutoff(uint256 marketId, uint256 newCutoff) external onlyOracleRouter {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);
        require(newCutoff > block.timestamp, "Cutoff in past");
        require(newCutoff <= m.endTime, "Cutoff after end");
        m.tradingCutoff = newCutoff;
    }

    /// @notice Get dispute configuration for a market's profile.
    function getDisputeConfig(uint256 marketId) external view returns (
        bool disputeEnabled,
        uint256 disputeWindow,
        uint256 disputeBondAmount
    ) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        ArbitrationProfile storage p = profiles[m.profileHash];
        return (p.disputeEnabled, p.disputeWindow, p.disputeBondAmount);
    }

    // ─── CPS Admin ───

    event CollateralPerSetUpdated(uint256 indexed marketId, uint256 oldCps, uint256 newCps);

    /// @notice DEPRECATED — collateralPerSet is immutable after market creation. Always reverts.
    /// @dev    Retained for ABI back-compat. Use a new market for different CPS values.
    /// @custom:deprecated since v3 (QGM-29). Will be removed in a future ABI-breaking release.
    function setCollateralPerSet(uint256 marketId, uint256 newCps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        newCps;
        revert CollateralPerSetImmutable(marketId);
    }

    /// @notice DEPRECATED — see `setCollateralPerSet`. Always reverts.
    /// @custom:deprecated since v3 (QGM-29).
    function batchSetCollateralPerSet(uint256[] calldata marketIds, uint256 newCps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        newCps;
        if (marketIds.length == 0) revert MarketNotFound(0);
        if (!markets[marketIds[0]].exists) revert MarketNotFound(marketIds[0]);
        revert CollateralPerSetImmutable(marketIds[0]);
    }

    // ─── View ───

    function getCollateralPerSet(uint256 marketId) external view returns (uint256) {
        uint256 cps = markets[marketId].collateralPerSet;
        return cps > 0 ? cps : 1e18;
    }

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    function getSettlementData(uint256 marketId) external view returns (
        uint256 endTime,
        uint256 tradingCutoff,
        uint256 currentOI,
        uint256 maxOpenInterest,
        bool resolved,
        bool finalized,
        bytes32 conditionId
    ) {
        Market storage m = markets[marketId];
        return (m.endTime, m.tradingCutoff, m.currentOI, m.maxOpenInterest, m.resolved, m.finalized, m.conditionId);
    }

    // ─── Storage Gap ───
    // Reduced from 49 → 47 to accommodate Option C storage:
    //   - mapping(bytes32 => uint256) conditionIdToMarketId  (1 slot)
    //   - address conditionalTokensAddress                   (1 slot)
    uint256[47] private __gap;
}
