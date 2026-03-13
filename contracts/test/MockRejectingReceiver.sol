// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockRejectingReceiver — Contract that rejects ERC20 transfers
/// @dev For testing safe fee transfer (unclaimedFees accumulation)
contract MockRejectingReceiver {
    // Reject all token transfers by not implementing any receive logic
    // When used as feeCollector, the transfer will fail

    fallback() external payable {
        revert("Rejected");
    }

    receive() external payable {
        revert("Rejected");
    }
}
