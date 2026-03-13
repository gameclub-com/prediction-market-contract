// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "./Roles.sol";
import "./ConditionalTokens.sol";
import "./MarketRegistry.sol";

/// @title ExchangeCLOB — Non-Custodial Central Limit Order Book Exchange (Polymarket-style)
/// @notice Off-chain matching + on-chain batch settlement via transferFrom.
///         Users hold tokens in their own wallets (ProxyWallet). Exchange pulls via approval.
///         No deposit/withdraw — Exchange never custodies user funds (except transiently for MINT/MERGE).
/// @dev EIP-712 signed orders. MatchType: COMPLEMENTARY, MINT, MERGE.
contract ExchangeCLOB is AccessControl, EIP712, ReentrancyGuard, ERC1155Holder {
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

    // ─── Custom Errors ───
    error OrderExpired(bytes32 hash, uint256 deadline);
    error NonceTooLow(address maker, uint256 current, uint256 required);
    error BatchAlreadyProcessed(uint256 batchId);
    error MarketIsResolved(uint256 marketId);
    error SystemNotActive(uint8 currentMode);
    error SanctionedAddress(address user);
    error SignatureVerificationFailed(address signer);
    error Unauthorized();
    error ZeroAmount();
    error TooManyFills(uint256 count, uint256 max);
    error NoUnclaimedFees();
    error CannotSweepProtectedToken(address token);
    error FreezeAllActive();
    error OnlyNormalMode();
    error OrderCancelledError(bytes32 orderHash);

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

    IERC20 public immutable usdt;
    ConditionalTokens public immutable conditionalTokens;
    MarketRegistry public immutable marketRegistry;
    address public feeCollector;
    address public treasury;

    // ─── Constructor ───
    constructor(
        address _usdt,
        address _conditionalTokens,
        address _marketRegistry,
        address _feeCollector,
        address _treasury
    ) EIP712("GameClub Exchange", "1") {
        // L-3: Zero-address checks
        require(_usdt != address(0), "Zero usdt");
        require(_conditionalTokens != address(0), "Zero ct");
        require(_marketRegistry != address(0), "Zero registry");
        require(_feeCollector != address(0), "Zero feeCollector");
        require(_treasury != address(0), "Zero treasury");
        usdt = IERC20(_usdt);
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        marketRegistry = MarketRegistry(_marketRegistry);
        feeCollector = _feeCollector;
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

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

        // L-2: Simplified batchKey
        bytes32 batchKey = bytes32(batchId);
        if (processedBatches[batchKey]) revert BatchAlreadyProcessed(batchId);
        processedBatches[batchKey] = true;

        uint256 successCount;
        uint256 skipCount;

        // G-3: Unchecked loop counter
        for (uint256 i = 0; i < fills.length;) {
            string memory reason = _processFill(fills[i]);
            if (bytes(reason).length == 0) {
                successCount++;
            } else {
                emit FillSkipped(fills[i].makerOrder.marketId, _orderDigest(fills[i].makerOrder), reason);
                skipCount++;
            }
            unchecked { i++; }
        }

        emit BatchSettled(batchId, successCount, skipCount, msg.sender);
    }

    /// @dev Returns empty string on success, or skip reason on failure.
    function _processFill(Fill calldata fill) internal returns (string memory) {
        Order calldata maker = fill.makerOrder;
        Order calldata taker = fill.takerOrder;

        // ── Basic checks ──
        if (maker.marketId != taker.marketId) return "market_mismatch";

        // Derive and validate matchType
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

        // ── Market checks ──
        string memory marketErr = _checkMarket(maker.marketId);
        if (bytes(marketErr).length > 0) return marketErr;

        // ── Compute order hashes once (M-1) ──
        bytes32 makerHash = _orderDigest(maker);
        bytes32 takerHash = _orderDigest(taker);

        // ── Order validation (H-3: sanctioned check inside) ──
        string memory makerErr = _validateOrder(maker, fill.makerSig, true, makerHash);
        if (bytes(makerErr).length > 0) return makerErr;

        string memory takerErr = _validateOrder(taker, fill.takerSig, false, takerHash);
        if (bytes(takerErr).length > 0) return takerErr;

        // ── Fill amount checks (M-1: keyed by orderHash) ──
        uint256 makerFilled = filled[makerHash];
        if (makerFilled == type(uint256).max || makerFilled + fill.fillAmount > maker.amount) return "maker_overfill";
        uint256 takerFilled = filled[takerHash];
        if (takerFilled == type(uint256).max || takerFilled + fill.fillAmount > taker.amount) return "taker_overfill";

        // ── Build context & execute ──
        return _executeSettlement(fill, makerHash, takerHash);
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

        // M-1 v2: Only LIMIT orders supported on-chain
        if (order.orderType != OrderType.LIMIT) return string.concat(prefix, "_unsupported_type");

        // H-3: Sanctioned address check
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

    function _executeSettlement(Fill calldata fill, bytes32 makerHash, bytes32 takerHash) internal returns (string memory) {
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

        // M-4: OI check only for MINT (COMPLEMENTARY doesn't change OI, MERGE decreases it)
        if (fill.matchType == MatchType.MINT) {
            if (market.maxOpenInterest > 0 && market.currentOI + fill.fillAmount > market.maxOpenInterest) {
                return "max_oi_exceeded";
            }
        }

        if (fill.matchType == MatchType.COMPLEMENTARY) {
            return _executeComplementary(fill, ctx);
        } else if (fill.matchType == MatchType.MINT) {
            return _executeMint(fill, ctx);
        } else {
            return _executeMerge(fill, ctx);
        }
    }

    /// @dev COMPLEMENTARY: same-token BUY↔SELL — P2P transferFrom
    function _executeComplementary(Fill calldata fill, FillCtx memory ctx) internal returns (string memory) {
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

        // Non-custodial balance + allowance checks (on-chain)
        uint256 posId = _getPositionId(ctx.conditionId, ctx.outcomeIndex);
        if (usdt.balanceOf(ctx.buyer) < ctx.fillValue) return "buyer_insufficient_balance";
        // M-8 v2: Pre-check allowance to avoid batch-killing revert
        if (usdt.allowance(ctx.buyer, address(this)) < ctx.fillValue) return "buyer_insufficient_allowance";
        if (conditionalTokens.balanceOf(ctx.seller, posId) < fill.fillAmount) {
            return "seller_insufficient_shares";
        }
        if (!conditionalTokens.isApprovedForAll(ctx.seller, address(this))) return "seller_not_approved";

        // ── Execute (CEI) ──
        _applyComplementary(fill, ctx, posId);
        return "";
    }

    /// @dev MINT: cross-outcome BUY+BUY → splitPosition
    function _executeMint(Fill calldata fill, FillCtx memory ctx) internal returns (string memory) {
        uint256 makerCost = (fill.makerOrder.price * fill.fillAmount) / 1e18;
        uint256 takerCost = fill.fillAmount - makerCost + fill.fee;

        if (fill.makerOrder.price + fill.takerOrder.price < 1e18) return "price_sum_below_one";

        // Fee check
        if (fill.fillAmount > 0 && fill.fee * 10_000 > fill.fillAmount * MAX_FEE) return "fee_too_high";

        // Non-custodial balance + allowance checks
        if (usdt.balanceOf(fill.makerOrder.maker) < makerCost) return "maker_insufficient_balance";
        if (usdt.allowance(fill.makerOrder.maker, address(this)) < makerCost) return "maker_insufficient_allowance";
        if (usdt.balanceOf(fill.takerOrder.maker) < takerCost) return "taker_insufficient_balance";
        if (usdt.allowance(fill.takerOrder.maker, address(this)) < takerCost) return "taker_insufficient_allowance";

        _applyMint(fill, ctx, makerCost, takerCost);
        return "";
    }

    /// @dev MERGE: cross-outcome SELL+SELL → mergePositions
    function _executeMerge(Fill calldata fill, FillCtx memory ctx) internal returns (string memory) {
        if (fill.makerOrder.price + fill.takerOrder.price > 1e18) return "price_sum_above_one";

        // Fee check
        if (fill.fillAmount > 0 && fill.fee * 10_000 > fill.fillAmount * MAX_FEE) return "fee_too_high";

        // H-1: Fee underflow guard — check fee doesn't exceed taker proceeds
        uint256 makerPay = (fill.makerOrder.price * fill.fillAmount) / 1e18;
        uint256 takerPay = fill.fillAmount - makerPay;
        if (fill.fee > takerPay) return "fee_exceeds_taker_proceeds";

        // Non-custodial shares checks
        uint256 makerOi = fill.makerOrder.outcomeIndex;
        uint256 takerOi = fill.takerOrder.outcomeIndex;
        uint256 makerPosId = _getPositionId(ctx.conditionId, makerOi);
        uint256 takerPosId = _getPositionId(ctx.conditionId, takerOi);

        if (conditionalTokens.balanceOf(fill.makerOrder.maker, makerPosId) < fill.fillAmount) {
            return "maker_insufficient_shares";
        }
        if (!conditionalTokens.isApprovedForAll(fill.makerOrder.maker, address(this))) return "maker_not_approved";
        if (conditionalTokens.balanceOf(fill.takerOrder.maker, takerPosId) < fill.fillAmount) {
            return "taker_insufficient_shares";
        }
        if (!conditionalTokens.isApprovedForAll(fill.takerOrder.maker, address(this))) return "taker_not_approved";

        _applyMerge(fill, ctx, makerPosId, takerPosId, makerPay);
        return "";
    }

    /// @dev COMPLEMENTARY settlement: P2P transferFrom (Polymarket-style)
    function _applyComplementary(Fill calldata fill, FillCtx memory ctx, uint256 posId) internal {
        // ── 1. Filled tracking (M-1: by orderHash) ──
        filled[ctx.makerHash] += fill.fillAmount;
        filled[ctx.takerHash] += fill.fillAmount;

        // ── 2. M-4: COMPLEMENTARY = volume only, no OI change ──
        marketRegistry.addVolume(ctx.marketId, ctx.fillValue);

        // ── 3. Dust Kill (M-1: by orderHash) ──
        _dustKill(ctx.makerHash, fill.makerOrder.amount);
        _dustKill(ctx.takerHash, fill.takerOrder.amount);

        // ── 4. ERC1155 shares: seller → buyer (via transferFrom) ──
        conditionalTokens.safeTransferFrom(ctx.seller, ctx.buyer, posId, fill.fillAmount, "");

        // ── 5. USDT: buyer → seller (minus fee), fee via _collectFee (M-3 v2) ──
        uint256 sellerProceeds = ctx.fillValue;
        if (fill.fee > 0) {
            sellerProceeds -= fill.fee;
            // M-3 v2: Pull fee to Exchange, then use _collectFee (consistent with MINT/MERGE)
            usdt.safeTransferFrom(ctx.buyer, address(this), fill.fee);
            _collectFee(fill.fee);
        }
        if (sellerProceeds > 0) {
            usdt.safeTransferFrom(ctx.buyer, ctx.seller, sellerProceeds);
        }

        // L-7: matchType in event
        emit FillExecuted(
            ctx.marketId, fill.makerOrder.maker, fill.takerOrder.maker,
            ctx.executionPrice, fill.fillAmount, fill.fee, fill.makerOrder.side,
            MatchType.COMPLEMENTARY
        );
    }

    /// @dev MINT settlement: BUY+BUY → splitPosition (transient custody)
    function _applyMint(
        Fill calldata fill, FillCtx memory ctx,
        uint256 makerCost, uint256 takerCost
    ) internal {
        uint256 amt = fill.fillAmount;
        address makerAddr = fill.makerOrder.maker;
        address takerAddr = fill.takerOrder.maker;

        // ── 1. Filled tracking (M-1: by orderHash) ──
        filled[ctx.makerHash] += amt;
        filled[ctx.takerHash] += amt;

        // ── 2. M-4: MINT = volume + OI increase (correct) ──
        marketRegistry.addVolumeAndOI(ctx.marketId, amt, amt);

        // ── 3. Dust Kill (M-1: by orderHash) ──
        _dustKill(ctx.makerHash, fill.makerOrder.amount);
        _dustKill(ctx.takerHash, fill.takerOrder.amount);

        // ── 4. Pull USDT from both buyers into Exchange (transient) ──
        usdt.safeTransferFrom(makerAddr, address(this), makerCost);
        usdt.safeTransferFrom(takerAddr, address(this), takerCost);

        // ── 5. Split + distribute shares ──
        _splitAndDistribute(fill, ctx, makerAddr, takerAddr, amt);

        // ── 6. Fee + surplus ──
        _handleMintSurplus(fill.fee, makerCost + takerCost, amt);

        // L-7: matchType in event
        emit FillExecuted(
            ctx.marketId, makerAddr, takerAddr,
            ctx.executionPrice, amt, fill.fee, fill.makerOrder.side,
            MatchType.MINT
        );
    }

    function _splitAndDistribute(
        Fill calldata fill, FillCtx memory ctx,
        address makerAddr, address takerAddr, uint256 amt
    ) internal {
        // L-9: forceApprove for token compatibility
        usdt.forceApprove(address(conditionalTokens), amt);
        conditionalTokens.splitPosition(ctx.conditionId, amt);

        uint256 makerPosId = _getPositionId(ctx.conditionId, fill.makerOrder.outcomeIndex);
        uint256 takerPosId = _getPositionId(ctx.conditionId, fill.takerOrder.outcomeIndex);
        conditionalTokens.safeTransferFrom(address(this), makerAddr, makerPosId, amt, "");
        conditionalTokens.safeTransferFrom(address(this), takerAddr, takerPosId, amt, "");
    }

    // H-2: Separated fee and surplus handling
    function _handleMintSurplus(uint256 fee, uint256 totalPaid, uint256 collateral) internal {
        if (fee > 0) {
            _collectFee(fee);
        }
        // Surplus = totalPaid - collateral - fee (anything beyond collateral and fee)
        if (totalPaid > collateral + fee) {
            usdt.safeTransfer(treasury, totalPaid - collateral - fee);
        }
    }

    /// @dev MERGE settlement: SELL+SELL → mergePositions (transient custody)
    function _applyMerge(
        Fill calldata fill, FillCtx memory ctx,
        uint256 makerPosId, uint256 takerPosId, uint256 makerPay
    ) internal {
        uint256 amt = fill.fillAmount;
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
        conditionalTokens.safeTransferFrom(makerAddr, address(this), makerPosId, amt, "");
        conditionalTokens.safeTransferFrom(takerAddr, address(this), takerPosId, amt, "");

        // ── 5. Merge: burn YES+NO shares → get USDT back ──
        conditionalTokens.mergePositions(ctx.conditionId, amt);

        // ── 6. Distribute USDT + fee ──
        _distributeMergeProceeds(fill, makerAddr, takerAddr, makerPay, amt);

        // L-7: matchType in event
        emit FillExecuted(
            ctx.marketId, makerAddr, takerAddr,
            ctx.executionPrice, amt, fill.fee, fill.makerOrder.side,
            MatchType.MERGE
        );
    }

    function _distributeMergeProceeds(
        Fill calldata fill, address makerAddr, address takerAddr,
        uint256 makerPay, uint256 amt
    ) internal {
        uint256 takerPay = amt - makerPay;

        if (fill.fee > 0) {
            _collectFee(fill.fee);
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

    // ─── Reject BNB ───
    fallback() external payable { revert(); }
    receive() external payable { revert(); }

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

    function _getPositionId(bytes32 conditionId, uint256 outcomeIndex) internal view returns (uint256) {
        uint256 indexSet = 1 << outcomeIndex;
        bytes32 collectionId = conditionalTokens.getCollectionId(conditionId, indexSet);
        return conditionalTokens.getPositionId(address(usdt), collectionId);
    }

    // ─── ERC1155 Receiver (needed for transient MINT/MERGE custody) ───
    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControl, ERC1155Holder) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
