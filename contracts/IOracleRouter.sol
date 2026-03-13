// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IOracleRouter — Interface for oracle resolution with dispute support
/// @notice Defines the universal oracle router interface. Any implementation
///         (centralized, UMA, Chainlink) must satisfy this interface.
/// @dev MarketRegistry delegates resolution to an IOracleRouter implementation.
interface IOracleRouter {
    // ─── Enums ───
    enum ProposalStatus { NONE, PROPOSED, DISPUTED, FINALIZED, REJECTED }

    // ─── Structs ───
    struct Proposal {
        uint256 outcomeIndex;
        address proposer;
        uint256 proposedAt;
        uint256 disputeDeadline;
        ProposalStatus status;
        address disputer;
        uint256 disputeBond;
    }

    // ─── Events ───
    event OutcomeProposed(
        uint256 indexed marketId,
        uint256 outcomeIndex,
        address indexed proposer,
        uint256 disputeDeadline
    );
    event OutcomeDisputed(
        uint256 indexed marketId,
        address indexed disputer,
        uint256 bond
    );
    event OutcomeFinalized(
        uint256 indexed marketId,
        uint256 outcomeIndex
    );
    event DisputeResolved(
        uint256 indexed marketId,
        uint256 outcomeIndex,
        address indexed resolvedBy
    );

    // ─── Functions ───

    /// @notice Propose an outcome for a market. Starts the dispute window.
    /// @param marketId The market to resolve.
    /// @param outcomeIndex The proposed winning outcome (0 or 1 for binary).
    function proposeOutcome(uint256 marketId, uint256 outcomeIndex) external;

    /// @notice Dispute a proposed outcome by depositing a bond.
    /// @param marketId The market whose proposal to dispute.
    function disputeOutcome(uint256 marketId) external;

    /// @notice Finalize an undisputed proposal after the dispute window expires.
    /// @param marketId The market to finalize.
    function finalizeOutcome(uint256 marketId) external;

    /// @notice Get the current proposal for a market.
    /// @param marketId The market to query.
    /// @return proposal The proposal state.
    function getProposal(uint256 marketId) external view returns (Proposal memory proposal);
}
