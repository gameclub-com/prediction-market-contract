// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "./Roles.sol";
import "./ConditionalTokens.sol";
import "./MarketRegistry.sol";

/// @title ExchangeCLOB — Non-Custodial Central Limit Order Book Exchange (Polymarket-style)
/// @notice Off-chain matching + on-chain batch settlement via transferFrom.
///         Users hold tokens in their own wallets (ProxyWallet). Exchange pulls via approval.
///         No deposit/withdraw — Exchange never custodies user funds (except transiently for MINT/MERGE).
/// @dev EIP-712 signed orders. MatchType: COMPLEMENTARY, MINT, MERGE.
///      v2 minimum-fix: trackedShares model removed; QGM-03 closed via subtractOI revert only.
contract ExchangeCLOB is
    Initializable,
    AccessControlEnumerableUpgradeable,
    EIP712Upgradeable,
    ERC1155Holder,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Enums ───
    enum Side { BUY, SELL }
    enum OrderType { LIMIT, IOC, REDUCE_ONLY, POST_ONLY }
    enum ShutdownMode { NORMAL, EMERGENCY_STOP, FREEZE_ALL }
    /// @dev Polymarket-style match types:
    /// COMPLEMENTARY = same-token BUY↔SELL (direct swap)
    /// MINT = cross-outcome BUY+BUY → splitPosition (creates new shares)
    /// MERGE = cross-outcome SELL+SELL → mergePositions (destroys shares)
    enum MatchType { COMPLEMENTARY, MINT, MERGE }

    // ─── Structs ───
    struct Order {
        address maker;
        uint256 marketId;
        uint256 outcomeIndex;
        Side side;
        uint256 amount;
        uint256 price;
        uint256 nonce;
        uint256 deadline;
        OrderType orderType;
        uint256 salt;
    }

    struct Fill {
        Order makerOrder;
        Order takerOrder;
        bytes makerSig;
        bytes takerSig;
        uint256 fillAmount;
        uint256 fee;
        MatchType matchType;
    }

    /// @dev Packed context to avoid stack-too-deep in settlement
    struct FillCtx {
        address buyer;
        address seller;
        uint256 outcomeIndex;
        uint256 executionPrice;
        uint256 fillValue;
        bytes32 conditionId;
        uint256 marketId;
        bytes32 makerHash;  // M-1: orderHash for fill tracking
        bytes32 takerHash;  // M-1: orderHash for fill tracking
    }

    /// @dev Batch-level accumulators — passed by reference through the settlement call chain.
    /// Avoids per-fill fee collection and surplus transfers (gas optimization).
    struct BatchAcc {
        uint256 fees;       // accumulated fees for single _collectFee at end
        uint256 surplus;    // accumulated MINT surplus for single treasury transfer
    }

    /// @dev V3: Aggregated MINT sweep — multiple MINT fills with the same taker + market
    /// settled via a single splitPosition call. Gas savings: ~58% for 5-fill sweeps.
    struct MintSweep {
        Order   takerOrder;       // single taker (market-order buyer)
        bytes   takerSig;         // verified once
        Order[] makerOrders;      // N maker limit orders
        bytes[] makerSigs;        // N maker signatures
        uint256[] fillAmounts;    // N fill amounts (shares)
        uint256[] fees;           // N fees
    }

    // ─── Custom Errors ───
    error BatchAlreadyProcessed(uint256 batchId);
    error Unauthorized();
    error TooManyFills(uint256 count, uint256 max);
    error NoUnclaimedFees();
    error CannotSweepProtectedToken(address token);
    error FreezeAllActive();
    error OnlyNormalMode();
    error SweepLengthMismatch();
    error SweepEmpty();
    error ReceiverIncompatible();
    error ArithmeticOverflow();
    error ReentrantCall();
    error ZeroAddress();
    error NonceNotIncreasing();
    error SweepValidation(uint8 code);

    // ─── Events ───
    event OrderCancelled(address indexed maker, bytes32 orderHash);
    event NonceBumped(address indexed user, uint256 newNonce);

    // L-7: Added matchType to FillExecuted
    event FillExecuted(
        uint256 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 executionPrice,
        uint256 fillAmount,
        uint256 fee,
        Side makerSide,
        MatchType matchType
    );
    event FillSkipped(uint256 indexed marketId, bytes32 orderHash, string reason);
    event BatchSettled(uint256 indexed batchId, uint256 successCount, uint256 skipCount, address relayer);
    event ForceSettled(uint256 indexed batchId, uint256 successCount, uint256 skipCount, address indexed caller);

    event FeesClaimed(address indexed collector, uint256 amount);
    event ShutdownModeChanged(ShutdownMode mode);
    event Swept(address indexed token, uint256 amount);
    event SanctionUpdated(address indexed user, bool sanctioned_);

    // ─── Reentrancy Guard (inline — OZ v5 removed ReentrancyGuardUpgradeable) ───
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ─── Constants ───
    uint256 public constant MAX_FEE = 500; // 500 bps, immutable
    uint256 public constant MIN_ORDER = 1e18;
    uint256 public constant MAX_FILLS_PER_BATCH = 100;
    uint256 public constant SIG_VERIFY_GAS_LIMIT = 50_000;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint256 marketId,uint256 outcomeIndex,uint8 side,uint256 amount,uint256 price,uint256 nonce,uint256 deadline,uint8 orderType,uint256 salt)"
    );

    // ─── Storage ───
    // M-1: filled keyed by orderHash (not maker+nonce)
    mapping(bytes32 => uint256) public filled;                             // orderHash => filledAmount
    mapping(bytes32 => bool) public isCancelled;                           // orderHash => cancelled
    mapping(address => uint256) public userNonce;                          // maker => minNonce
    mapping(bytes32 => bool) public processedBatches;                      // batchKey => processed
    ShutdownMode public systemMode;
    mapping(address => uint256) public unclaimedFees;                      // feeCollector => unclaimed
    mapping(address => bool) public sanctioned;

    IERC20 public usdt;                         // was immutable
    ConditionalTokens public conditionalTokens; // was immutable
    MarketRegistry public marketRegistry;       // was immutable
    address public feeCollector;
    address public treasury;
    // NOTE: trackedShares removed (minimum-fix model). QGM-03 closed via subtractOI revert.

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdt,
        address _conditionalTokens,
        address _marketRegistry,
        address _feeCollector,
        address _treasury
    ) external initializer {
        // L-3: Zero-address checks
        if (
            _usdt == address(0) ||
            _conditionalTokens == address(0) ||
            _marketRegistry == address(0) ||
            _feeCollector == address(0) ||
            _treasury == address(0)
        ) revert ZeroAddress();

        __AccessControlEnumerable_init();
        __EIP712_init("GameClub Exchange", "1");
        _reentrancyStatus = _NOT_ENTERED;

        usdt = IERC20(_usdt);
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        marketRegistry = MarketRegistry(_marketRegistry);
        feeCollector = _feeCollector;
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice V2 upgrade: set infinite USDT approval to ConditionalTokens.
    /// Replaces per-fill forceApprove in _splitAndDistribute (gas optimization).
    function initializeV2() external reinitializer(2) {
        usdt.forceApprove(address(conditionalTokens), type(uint256).max);
    }

    // ─── UUPS Authorization ───
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─── Modifiers ───
    modifier notFreezeAll() {
        if (systemMode == ShutdownMode.FREEZE_ALL) revert FreezeAllActive();
        _;
    }
    modifier onlyNormal() {
        if (systemMode != ShutdownMode.NORMAL) revert OnlyNormalMode();
        _;
    }

    // ═══════════════════════════════════════════════════════
    // ORDER CANCELLATION
    // ═══════════════════════════════════════════════════════

    // L-6: notFreezeAll on user-callable functions
    function cancelOrder(Order calldata order) external notFreezeAll {
        if (order.maker != msg.sender) revert Unauthorized();
        bytes32 h = hashOrder(order);
        isCancelled[h] = true;
        emit OrderCancelled(order.maker, h);
    }

    // L-1: Enforce monotonic increase + L-6: notFreezeAll
    function cancelAllBelowNonce(uint256 nonce) external notFreezeAll {
        if (nonce <= userNonce[msg.sender]) revert NonceNotIncreasing();
        userNonce[msg.sender] = nonce;
        emit NonceBumped(msg.sender, nonce);
    }

    // ═══════════════════════════════════════════════════════
    // SETTLEMENT (Non-Custodial — transferFrom from user wallets)
    // ═══════════════════════════════════════════════════════

    function settleBatch(
        uint256 batchId, Fill[] calldata fills
    ) external onlyRole(Roles.RELAYER_ROLE) onlyNormal nonReentrant {
        if (fills.length > MAX_FILLS_PER_BATCH) revert TooManyFills(fills.length, MAX_FILLS_PER_BATCH);

        bytes32 batchKey = bytes32(batchId);
        if (processedBatches[batchKey]) revert BatchAlreadyProcessed(batchId);
        processedBatches[batchKey] = true;

        uint256 successCount;
        uint256 skipCount;
        BatchAcc memory acc;

        for (uint256 i = 0; i < fills.length;) {
            string memory reason = _processFill(fills[i], acc);
            if (bytes(reason).length == 0) {
                successCount++;
            } else {
                emit FillSkipped(fills[i].makerOrder.marketId, _orderDigest(fills[i].makerOrder), reason);
                skipCount++;
            }
            unchecked { i++; }
        }

        if (acc.fees > 0) _collectFee(acc.fees);
        if (acc.surplus > 0) usdt.safeTransfer(treasury, acc.surplus);

        emit BatchSettled(batchId, successCount, skipCount, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // FORCE SETTLEMENT (resolved/expired markets — admin recovery)
    // ═══════════════════════════════════════════════════════

    /// @notice Settle fills on resolved/expired markets. Skips _checkMarket and deadline checks.
    /// @dev Only callable by SAFETY_COUNCIL_ROLE. Still validates signatures and balances.
    function forceSettleBatch(
        uint256 batchId, Fill[] calldata fills
    ) external onlyRole(Roles.SAFETY_COUNCIL_ROLE) nonReentrant {
        if (fills.length > MAX_FILLS_PER_BATCH) revert TooManyFills(fills.length, MAX_FILLS_PER_BATCH);

        bytes32 batchKey = bytes32(batchId);
        if (processedBatches[batchKey]) revert BatchAlreadyProcessed(batchId);
        processedBatches[batchKey] = true;

        uint256 successCount;
        uint256 skipCount;
        BatchAcc memory acc;

        for (uint256 i = 0; i < fills.length;) {
            string memory reason = _processForceSettleFill(fills[i], acc);
            if (bytes(reason).length == 0) {
                successCount++;
            } else {
                emit FillSkipped(fills[i].makerOrder.marketId, _orderDigest(fills[i].makerOrder), reason);
                skipCount++;
            }
            unchecked { i++; }
        }

        if (acc.fees > 0) _collectFee(acc.fees);
        if (acc.surplus > 0) usdt.safeTransfer(treasury, acc.surplus);

        emit ForceSettled(batchId, successCount, skipCount, msg.sender);
    }

    function _processForceSettleFill(Fill calldata fill, BatchAcc memory acc) internal returns (string memory) {
        return _processFillInternal(fill, acc, true);
    }

    // ═══════════════════════════════════════════════════════
    // V3: AGGREGATED MINT SWEEP
    // ═══════════════════════════════════════════════════════

    /// @notice Settle multiple MINT fills sharing the same taker + market via a single
    ///         splitPosition call. Emits individual FillExecuted per maker for indexer compat.
    function settleMintSweep(
        uint256 batchId, MintSweep calldata sw
    ) external onlyRole(Roles.RELAYER_ROLE) onlyNormal nonReentrant {
        uint256 n = sw.makerOrders.length;
        if (n == 0) revert SweepEmpty();
        if (sw.makerSigs.length != n || sw.fillAmounts.length != n || sw.fees.length != n)
            revert SweepLengthMismatch();
        if (n > MAX_FILLS_PER_BATCH) revert TooManyFills(n, MAX_FILLS_PER_BATCH);

        bytes32 batchKey = bytes32(batchId);
        if (processedBatches[batchKey]) revert BatchAlreadyProcessed(batchId);
        processedBatches[batchKey] = true;

        _executeMintSweep(sw, n);
        emit BatchSettled(batchId, n, 0, msg.sender);
    }

    /// @dev Internal: all MINT sweep logic extracted to stay within contract-size limit.
    function _executeMintSweep(MintSweep calldata sw, uint256 n) internal {
        uint256 marketId = sw.takerOrder.marketId;
        string memory err = _checkMarket(marketId);
        if (bytes(err).length > 0) revert SweepValidation(1);

        MarketRegistry.Market memory market = marketRegistry.getMarket(marketId);
        uint256 cps = _getCollateralPerSet(marketId);

        if (sw.takerOrder.side != Side.BUY) revert SweepValidation(2);
        if (sw.takerOrder.outcomeIndex >= market.outcomeSlotCount) revert SweepValidation(3);
        if (sw.takerOrder.price > cps) revert SweepValidation(4);
        _requireERC1155Receiver(sw.takerOrder.maker);

        bytes32 takerHash = _orderDigest(sw.takerOrder);
        err = _validateOrder(sw.takerOrder, sw.takerSig, false, takerHash, false);
        if (bytes(err).length > 0) revert SweepValidation(5);

        {
            uint256 selfMakerCost;
            uint256 estTakerCost;
            for (uint256 i = 0; i < n;) {
                uint256 amt = sw.fillAmounts[i];
                if (amt == 0) revert SweepValidation(6);

                uint256 mkPrice = sw.makerOrders[i].price;
                if (mkPrice > cps) revert SweepValidation(7);

                uint256 col = Math.mulDiv(amt, cps, 1e18);
                if (col == 0) revert SweepValidation(8);

                uint256 mkCost = Math.mulDiv(mkPrice, amt, 1e18);
                if (mkCost > col) revert SweepValidation(9);
                if (sw.fees[i] * 10_000 > col * MAX_FEE) revert SweepValidation(10);

                if (sw.makerOrders[i].maker == sw.takerOrder.maker) {
                    selfMakerCost = _checkedAdd(selfMakerCost, mkCost);
                }
                estTakerCost = _checkedAdd(estTakerCost, col - mkCost + sw.fees[i]);
                unchecked { i++; }
            }

            if (selfMakerCost > 0) {
                uint256 totalCost = _checkedAdd(selfMakerCost, estTakerCost);
                if (usdt.balanceOf(sw.takerOrder.maker) < totalCost) revert SweepValidation(11);
                if (usdt.allowance(sw.takerOrder.maker, address(this)) < totalCost) revert SweepValidation(12);
            }
        }

        (uint256 totalFill, uint256 totalCol, uint256 totalTakerCost, BatchAcc memory acc)
            = _sweepMakerPass(sw, n, marketId, cps);

        uint256 tf = filled[takerHash];
        if (tf == type(uint256).max || tf + totalFill > sw.takerOrder.amount) revert SweepValidation(13);
        filled[takerHash] += totalFill;
        _dustKill(takerHash, sw.takerOrder.amount);

        if (usdt.balanceOf(sw.takerOrder.maker) < totalTakerCost) revert SweepValidation(14);
        if (usdt.allowance(sw.takerOrder.maker, address(this)) < totalTakerCost) revert SweepValidation(15);
        usdt.safeTransferFrom(sw.takerOrder.maker, address(this), totalTakerCost);

        if (totalCol == 0) revert SweepValidation(16);
        // Option C: maxOpenInterest cap is now enforced inside MarketRegistry.addOIByCondition,
        //           triggered by ConditionalTokens.splitPosition() below.
        //           ExchangeCLOB only tracks volume; OI is auto-incremented in CT layer.
        marketRegistry.addVolume(marketId, totalCol);
        conditionalTokens.splitPosition(market.conditionId, totalCol);
        // After splitPosition: ExchangeCLOB holds both outcome shares + their OI eligibility.
        // The eligibility moves to maker/taker recipients via _update transfer hook
        // when shares are distributed in _sweepDistributePass / takerPosId transfer below.

        _sweepDistributePass(sw, n, market.conditionId, marketId, cps);
        uint256 takerPosId = _getPositionId(market.conditionId, sw.takerOrder.outcomeIndex);
        conditionalTokens.safeTransferFrom(address(this), sw.takerOrder.maker, takerPosId, totalCol, "");

        if (acc.fees > 0) _collectFee(acc.fees);
        if (acc.surplus > 0) usdt.safeTransfer(treasury, acc.surplus);
    }

    function _sweepMakerPass(
        MintSweep calldata sw, uint256 n, uint256 marketId, uint256 cps
    ) internal returns (uint256 totalFill, uint256 totalCol, uint256 totalTakerCost, BatchAcc memory acc) {
        for (uint256 i = 0; i < n;) {
            Order calldata mk = sw.makerOrders[i];
            uint256 amt = sw.fillAmounts[i];
            uint256 fee = sw.fees[i];

            if (mk.side != Side.BUY || mk.marketId != marketId) revert SweepValidation(17);
            if (mk.outcomeIndex >= 2) revert SweepValidation(18);
            if (mk.outcomeIndex == sw.takerOrder.outcomeIndex) revert SweepValidation(19);
            if (mk.price > cps) revert SweepValidation(20);
            _requireERC1155Receiver(mk.maker);
            bytes32 mkH = _orderDigest(mk);
            string memory mkErr = _validateOrder(mk, sw.makerSigs[i], true, mkH, false);
            if (bytes(mkErr).length > 0) revert SweepValidation(21);
            uint256 mf = filled[mkH];
            if (mf == type(uint256).max || mf + amt > mk.amount) revert SweepValidation(22);
            require(mk.price + sw.takerOrder.price >= cps, "sw:price_sum");

            uint256 col = Math.mulDiv(amt, cps, 1e18);
            if (col == 0) revert SweepValidation(23);
            uint256 mkCost = Math.mulDiv(mk.price, amt, 1e18);
            if (mkCost > col) revert SweepValidation(24);
            if (fee * 10_000 > col * MAX_FEE) revert SweepValidation(25);
            if (usdt.balanceOf(mk.maker) < mkCost) revert SweepValidation(26);
            if (usdt.allowance(mk.maker, address(this)) < mkCost) revert SweepValidation(27);

            filled[mkH] += amt;
            _dustKill(mkH, mk.amount);
            usdt.safeTransferFrom(mk.maker, address(this), mkCost);

            totalFill = _checkedAdd(totalFill, amt);
            totalCol = _checkedAdd(totalCol, col);
            totalTakerCost = _checkedAdd(totalTakerCost, col - mkCost + fee);
            if (fee > 0) acc.fees = _checkedAdd(acc.fees, fee);
            unchecked { i++; }
        }
    }

    function _sweepDistributePass(
        MintSweep calldata sw, uint256 n, bytes32 conditionId, uint256 marketId, uint256 cps
    ) internal {
        for (uint256 i = 0; i < n;) {
            uint256 shares = Math.mulDiv(sw.fillAmounts[i], cps, 1e18);
            uint256 mkPosId = _getPositionId(conditionId, sw.makerOrders[i].outcomeIndex);
            conditionalTokens.safeTransferFrom(address(this), sw.makerOrders[i].maker, mkPosId, shares, "");
            emit FillExecuted(
                marketId, sw.makerOrders[i].maker, sw.takerOrder.maker,
                sw.makerOrders[i].price, sw.fillAmounts[i], sw.fees[i],
                Side.BUY, MatchType.MINT
            );
            unchecked { i++; }
        }
    }

    /// @dev Returns empty string on success, or skip reason on failure.
    function _processFill(Fill calldata fill, BatchAcc memory acc) internal returns (string memory) {
        return _processFillInternal(fill, acc, false);
    }

    /// @dev Unified fill processor. force=true skips _checkMarket and deadline (force-settle path).
    /// @dev Skip reasons use short codes for EIP-170 size; see docs/audit-v2-operational-notes-ko.md §3 for mapping.
    function _processFillInternal(Fill calldata fill, BatchAcc memory acc, bool force) internal returns (string memory) {
        if (fill.fillAmount == 0) return "zf";

        Order calldata maker = fill.makerOrder;
        Order calldata taker = fill.takerOrder;

        if (maker.marketId != taker.marketId) return "mm";

        MatchType mt = fill.matchType;
        if (mt == MatchType.COMPLEMENTARY) {
            if (uint8(maker.side) == uint8(taker.side)) return "ss";
        } else if (mt == MatchType.MINT) {
            if (maker.side != Side.BUY || taker.side != Side.BUY) return "mb";
            if (maker.outcomeIndex == taker.outcomeIndex) return "mo";
        } else if (mt == MatchType.MERGE) {
            if (maker.side != Side.SELL || taker.side != Side.SELL) return "ms";
            if (maker.outcomeIndex == taker.outcomeIndex) return "mso";
        }

        if (force) {
            // Force-settle: skip _checkMarket (resolved/expired markets allowed)
            if (!marketRegistry.getMarket(maker.marketId).exists) return "mnf";
        } else {
            string memory marketErr = _checkMarket(maker.marketId);
            if (bytes(marketErr).length > 0) return marketErr;
        }

        bytes32 makerHash = _orderDigest(maker);
        bytes32 takerHash = _orderDigest(taker);

        string memory makerErr = _validateOrder(maker, fill.makerSig, true, makerHash, force);
        if (bytes(makerErr).length > 0) return makerErr;
        string memory takerErr = _validateOrder(taker, fill.takerSig, false, takerHash, force);
        if (bytes(takerErr).length > 0) return takerErr;

        uint256 makerFilled = filled[makerHash];
        if (makerFilled == type(uint256).max || makerFilled + fill.fillAmount > maker.amount) return "mof";
        uint256 takerFilled = filled[takerHash];
        if (takerFilled == type(uint256).max || takerFilled + fill.fillAmount > taker.amount) return "tof";

        return _executeSettlement(fill, makerHash, takerHash, acc);
    }

    function _checkMarket(uint256 marketId) internal view returns (string memory) {
        MarketRegistry.Market memory m = marketRegistry.getMarket(marketId);
        if (!m.exists) return "mnf";
        if (m.resolved) return "mrs";
        if (m.frozen) return "mfr";
        // H-1 v2: Enforce tradingCutoff on-chain (endTime not checked — relayer grace period)
        if (m.tradingCutoff > 0 && block.timestamp >= m.tradingCutoff) return "mcp";
        return "";
    }

    // M-1: Takes precomputed hash to avoid double computation
    // H-3: Added sanctioned check
    // skipDeadline=true: force-settle path (allows expired orders for recovery)
    function _validateOrder(
        Order calldata order, bytes calldata sig, bool isMaker, bytes32 h, bool skipDeadline
    ) internal view returns (string memory) {
        if (order.orderType != OrderType.LIMIT) return isMaker ? "mut" : "tut";
        if (sanctioned[order.maker]) return isMaker ? "msn" : "tsn";
        if (order.nonce < userNonce[order.maker]) return isMaker ? "mnl" : "tnl";
        if (isCancelled[h]) return isMaker ? "mcl" : "tcl";
        if (!skipDeadline && block.timestamp > order.deadline) return isMaker ? "mexp" : "texp";

        if (!_verifySignature(order.maker, h, sig)) {
            if (order.maker.code.length > 0) return isMaker ? "mscf" : "tscf";
            return isMaker ? "msig" : "tsig";
        }
        return "";
    }

    function _executeSettlement(Fill calldata fill, bytes32 makerHash, bytes32 takerHash, BatchAcc memory acc) internal returns (string memory) {
        FillCtx memory ctx;
        ctx.marketId = fill.makerOrder.marketId;
        ctx.executionPrice = fill.makerOrder.price; // Maker price (Surplus Matching)
        ctx.fillValue = Math.mulDiv(ctx.executionPrice, fill.fillAmount, 1e18, Math.Rounding.Ceil);
        ctx.outcomeIndex = fill.makerOrder.outcomeIndex;
        ctx.makerHash = makerHash;
        ctx.takerHash = takerHash;

        MarketRegistry.Market memory market = marketRegistry.getMarket(ctx.marketId);
        ctx.conditionId = market.conditionId;

        // V3: MINT fills must go through settleMintSweep
        if (fill.matchType == MatchType.MINT) return "mus";

        if (fill.matchType == MatchType.COMPLEMENTARY) {
            return _executeComplementary(fill, ctx, acc);
        } else {
            return _executeMerge(fill, ctx, acc);
        }
    }

    /// @dev COMPLEMENTARY: same-token BUY↔SELL — P2P transferFrom
    function _executeComplementary(Fill calldata fill, FillCtx memory ctx, BatchAcc memory acc) internal returns (string memory) {
        // H-5 v2: Both orders must reference the same outcome for COMPLEMENTARY
        if (fill.makerOrder.outcomeIndex != fill.takerOrder.outcomeIndex) return "ocm";

        // Price crossing validation
        if (fill.takerOrder.side == Side.BUY) {
            if (ctx.executionPrice > fill.takerOrder.price) return "pnc";
        } else {
            if (ctx.executionPrice < fill.takerOrder.price) return "pnc";
        }

        // Fee bps check
        if (ctx.fillValue > 0 && fill.fee * 10_000 > ctx.fillValue * MAX_FEE) return "fth";

        // Determine buyer/seller
        if (fill.makerOrder.side == Side.BUY) {
            ctx.buyer = fill.makerOrder.maker;
            ctx.seller = fill.takerOrder.maker;
        } else {
            ctx.buyer = fill.takerOrder.maker;
            ctx.seller = fill.makerOrder.maker;
        }

        // CPS scaling: on-chain conditional tokens are denominated in collateral units,
        // not fillAmount units. 1 off-chain "share" = CPS/1e18 conditional tokens.
        uint256 cps = _getCollateralPerSet(ctx.marketId);
        uint256 shareAmount = Math.mulDiv(fill.fillAmount, cps, 1e18);
        if (shareAmount == 0) return "saz";

        // Non-custodial balance + allowance checks (on-chain)
        // QGM-12: buyer pays fillValue + fee; seller receives full fillValue
        uint256 posId = _getPositionId(ctx.conditionId, ctx.outcomeIndex);
        uint256 buyerTotal = _checkedAdd(ctx.fillValue, fill.fee);
        if (usdt.balanceOf(ctx.buyer) < buyerTotal) return "bib";
        // M-8 v2: Pre-check allowance to avoid batch-killing revert
        if (usdt.allowance(ctx.buyer, address(this)) < buyerTotal) return "bia";
        if (conditionalTokens.balanceOf(ctx.seller, posId) < shareAmount) {
            return "sis";
        }
        if (!conditionalTokens.isApprovedForAll(ctx.seller, address(this))) return "sna";
        // QGM-30: ERC1155 receiver pre-check
        if (!_canReceiveERC1155(ctx.buyer)) return "bri";

        // ── Execute (CEI) ──
        _applyComplementary(fill, ctx, posId, shareAmount, acc);
        return "";
    }

    // V3: _executeMint removed — all MINT fills now routed through settleMintSweep

    /// @dev MERGE: cross-outcome SELL+SELL → mergePositions
    function _executeMerge(Fill calldata fill, FillCtx memory ctx, BatchAcc memory acc) internal returns (string memory) {
        uint256 cps = _getCollateralPerSet(ctx.marketId);
        if (fill.makerOrder.price + fill.takerOrder.price > cps) return "pao";

        // Fee check: fee against collateral, not shares
        uint256 collateral = Math.mulDiv(fill.fillAmount, cps, 1e18);
        if (collateral == 0) return "mzc";
        if (fill.fee * 10_000 > collateral * MAX_FEE) return "fth";

        // H-1: Fee underflow guard — check fee doesn't exceed taker proceeds
        uint256 makerPay = Math.mulDiv(fill.makerOrder.price, fill.fillAmount, 1e18);
        uint256 takerPay = collateral - makerPay;
        if (fill.fee > takerPay) return "ftp";

        // Non-custodial shares checks
        uint256 makerOi = fill.makerOrder.outcomeIndex;
        uint256 takerOi = fill.takerOrder.outcomeIndex;
        uint256 makerPosId = _getPositionId(ctx.conditionId, makerOi);
        uint256 takerPosId = _getPositionId(ctx.conditionId, takerOi);

        if (conditionalTokens.balanceOf(fill.makerOrder.maker, makerPosId) < collateral) {
            return "mis";
        }
        if (!conditionalTokens.isApprovedForAll(fill.makerOrder.maker, address(this))) return "mna";
        if (conditionalTokens.balanceOf(fill.takerOrder.maker, takerPosId) < collateral) {
            return "tis";
        }
        if (!conditionalTokens.isApprovedForAll(fill.takerOrder.maker, address(this))) return "tna";

        // NOTE: trackedShares (musr/tusr) check removed — minimum-fix model.
        //       Direct-split shares fed into MERGE are blocked at MarketRegistry.subtractOI revert,
        //       which atomically rolls back the entire fill (no fund loss, just tx revert).
        //       Off-chain BatchBuilder should pre-filter via share_acquisitions tracking.

        _applyMerge(fill, ctx, makerPosId, takerPosId, makerPay, collateral, acc);
        return "";
    }

    /// @dev COMPLEMENTARY settlement: P2P transferFrom (Polymarket-style)
    function _applyComplementary(Fill calldata fill, FillCtx memory ctx, uint256 posId, uint256 shareAmount, BatchAcc memory acc) internal {
        // ── 1. Filled tracking (M-1: by orderHash) ──
        filled[ctx.makerHash] += fill.fillAmount;
        filled[ctx.takerHash] += fill.fillAmount;

        // ── 2. M-4: COMPLEMENTARY = volume only, no OI change ──
        marketRegistry.addVolume(ctx.marketId, ctx.fillValue);

        // ── 3. Dust Kill (M-1: by orderHash) ──
        _dustKill(ctx.makerHash, fill.makerOrder.amount);
        _dustKill(ctx.takerHash, fill.takerOrder.amount);

        // ── 4. USDT: buyer → seller (full fillValue), fee paid separately by buyer ──
        // QGM-12: buyer pays fillValue + fee separately. Seller receives full fillValue.
        uint256 sellerProceeds = ctx.fillValue;
        if (fill.fee > 0) {
            usdt.safeTransferFrom(ctx.buyer, address(this), fill.fee);
            acc.fees = _checkedAdd(acc.fees, fill.fee);
        }
        if (sellerProceeds > 0) {
            usdt.safeTransferFrom(ctx.buyer, ctx.seller, sellerProceeds);
        }

        // ── 5. ERC1155 shares: seller → buyer (CPS-scaled amount) ──
        conditionalTokens.safeTransferFrom(ctx.seller, ctx.buyer, posId, shareAmount, "");

        // L-7: matchType in event
        emit FillExecuted(
            ctx.marketId, fill.makerOrder.maker, fill.takerOrder.maker,
            ctx.executionPrice, fill.fillAmount, fill.fee, fill.makerOrder.side,
            MatchType.COMPLEMENTARY
        );
    }

    // V3: _applyMint + _splitAndDistribute removed — all MINT fills now routed through settleMintSweep

    /// @dev MERGE settlement: SELL+SELL → mergePositions (transient custody)
    function _applyMerge(
        Fill calldata fill, FillCtx memory ctx,
        uint256 makerPosId, uint256 takerPosId, uint256 makerPay, uint256 collateral, BatchAcc memory acc
    ) internal {
        uint256 amt = fill.fillAmount;
        address makerAddr = fill.makerOrder.maker;
        address takerAddr = fill.takerOrder.maker;

        // ── 1. Filled tracking (M-1: by orderHash) ──
        filled[ctx.makerHash] += amt;
        filled[ctx.takerHash] += amt;

        // ── 2. M-4: MERGE = volume only at this layer ──
        // Option C: OI decrement is now driven by ConditionalTokens.mergePositions()
        //           via subtractOIByCondition hook, gated on ExchangeCLOB's own
        //           eligibility holdings (transferred in from maker/taker via _update hook).
        //           Direct-split shares without eligibility do NOT decrement OI — closing
        //           QGM-03 "Source Tracking" recommendation in the ConditionalTokens layer.
        marketRegistry.addVolume(ctx.marketId, makerPay);

        // ── 3. Dust Kill (M-1: by orderHash) ──
        _dustKill(ctx.makerHash, fill.makerOrder.amount);
        _dustKill(ctx.takerHash, fill.takerOrder.amount);

        // ── 4. Pull shares from both sellers into Exchange (transient) ──
        conditionalTokens.safeTransferFrom(makerAddr, address(this), makerPosId, collateral, "");
        conditionalTokens.safeTransferFrom(takerAddr, address(this), takerPosId, collateral, "");

        // ── 5. Merge: burn YES+NO shares → get USDT back ──
        conditionalTokens.mergePositions(ctx.conditionId, collateral);

        // ── 6. Distribute USDT + fee ──
        _distributeMergeProceeds(fill, makerAddr, takerAddr, makerPay, collateral, acc);

        // L-7: matchType in event
        emit FillExecuted(
            ctx.marketId, makerAddr, takerAddr,
            ctx.executionPrice, amt, fill.fee, fill.makerOrder.side,
            MatchType.MERGE
        );
    }

    function _distributeMergeProceeds(
        Fill calldata fill, address makerAddr, address takerAddr,
        uint256 makerPay, uint256 amt, BatchAcc memory acc
    ) internal {
        uint256 takerPay = amt - makerPay;

        if (fill.fee > 0) {
            acc.fees = _checkedAdd(acc.fees, fill.fee);
            // Fee deducted from taker's share (H-1 guard already checked fee <= takerPay)
            takerPay -= fill.fee;
        }

        if (makerPay > 0) {
            usdt.safeTransfer(makerAddr, makerPay);
        }
        if (takerPay > 0) {
            usdt.safeTransfer(takerAddr, takerPay);
        }
    }

    // M-3: Safe transfer pattern with fallback to unclaimedFees
    function _collectFee(uint256 fee) internal {
        (bool success, bytes memory data) = address(usdt).call(
            abi.encodeWithSelector(IERC20.transfer.selector, feeCollector, fee)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            unclaimedFees[feeCollector] += fee;
        }
    }

    // M-1: Dust kill by orderHash
    function _dustKill(bytes32 orderHash, uint256 orderAmount) internal {
        uint256 f = filled[orderHash];
        if (f < type(uint256).max && orderAmount - f < MIN_ORDER) {
            filled[orderHash] = type(uint256).max;
        }
    }

    function _checkedAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) revert ArithmeticOverflow();
            return c;
        }
    }

    function _canReceiveERC1155(address account) internal view returns (bool) {
        if (account.code.length == 0) return true;

        (bool success, bytes memory result) = account.staticcall(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IERC1155Receiver).interfaceId)
        );
        return success && result.length >= 32 && abi.decode(result, (bool));
    }

    function _requireERC1155Receiver(address account) internal view {
        if (!_canReceiveERC1155(account)) revert ReceiverIncompatible();
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════

    function setSanctioned(address user, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sanctioned[user] = status;
        emit SanctionUpdated(user, status);
    }

    // L-3: Zero-address checks on setters
    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fc == address(0)) revert ZeroAddress();
        feeCollector = fc;
    }
    function setTreasury(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
    }

    // ─── Shutdown ───
    function emergencyStop() external onlyRole(Roles.PAUSER_ROLE) {
        systemMode = ShutdownMode.EMERGENCY_STOP;
        emit ShutdownModeChanged(ShutdownMode.EMERGENCY_STOP);
    }
    function freezeAll() external onlyRole(Roles.PAUSER_ROLE) {
        systemMode = ShutdownMode.FREEZE_ALL;
        emit ShutdownModeChanged(ShutdownMode.FREEZE_ALL);
    }
    function resume() external onlyRole(DEFAULT_ADMIN_ROLE) {
        systemMode = ShutdownMode.NORMAL;
        emit ShutdownModeChanged(ShutdownMode.NORMAL);
    }

    // ─── Sweep ───
    function sweep(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(usdt) || token == address(conditionalTokens)) {
            revert CannotSweepProtectedToken(token);
        }
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Swept(token, amount);
    }

    // ─── Sweep ERC1155 (L-4 v2: rescue misrouted tokens) ───
    function sweepERC1155(address token, uint256 id, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC1155(token).safeTransferFrom(address(this), msg.sender, id, amount, "");
    }

    // ─── Claim Fees ───
    // L-6: notFreezeAll on user-callable function
    function claimFees() external nonReentrant notFreezeAll {
        uint256 amount = unclaimedFees[msg.sender];
        if (amount == 0) revert NoUnclaimedFees();
        unclaimedFees[msg.sender] = 0; // CEI
        usdt.safeTransfer(msg.sender, amount);
        emit FeesClaimed(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════
    // EIP-712 HELPERS
    // ═══════════════════════════════════════════════════════

    function hashOrder(Order calldata order) public view returns (bytes32) {
        return _orderDigest(order);
    }

    function _orderDigest(Order calldata order) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            ORDER_TYPEHASH,
            order.maker, order.marketId, order.outcomeIndex, uint8(order.side),
            order.amount, order.price, order.nonce, order.deadline,
            uint8(order.orderType), order.salt
        )));
    }

    // ─── Signature Verification with Gas Limit ───

    function _verifySignature(
        address signer, bytes32 digest, bytes calldata sig
    ) internal view returns (bool) {
        // ECDSA first (~3k gas for EOA)
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;

        // EIP-1271 with gas limit (ProxyWallet / AA ~30k, cap at 50k)
        if (signer.code.length > 0) {
            (bool success, bytes memory result) = signer.staticcall{gas: SIG_VERIFY_GAS_LIMIT}(
                abi.encodeCall(IERC1271.isValidSignature, (digest, sig))
            );
            return success && result.length >= 32
                && abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector;
        }
        return false;
    }

    // ─── Internal Helpers ───

    function _getCollateralPerSet(uint256 marketId) internal view returns (uint256) {
        return marketRegistry.getCollateralPerSet(marketId);
    }

    function _getPositionId(bytes32 conditionId, uint256 outcomeIndex) internal view returns (uint256) {
        uint256 indexSet = 1 << outcomeIndex;
        bytes32 collectionId = conditionalTokens.getCollectionId(conditionId, indexSet);
        return conditionalTokens.getPositionId(address(usdt), collectionId);
    }

    // ─── ERC1155 Receiver (needed for transient MINT/MERGE custody) ───
    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControlEnumerableUpgradeable, ERC1155Holder) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ─── Storage Gap ───
    uint256[45] private __gap;
}
