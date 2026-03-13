// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConditionalTokens — ERC1155 outcome tokens for prediction markets
/// @notice v1: outcomeSlotCount == 2 only. Gnosis CTF-style.
contract ConditionalTokens is ERC1155, ReentrancyGuard {
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
    uint256 public constant MIN_REDEEM = 0.1e18; // 0.1 USDT

    // ─── State ───
    IERC20 public immutable collateralToken; // USDT
    address public treasury;

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

    constructor(address _collateralToken, address _treasury) ERC1155("") {
        // L-3: Zero-address checks
        require(_collateralToken != address(0), "Zero collateralToken");
        require(_treasury != address(0), "Zero treasury");
        collateralToken = IERC20(_collateralToken);
        treasury = _treasury;
    }

    // ─── L-4: Treasury setter ───

    function setTreasury(address _treasury) external {
        require(msg.sender == treasury, "Only treasury");
        require(_treasury != address(0), "Zero address");
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    // ─── Condition Management ───

    function prepareCondition(
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount
    ) external returns (bytes32) {
        if (oracle == address(0)) revert InvalidOracleAddress();
        if (outcomeSlotCount != 2) revert InvalidOutcomeSlotCount(outcomeSlotCount);

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
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (conditionOutcomeSlotCounts[conditionId] == 0) revert ConditionNotFound(conditionId);

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

            _mint(msg.sender, posId, amount, "");
            unchecked { i++; }
        }

        emit PositionSplit(msg.sender, conditionId, amount);
    }

    function mergePositions(
        bytes32 conditionId,
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (conditionOutcomeSlotCounts[conditionId] == 0) revert ConditionNotFound(conditionId);

        uint256 outcomeSlotCount = conditionOutcomeSlotCounts[conditionId];
        for (uint256 i = 0; i < outcomeSlotCount;) {
            uint256 indexSet = 1 << i;
            uint256 posId = getPositionId(address(collateralToken), getCollectionId(conditionId, indexSet));
            _burn(msg.sender, posId, amount);
            unchecked { i++; }
        }

        // C-1: Decrement collateral tracking
        conditionCollateral[conditionId] -= amount;

        collateralToken.safeTransfer(msg.sender, amount);

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
    ) external {
        require(msg.sender == treasury, "Only treasury");
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
                _totalSupply[ids[i]] += values[i];
            }
            if (to == address(0)) {
                _totalSupply[ids[i]] -= values[i];
            }
            unchecked { i++; }
        }
    }
}
