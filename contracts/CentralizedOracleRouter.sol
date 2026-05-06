// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IOracleRouter.sol";
import "./MarketRegistry.sol";
import "./Roles.sol";

/// @title CentralizedOracleRouter — Oracle resolution with on-chain dispute window
/// @notice Phase 1: centralized proposer + permissionless dispute + council resolution.
///         Implements IOracleRouter so it can be swapped for UMA/Chainlink adapter later.
/// @dev MarketRegistry delegates resolution to this contract via oracleRouter address.
contract CentralizedOracleRouter is
    IOracleRouter,
    Initializable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ─── Errors ───
    error ProposalAlreadyExists(uint256 marketId);
    error ProposalNotFound(uint256 marketId);
    error ProposalNotProposed(uint256 marketId);
    error ProposalNotDisputed(uint256 marketId);
    error DisputeWindowNotExpired(uint256 marketId, uint256 deadline);
    error DisputeWindowExpired(uint256 marketId);
    error InvalidOutcome(uint256 outcomeIndex);
    error ZeroAddress();

    // ─── Events (implementation-specific, beyond IOracleRouter) ───
    event EmergencyRejected(uint256 indexed marketId, address indexed rejectedBy);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event BondCredited(uint256 indexed marketId, address indexed recipient, uint256 amount);
    event BondWithdrawn(address indexed recipient, uint256 amount);

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
    MarketRegistry public marketRegistry; // was immutable
    IERC20 public bondToken;              // was immutable
    address public treasury;

    mapping(uint256 => Proposal) private _proposals;
    mapping(address => uint256) public pendingBondWithdrawals;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _marketRegistry,
        address _bondToken,
        address _treasury
    ) external initializer {
        if (_marketRegistry == address(0) || _bondToken == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }

        __AccessControlEnumerable_init();
        _reentrancyStatus = _NOT_ENTERED;

        marketRegistry = MarketRegistry(_marketRegistry);
        bondToken = IERC20(_bondToken);
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ─── UUPS Authorization ───
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════════════════════════════════════════════════════
    // IOracleRouter IMPLEMENTATION
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IOracleRouter
    function proposeOutcome(
        uint256 marketId,
        uint256 outcomeIndex
    ) external onlyRole(Roles.PROPOSER_ROLE) {
        _proposeOutcome(marketId, outcomeIndex);
    }

    /// @notice Batch propose outcomes for multiple markets in a single transaction.
    /// @param marketIds Array of market IDs to propose.
    /// @param outcomeIndices Array of outcome indices (must match marketIds length).
    function proposeOutcomeBatch(
        uint256[] calldata marketIds,
        uint256[] calldata outcomeIndices
    ) external onlyRole(Roles.PROPOSER_ROLE) {
        require(marketIds.length == outcomeIndices.length, "Array length mismatch");
        require(marketIds.length > 0, "Empty batch");

        for (uint256 i = 0; i < marketIds.length;) {
            _proposeOutcome(marketIds[i], outcomeIndices[i]);
            unchecked { i++; }
        }
    }

    /// @dev Internal propose logic shared by proposeOutcome and proposeOutcomeBatch.
    function _proposeOutcome(uint256 marketId, uint256 outcomeIndex) internal {
        if (outcomeIndex > 1) revert InvalidOutcome(outcomeIndex);

        MarketRegistry.Market memory m = marketRegistry.getMarket(marketId);
        require(
            (m.tradingCutoff > 0 && block.timestamp >= m.tradingCutoff) || block.timestamp >= m.endTime,
            "Market not yet ended or cutoff not reached"
        );

        Proposal storage p = _proposals[marketId];
        if (p.status == ProposalStatus.PROPOSED || p.status == ProposalStatus.DISPUTED || p.status == ProposalStatus.FINALIZED) {
            revert ProposalAlreadyExists(marketId);
        }

        (bool disputeEnabled, uint256 disputeWindow,) = marketRegistry.getDisputeConfig(marketId);

        marketRegistry.setResolved(marketId);

        if (!disputeEnabled || disputeWindow == 0) {
            marketRegistry.finalizeResolution(marketId, outcomeIndex);

            _proposals[marketId] = Proposal({
                outcomeIndex: outcomeIndex,
                proposer: msg.sender,
                proposedAt: block.timestamp,
                disputeDeadline: block.timestamp,
                status: ProposalStatus.FINALIZED,
                disputer: address(0),
                disputeBond: 0
            });

            emit OutcomeProposed(marketId, outcomeIndex, msg.sender, block.timestamp);
            emit OutcomeFinalized(marketId, outcomeIndex);
        } else {
            uint256 deadline = block.timestamp + disputeWindow;

            _proposals[marketId] = Proposal({
                outcomeIndex: outcomeIndex,
                proposer: msg.sender,
                proposedAt: block.timestamp,
                disputeDeadline: deadline,
                status: ProposalStatus.PROPOSED,
                disputer: address(0),
                disputeBond: 0
            });

            emit OutcomeProposed(marketId, outcomeIndex, msg.sender, deadline);
        }
    }

    /// @inheritdoc IOracleRouter
    function disputeOutcome(uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[marketId];
        if (p.status != ProposalStatus.PROPOSED) revert ProposalNotProposed(marketId);
        if (block.timestamp >= p.disputeDeadline) revert DisputeWindowExpired(marketId);

        MarketRegistry.Market memory m = marketRegistry.getMarket(marketId);
        require(!m.finalized, "Market already finalized");

        // Get bond amount from market's profile
        (,, uint256 bondAmount) = marketRegistry.getDisputeConfig(marketId);

        // CEI: update state before external call
        p.status = ProposalStatus.DISPUTED;
        p.disputer = msg.sender;
        p.disputeBond = bondAmount;

        // Pull bond from disputer
        if (bondAmount > 0) {
            bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        }

        // Freeze market for additional safety during dispute
        marketRegistry.freezeMarket(marketId);

        emit OutcomeDisputed(marketId, msg.sender, bondAmount);
    }

    /// @inheritdoc IOracleRouter
    function finalizeOutcome(uint256 marketId) external {
        Proposal storage p = _proposals[marketId];
        if (p.status != ProposalStatus.PROPOSED) revert ProposalNotProposed(marketId);
        if (block.timestamp < p.disputeDeadline) revert DisputeWindowNotExpired(marketId, p.disputeDeadline);

        p.status = ProposalStatus.FINALIZED;

        marketRegistry.finalizeResolution(marketId, p.outcomeIndex);

        emit OutcomeFinalized(marketId, p.outcomeIndex);
    }

    /// @inheritdoc IOracleRouter
    function getProposal(uint256 marketId) external view returns (Proposal memory) {
        return _proposals[marketId];
    }

    // ═══════════════════════════════════════════════════════
    // EARLY RESOLVE — PROPOSER_ROLE without time gate
    // ═══════════════════════════════════════════════════════

    /// @notice Propose outcome without tradingCutoff/endTime gate.
    /// @dev For esports and other markets where the result is known before endTime.
    ///      Respects disputeWindow (disputeWindow=0 → immediate finalize).
    ///      Same access control as proposeOutcome (PROPOSER_ROLE).
    function earlyResolve(
        uint256 marketId,
        uint256 outcomeIndex
    ) external onlyRole(Roles.PROPOSER_ROLE) {
        _earlyResolve(marketId, outcomeIndex);
    }

    /// @notice Batch early resolve for multiple markets in a single transaction.
    function earlyResolveBatch(
        uint256[] calldata marketIds,
        uint256[] calldata outcomeIndices
    ) external onlyRole(Roles.PROPOSER_ROLE) {
        require(marketIds.length == outcomeIndices.length, "Array length mismatch");
        require(marketIds.length > 0, "Empty batch");

        for (uint256 i = 0; i < marketIds.length;) {
            _earlyResolve(marketIds[i], outcomeIndices[i]);
            unchecked { i++; }
        }
    }

    /// @dev Internal early resolve logic — same as _proposeOutcome but without time check.
    function _earlyResolve(uint256 marketId, uint256 outcomeIndex) internal {
        if (outcomeIndex > 1) revert InvalidOutcome(outcomeIndex);

        Proposal storage p = _proposals[marketId];
        if (p.status == ProposalStatus.PROPOSED || p.status == ProposalStatus.DISPUTED || p.status == ProposalStatus.FINALIZED) {
            revert ProposalAlreadyExists(marketId);
        }

        (bool disputeEnabled, uint256 disputeWindow,) = marketRegistry.getDisputeConfig(marketId);

        marketRegistry.setResolved(marketId);

        if (!disputeEnabled || disputeWindow == 0) {
            marketRegistry.finalizeResolution(marketId, outcomeIndex);

            _proposals[marketId] = Proposal({
                outcomeIndex: outcomeIndex,
                proposer: msg.sender,
                proposedAt: block.timestamp,
                disputeDeadline: block.timestamp,
                status: ProposalStatus.FINALIZED,
                disputer: address(0),
                disputeBond: 0
            });

            emit OutcomeProposed(marketId, outcomeIndex, msg.sender, block.timestamp);
            emit OutcomeFinalized(marketId, outcomeIndex);
        } else {
            uint256 deadline = block.timestamp + disputeWindow;

            _proposals[marketId] = Proposal({
                outcomeIndex: outcomeIndex,
                proposer: msg.sender,
                proposedAt: block.timestamp,
                disputeDeadline: deadline,
                status: ProposalStatus.PROPOSED,
                disputer: address(0),
                disputeBond: 0
            });

            emit OutcomeProposed(marketId, outcomeIndex, msg.sender, deadline);
        }
    }

    // ═══════════════════════════════════════════════════════
    // COUNCIL FUNCTIONS (Implementation-specific)
    // ═══════════════════════════════════════════════════════

    /// @notice Council resolves a disputed proposal.
    /// @param marketId The disputed market.
    /// @param outcomeIndex The final outcome determined by the council.
    /// @dev If council agrees with original proposal, disputer loses bond.
    ///      If council disagrees, disputer gets bond back.
    function councilResolve(
        uint256 marketId,
        uint256 outcomeIndex
    ) external onlyRole(Roles.COUNCIL_ROLE) nonReentrant {
        if (outcomeIndex > 1) revert InvalidOutcome(outcomeIndex);

        Proposal storage p = _proposals[marketId];
        if (p.status != ProposalStatus.DISPUTED) revert ProposalNotDisputed(marketId);

        uint256 originalOutcome = p.outcomeIndex;
        p.outcomeIndex = outcomeIndex;
        p.status = ProposalStatus.FINALIZED;

        // Bond disposition — pull-based to prevent DoS
        if (p.disputeBond > 0) {
            if (outcomeIndex == originalOutcome) {
                pendingBondWithdrawals[treasury] += p.disputeBond;
                emit BondCredited(marketId, treasury, p.disputeBond);
            } else {
                pendingBondWithdrawals[p.disputer] += p.disputeBond;
                emit BondCredited(marketId, p.disputer, p.disputeBond);
            }
        }

        // Unfreeze then finalize
        // Use try/catch for unfreeze since market may not be frozen
        // (e.g., safety council already unfroze it)
        try marketRegistry.unfreezeMarket(marketId) {} catch {}

        marketRegistry.finalizeResolution(marketId, outcomeIndex);

        emit DisputeResolved(marketId, outcomeIndex, msg.sender);
    }

    /// @notice Council rejects the proposal entirely. Market returns to unresolved.
    /// @dev Allows a new proposal to be submitted. Bond is returned to disputer.
    function emergencyReject(uint256 marketId) external onlyRole(Roles.COUNCIL_ROLE) nonReentrant {
        _emergencyReject(marketId, 0, false);
    }

    /// @notice Council rejects the proposal and resets tradingCutoff so the market can resume trading.
    function emergencyRejectAndResetCutoff(
        uint256 marketId,
        uint256 newCutoff
    ) external onlyRole(Roles.COUNCIL_ROLE) nonReentrant {
        _emergencyReject(marketId, newCutoff, true);
    }

    function _emergencyReject(uint256 marketId, uint256 newCutoff, bool resetCutoff) internal {
        Proposal storage p = _proposals[marketId];
        if (p.status != ProposalStatus.PROPOSED && p.status != ProposalStatus.DISPUTED) {
            revert ProposalNotFound(marketId);
        }

        // Return bond to disputer if disputed — pull-based
        if (p.status == ProposalStatus.DISPUTED && p.disputeBond > 0) {
            pendingBondWithdrawals[p.disputer] += p.disputeBond;
            emit BondCredited(marketId, p.disputer, p.disputeBond);
        }

        p.status = ProposalStatus.REJECTED;

        // Roll back resolved state so market can resume trading
        marketRegistry.unresolve(marketId);
        if (resetCutoff) {
            marketRegistry.resetTradingCutoff(marketId, newCutoff);
        }

        // Unfreeze if frozen
        try marketRegistry.unfreezeMarket(marketId) {} catch {}

        emit EmergencyRejected(marketId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // H-3 v2: EMERGENCY RESOLVE (replaces MarketRegistry.overrideOutcome)
    // ═══════════════════════════════════════════════════════

    /// @notice Safety Council emergency resolution — bypasses time checks.
    /// @dev Replaces MarketRegistry.overrideOutcome. Goes through OracleRouter flow,
    ///      handles active dispute bonds (returns to disputer), and finalizes.
    ///      No time restriction (SAFETY_COUNCIL can resolve at any time).
    function emergencyResolve(
        uint256 marketId,
        uint256 outcomeIndex
    ) external onlyRole(Roles.SAFETY_COUNCIL_ROLE) nonReentrant {
        _emergencyResolve(marketId, outcomeIndex);
    }

    /// @notice Batch emergency resolution for multiple markets in a single transaction.
    function emergencyResolveBatch(
        uint256[] calldata marketIds,
        uint256[] calldata outcomeIndices
    ) external onlyRole(Roles.SAFETY_COUNCIL_ROLE) nonReentrant {
        require(marketIds.length == outcomeIndices.length, "Array length mismatch");
        require(marketIds.length > 0, "Empty batch");

        for (uint256 i = 0; i < marketIds.length;) {
            _emergencyResolve(marketIds[i], outcomeIndices[i]);
            unchecked { i++; }
        }
    }

    /// @dev Internal emergency resolve logic shared by single and batch variants.
    function _emergencyResolve(uint256 marketId, uint256 outcomeIndex) internal {
        if (outcomeIndex > 1) revert InvalidOutcome(outcomeIndex);

        Proposal storage p = _proposals[marketId];

        // Cannot re-resolve already finalized
        if (p.status == ProposalStatus.FINALIZED) {
            revert ProposalAlreadyExists(marketId);
        }

        // If there's an active dispute, return the bond to disputer — pull-based
        if (p.status == ProposalStatus.DISPUTED && p.disputeBond > 0) {
            pendingBondWithdrawals[p.disputer] += p.disputeBond;
            emit BondCredited(marketId, p.disputer, p.disputeBond);
        }

        p.status = ProposalStatus.FINALIZED;
        p.outcomeIndex = outcomeIndex;

        // Set resolved if not already
        MarketRegistry.Market memory m = marketRegistry.getMarket(marketId);
        if (!m.resolved) {
            marketRegistry.setResolved(marketId);
        }

        // Unfreeze if frozen
        try marketRegistry.unfreezeMarket(marketId) {} catch {}

        // Finalize
        marketRegistry.finalizeResolution(marketId, outcomeIndex);

        emit OutcomeFinalized(marketId, outcomeIndex);
    }

    /// @notice Rescue bond from an orphaned proposal (e.g., market was expired externally).
    /// @dev Returns bond to disputer if proposal is stuck in DISPUTED state but market is already finalized.
    function rescueBond(uint256 marketId) external onlyRole(Roles.COUNCIL_ROLE) nonReentrant {
        Proposal storage p = _proposals[marketId];
        if (p.status != ProposalStatus.DISPUTED) revert ProposalNotDisputed(marketId);

        // Only rescue if market is already finalized (orphaned proposal)
        MarketRegistry.Market memory m = marketRegistry.getMarket(marketId);
        require(m.finalized, "Market not finalized");

        if (p.disputeBond > 0) {
            pendingBondWithdrawals[p.disputer] += p.disputeBond;
            emit BondCredited(marketId, p.disputer, p.disputeBond);
        }
        p.status = ProposalStatus.FINALIZED;

        emit DisputeResolved(marketId, p.outcomeIndex, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // BOND WITHDRAWAL
    // ═══════════════════════════════════════════════════════

    /// @notice Withdraw credited dispute bonds (pull-based pattern to prevent DoS).
    function withdrawBond() external nonReentrant {
        uint256 amount = pendingBondWithdrawals[msg.sender];
        require(amount > 0, "No bond to withdraw");
        pendingBondWithdrawals[msg.sender] = 0;
        bondToken.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    // ─── Storage Gap ───
    uint256[47] private __gap;
}
