// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IOracleRouter.sol";
import "./MarketRegistry.sol";
import "./Roles.sol";

/// @title CentralizedOracleRouter — Oracle resolution with on-chain dispute window
/// @notice Phase 1: centralized proposer + permissionless dispute + council resolution.
///         Implements IOracleRouter so it can be swapped for UMA/Chainlink adapter later.
/// @dev MarketRegistry delegates resolution to this contract via oracleRouter address.
contract CentralizedOracleRouter is IOracleRouter, AccessControl, ReentrancyGuard {
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

    // ─── State ───
    MarketRegistry public immutable marketRegistry;
    IERC20 public immutable bondToken;
    address public treasury;

    mapping(uint256 => Proposal) private _proposals;

    // ─── Constructor ───
    constructor(
        address _marketRegistry,
        address _bondToken,
        address _treasury
    ) {
        if (_marketRegistry == address(0) || _bondToken == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        marketRegistry = MarketRegistry(_marketRegistry);
        bondToken = IERC20(_bondToken);
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    // IOracleRouter IMPLEMENTATION
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IOracleRouter
    function proposeOutcome(
        uint256 marketId,
        uint256 outcomeIndex
    ) external onlyRole(Roles.PROPOSER_ROLE) {
        if (outcomeIndex > 1) revert InvalidOutcome(outcomeIndex);

        // H-2 v2: PROPOSER must wait until tradingCutoff or endTime has passed
        MarketRegistry.Market memory m = marketRegistry.getMarket(marketId);
        require(
            block.timestamp >= m.tradingCutoff || block.timestamp >= m.endTime,
            "Market not yet ended"
        );

        Proposal storage p = _proposals[marketId];
        // Allow re-proposal only if NONE or REJECTED
        if (p.status == ProposalStatus.PROPOSED || p.status == ProposalStatus.DISPUTED || p.status == ProposalStatus.FINALIZED) {
            revert ProposalAlreadyExists(marketId);
        }

        // Get dispute config from market's profile
        (bool disputeEnabled, uint256 disputeWindow,) = marketRegistry.getDisputeConfig(marketId);

        // Mark market as resolved (stops trading via ExchangeCLOB._checkMarket)
        marketRegistry.setResolved(marketId);

        if (!disputeEnabled || disputeWindow == 0) {
            // No dispute window — finalize immediately
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
            // Start dispute window
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

        p.status = ProposalStatus.FINALIZED;

        // Bond disposition
        if (p.disputeBond > 0) {
            if (outcomeIndex == p.outcomeIndex) {
                // Original proposal confirmed — disputer loses bond
                bondToken.safeTransfer(treasury, p.disputeBond);
            } else {
                // Original proposal overturned — disputer gets bond back
                bondToken.safeTransfer(p.disputer, p.disputeBond);
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
        Proposal storage p = _proposals[marketId];
        if (p.status != ProposalStatus.PROPOSED && p.status != ProposalStatus.DISPUTED) {
            revert ProposalNotFound(marketId);
        }

        // Return bond to disputer if disputed
        if (p.status == ProposalStatus.DISPUTED && p.disputeBond > 0) {
            bondToken.safeTransfer(p.disputer, p.disputeBond);
        }

        p.status = ProposalStatus.REJECTED;

        // Roll back resolved state so market can resume trading
        marketRegistry.unresolve(marketId);

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
        if (outcomeIndex > 1) revert InvalidOutcome(outcomeIndex);

        Proposal storage p = _proposals[marketId];

        // Cannot re-resolve already finalized
        if (p.status == ProposalStatus.FINALIZED) {
            revert ProposalAlreadyExists(marketId);
        }

        // If there's an active dispute, return the bond to disputer
        if (p.status == ProposalStatus.DISPUTED && p.disputeBond > 0) {
            bondToken.safeTransfer(p.disputer, p.disputeBond);
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
            bondToken.safeTransfer(p.disputer, p.disputeBond);
        }
        p.status = ProposalStatus.FINALIZED;

        emit DisputeResolved(marketId, p.outcomeIndex, msg.sender);
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
}
