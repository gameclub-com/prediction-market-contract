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

    // ─── Modifiers ───
    modifier onlyOracleRouter() {
        if (msg.sender != oracleRouter) revert NotOracleRouter();
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

        // Prepare condition in ConditionalTokens (skip if already prepared)
        try conditionalTokens.prepareCondition(address(this), params.questionId, params.outcomeSlotCount) {}
        catch { /* ConditionAlreadyPrepared — safe to ignore */ }

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

        m.resolved = true;
        emit MarketResolved(marketId);
    }

    function finalizeResolution(uint256 marketId, uint256 outcomeIndex) external onlyOracleRouter {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (!m.resolved) revert MarketNotResolved(marketId);
        if (m.finalized) revert MarketAlreadyFinalized(marketId);

        m.finalized = true;

        // NCA: Report payouts to ConditionalTokens so shares can be redeemed
        // Oracle = address(this) because prepareCondition was called with address(this)
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

        m.finalized = true;

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
    function expireMarket(uint256 marketId) external onlyRole(Roles.KEEPER_ROLE) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        if (m.finalized) revert MarketAlreadyFinalizedErr(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        require(block.timestamp > m.endTime, "Market not expired yet");

        m.resolved = true;
        m.finalized = true;

        // INVALID result: 50/50 split so users can redeem half their collateral
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
        if (oi > m.currentOI) {
            emit OIUnderflow(marketId, m.currentOI, oi);
            m.currentOI = 0;
        } else {
            m.currentOI -= oi;
        }
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

    /// @notice Update collateralPerSet for an existing market.
    function setCollateralPerSet(uint256 marketId, uint256 newCps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Market storage m = markets[marketId];
        if (!m.exists) revert MarketNotFound(marketId);
        require(newCps == 1e18 || newCps == 1e17 || newCps == 1e16, "Invalid collateralPerSet");
        uint256 oldCps = m.collateralPerSet;
        m.collateralPerSet = newCps;
        emit CollateralPerSetUpdated(marketId, oldCps, newCps);
    }

    /// @notice Batch update collateralPerSet for multiple markets.
    function batchSetCollateralPerSet(uint256[] calldata marketIds, uint256 newCps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCps == 1e18 || newCps == 1e17 || newCps == 1e16, "Invalid collateralPerSet");
        for (uint256 i = 0; i < marketIds.length; i++) {
            Market storage m = markets[marketIds[i]];
            if (!m.exists) revert MarketNotFound(marketIds[i]);
            uint256 oldCps = m.collateralPerSet;
            m.collateralPerSet = newCps;
            emit CollateralPerSetUpdated(marketIds[i], oldCps, newCps);
        }
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
    uint256[49] private __gap;
}
