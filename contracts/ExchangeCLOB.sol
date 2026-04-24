// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
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
contract ExchangeCLOB is
    Initializable,
    AccessControlEnumerableUpgradeable,
    EIP712Upgradeable,
    ERC1155Holder,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

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

    event FeesClaimed(address indexed collector, uint256 amount);
    event ShutdownModeChanged(ShutdownMode mode);
    event Swept(address indexed token, uint256 amount);
    event SanctionUpdated(address indexed user, bool sanctioned_);

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
        require(_usdt != address(0), "Zero usdt");
        require(_conditionalTokens != address(0), "Zero ct");
        require(_marketRegistry != address(0), "Zero registry");
        require(_feeCollector != address(0), "Zero feeCollector");
        require(_treasury != address(0), "Zero treasury");

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
        require(nonce > userNonce[msg.sender], "Can only increase nonce");
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
        require(bytes(err).length == 0, err);

        MarketRegistry.Market memory market = marketRegistry.getMarket(marketId);
        uint256 cps = _getCollateralPerSet(marketId);

        require(sw.takerOrder.side == Side.BUY, "sw:taker_buy");
        bytes32 takerHash = _orderDigest(sw.takerOrder);
        err = _validateOrder(sw.takerOrder, sw.takerSig, false, takerHash);
        require(bytes(err).length == 0, err);

        // QGM-05: Pre-check aggregate balance for self-matched sweeps (maker == taker)
        {
            uint256 selfMakerCost;
            uint256 estTakerCost;
            for (uint256 i = 0; i < n;) {
                uint256 mkCost = (sw.makerOrders[i].price * sw.fillAmounts[i]) / 1e18;
                uint256 col = (sw.fillAmounts[i] * cps) / 1e18;
                if (sw.makerOrders[i].maker == sw.takerOrder.maker) {
                    selfMakerCost += mkCost;
                }
                estTakerCost += (col - mkCost + sw.fees[i]);
                unchecked { i++; }
            }
            if (selfMakerCost > 0) {
                uint256 totalCost = selfMakerCost + estTakerCost;
                require(usdt.balanceOf(sw.takerOrder.maker) >= totalCost, "sw:self_bal");
                require(usdt.allowance(sw.takerOrder.maker, address(this)) >= totalCost, "sw:self_alw");
            }
        }

        // Pass 1: validate makers, pull USDT, track fills
        (uint256 totalFill, uint256 totalCol, uint256 totalTakerCost, BatchAcc memory acc)
            = _sweepMakerPass(sw, n, marketId, cps);

        // Taker fill tracking
        uint256 tf = filled[takerHash];
        require(tf != type(uint256).max && tf + totalFill <= sw.takerOrder.amount, "sw:taker_ovfill");
        filled[takerHash] += totalFill;
        _dustKill(takerHash, sw.takerOrder.amount);

        // Taker USDT pull (once)
        require(usdt.balanceOf(sw.takerOrder.maker) >= totalTakerCost, "sw:taker_bal");
        require(usdt.allowance(sw.takerOrder.maker, address(this)) >= totalTakerCost, "sw:taker_alw");
        usdt.safeTransferFrom(sw.takerOrder.maker, address(this), totalTakerCost);

        // OI + single splitPosition
        if (market.maxOpenInterest > 0)
            require(market.currentOI + totalFill <= market.maxOpenInterest, "sw:oi");
        marketRegistry.addVolumeAndOI(marketId, totalCol, totalFill);
        conditionalTokens.splitPosition(market.conditionId, totalCol);

        // Pass 2: distribute shares + emit events (shares = fillAmount × CPS / 1e18)
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

            require(mk.side == Side.BUY && mk.marketId == marketId, "sw:mk_invalid");
            require(mk.outcomeIndex != sw.takerOrder.outcomeIndex, "sw:same_out");
            bytes32 mkH = _orderDigest(mk);
            string memory mkErr = _validateOrder(mk, sw.makerSigs[i], true, mkH);
            require(bytes(mkErr).length == 0, mkErr);
            uint256 mf = filled[mkH];
            require(mf != type(uint256).max && mf + amt <= mk.amount, "sw:mk_ovfill");
            require(mk.price + sw.takerOrder.price >= cps, "sw:price_sum");

            uint256 col = (amt * cps) / 1e18;
            uint256 mkCost = (mk.price * amt) / 1e18;
            require(col == 0 || fee * 10_000 <= col * MAX_FEE, "sw:fee");
            require(usdt.balanceOf(mk.maker) >= mkCost, "sw:mk_bal");
            require(usdt.allowance(mk.maker, address(this)) >= mkCost, "sw:mk_alw");

            filled[mkH] += amt;
            _dustKill(mkH, mk.amount);
            usdt.safeTransferFrom(mk.maker, address(this), mkCost);

            totalFill += amt;
            totalCol += col;
            totalTakerCost += (col - mkCost + fee);
            if (fee > 0) acc.fees += fee;
            unchecked { i++; }
        }
    }

    function _sweepDistributePass(
        MintSweep calldata sw, uint256 n, bytes32 conditionId, uint256 marketId, uint256 cps
    ) internal {
        for (uint256 i = 0; i < n;) {
            uint256 shares = (sw.fillAmounts[i] * cps) / 1e18;
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
        if (fill.fillAmount == 0) return "zero_fill_amount";

        Order calldata maker = fill.makerOrder;
        Order calldata taker = fill.takerOrder;

        if (maker.marketId != taker.marketId) return "market_mismatch";

        MatchType mt = fill.matchType;
        if (mt == MatchType.COMPLEMENTARY) {
            if (uint8(maker.side) == uint8(taker.side)) return "same_side";
        } else if (mt == MatchType.MINT) {
            if (maker.side != Side.BUY || taker.side != Side.BUY) return "mint_requires_buys";
            if (maker.outcomeIndex == taker.outcomeIndex) return "mint_same_outcome";
        } else if (mt == MatchType.MERGE) {
            if (maker.side != Side.SELL || taker.side != Side.SELL) return "merge_requires_sells";
            if (maker.outcomeIndex == taker.outcomeIndex) return "merge_same_outcome";
        }

        string memory marketErr = _checkMarket(maker.marketId);
        if (bytes(marketErr).length > 0) return marketErr;

        bytes32 makerHash = _orderDigest(maker);
        bytes32 takerHash = _orderDigest(taker);

        string memory makerErr = _validateOrder(maker, fill.makerSig, true, makerHash);
        if (bytes(makerErr).length > 0) return makerErr;
        string memory takerErr = _validateOrder(taker, fill.takerSig, false, takerHash);
        if (bytes(takerErr).length > 0) return takerErr;

        uint256 makerFilled = filled[makerHash];
        if (makerFilled == type(uint256).max || makerFilled + fill.fillAmount > maker.amount) return "maker_overfill";
        uint256 takerFilled = filled[takerHash];
        if (takerFilled == type(uint256).max || takerFilled + fill.fillAmount > taker.amount) return "taker_overfill";

        return _executeSettlement(fill, makerHash, takerHash, acc);
    }

    function _checkMarket(uint256 marketId) internal view returns (string memory) {
        MarketRegistry.Market memory m = marketRegistry.getMarket(marketId);
        if (!m.exists) return "market_not_found";
        if (m.resolved) return "market_resolved";
        if (m.frozen) return "market_frozen";
        // H-1 v2: Enforce tradingCutoff on-chain (endTime not checked — relayer grace period)
        if (m.tradingCutoff > 0 && block.timestamp >= m.tradingCutoff) return "trading_cutoff_passed";
        return "";
    }

    // M-1: Takes precomputed hash to avoid double computation
    // H-3: Added sanctioned check
    function _validateOrder(
        Order calldata order, bytes calldata sig, bool isMaker, bytes32 h
    ) internal view returns (string memory) {
        string memory prefix = isMaker ? "maker" : "taker";

        if (order.orderType != OrderType.LIMIT) return string.concat(prefix, "_unsupported_type");
        if (sanctioned[order.maker]) return string.concat(prefix, "_sanctioned");
        if (order.nonce < userNonce[order.maker]) return string.concat(prefix, "_nonce_low");
        if (isCancelled[h]) return string.concat(prefix, "_cancelled");
        if (block.timestamp > order.deadline) return string.concat(prefix, "_expired");

        if (!_verifySignature(order.maker, h, sig)) {
            if (order.maker.code.length > 0) return string.concat(prefix, "_sig_contract_failed");
            return string.concat(prefix, "_sig_invalid");
        }
        return "";
    }

    function _executeSettlement(Fill calldata fill, bytes32 makerHash, bytes32 takerHash, BatchAcc memory acc) internal returns (string memory) {
        FillCtx memory ctx;
        ctx.marketId = fill.makerOrder.marketId;
        ctx.executionPrice = fill.makerOrder.price; // Maker price (Surplus Matching)
        // M-5: ceilDiv for buyer cost (round in protocol's favor)
        ctx.fillValue = _ceilDiv(ctx.executionPrice * fill.fillAmount, 1e18);
        ctx.outcomeIndex = fill.makerOrder.outcomeIndex;
        ctx.makerHash = makerHash;
        ctx.takerHash = takerHash;

        MarketRegistry.Market memory market = marketRegistry.getMarket(ctx.marketId);
        ctx.conditionId = market.conditionId;

        // V3: MINT fills must go through settleMintSweep
        if (fill.matchType == MatchType.MINT) return "mint_use_sweep";

        if (fill.matchType == MatchType.COMPLEMENTARY) {
            return _executeComplementary(fill, ctx, acc);
        } else {
            return _executeMerge(fill, ctx, acc);
        }
    }

    /// @dev COMPLEMENTARY: same-token BUY↔SELL — P2P transferFrom
    function _executeComplementary(Fill calldata fill, FillCtx memory ctx, BatchAcc memory acc) internal returns (string memory) {
        // H-5 v2: Both orders must reference the same outcome for COMPLEMENTARY
        if (fill.makerOrder.outcomeIndex != fill.takerOrder.outcomeIndex) return "outcome_mismatch";

        // Price crossing validation
        if (fill.takerOrder.side == Side.BUY) {
            if (ctx.executionPrice > fill.takerOrder.price) return "price_not_crossing";
        } else {
            if (ctx.executionPrice < fill.takerOrder.price) return "price_not_crossing";
        }

        // Fee bps check
        if (ctx.fillValue > 0 && fill.fee * 10_000 > ctx.fillValue * MAX_FEE) return "fee_too_high";

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
        uint256 shareAmount = (fill.fillAmount * cps) / 1e18;

        // Non-custodial balance + allowance checks (on-chain)
        uint256 posId = _getPositionId(ctx.conditionId, ctx.outcomeIndex);
        if (usdt.balanceOf(ctx.buyer) < ctx.fillValue) return "buyer_insufficient_balance";
        // M-8 v2: Pre-check allowance to avoid batch-killing revert
        if (usdt.allowance(ctx.buyer, address(this)) < ctx.fillValue) return "buyer_insufficient_allowance";
        if (conditionalTokens.balanceOf(ctx.seller, posId) < shareAmount) {
            return "seller_insufficient_shares";
        }
        if (!conditionalTokens.isApprovedForAll(ctx.seller, address(this))) return "seller_not_approved";

        // ── Execute (CEI) ──
        _applyComplementary(fill, ctx, posId, shareAmount, acc);
        return "";
    }

    // V3: _executeMint removed — all MINT fills now routed through settleMintSweep

    /// @dev MERGE: cross-outcome SELL+SELL → mergePositions
    function _executeMerge(Fill calldata fill, FillCtx memory ctx, BatchAcc memory acc) internal returns (string memory) {
        uint256 cps = _getCollateralPerSet(ctx.marketId);
        if (fill.makerOrder.price + fill.takerOrder.price > cps) return "price_sum_above_one";

        // Fee check: fee against collateral, not shares
        uint256 collateral = (fill.fillAmount * cps) / 1e18;
        if (collateral > 0 && fill.fee * 10_000 > collateral * MAX_FEE) return "fee_too_high";

        // H-1: Fee underflow guard — check fee doesn't exceed taker proceeds
        uint256 makerPay = (fill.makerOrder.price * fill.fillAmount) / 1e18;
        uint256 takerPay = collateral - makerPay;
        if (fill.fee > takerPay) return "fee_exceeds_taker_proceeds";

        // Non-custodial shares checks
        uint256 makerOi = fill.makerOrder.outcomeIndex;
        uint256 takerOi = fill.takerOrder.outcomeIndex;
        uint256 makerPosId = _getPositionId(ctx.conditionId, makerOi);
        uint256 takerPosId = _getPositionId(ctx.conditionId, takerOi);

        if (conditionalTokens.balanceOf(fill.makerOrder.maker, makerPosId) < collateral) {
            return "maker_insufficient_shares";
        }
        if (!conditionalTokens.isApprovedForAll(fill.makerOrder.maker, address(this))) return "maker_not_approved";
        if (conditionalTokens.balanceOf(fill.takerOrder.maker, takerPosId) < collateral) {
            return "taker_insufficient_shares";
        }
        if (!conditionalTokens.isApprovedForAll(fill.takerOrder.maker, address(this))) return "taker_not_approved";

        _applyMerge(fill, ctx, makerPosId, takerPosId, makerPay, acc);
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

        // ── 4. USDT: buyer → seller (minus fee), fee accumulated in BatchAcc ──
        // QGM-06: Collect USDT before ERC1155 transfer to prevent callback manipulation
        uint256 sellerProceeds = ctx.fillValue;
        if (fill.fee > 0) {
            sellerProceeds -= fill.fee;
            usdt.safeTransferFrom(ctx.buyer, address(this), fill.fee);
            acc.fees += fill.fee;
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
        uint256 makerPosId, uint256 takerPosId, uint256 makerPay, BatchAcc memory acc
    ) internal {
        uint256 amt = fill.fillAmount;
        uint256 cps = _getCollateralPerSet(ctx.marketId);
        uint256 collateral = (amt * cps) / 1e18;
        address makerAddr = fill.makerOrder.maker;
        address takerAddr = fill.takerOrder.maker;

        // ── 1. Filled tracking (M-1: by orderHash) ──
        filled[ctx.makerHash] += amt;
        filled[ctx.takerHash] += amt;

        // ── 2. M-4: MERGE = volume + OI decrease ──
        marketRegistry.addVolume(ctx.marketId, makerPay);
        marketRegistry.subtractOI(ctx.marketId, amt);

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
            acc.fees += fill.fee;
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

    // M-5: Ceil division helper
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
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
        require(fc != address(0), "Zero address");
        feeCollector = fc;
    }
    function setTreasury(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(t != address(0), "Zero address");
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
    uint256[46] private __gap;
}
