// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockMaliciousAA — Malicious AA wallet that consumes all gas during sig verification
/// @dev For testing SIG_VERIFY_GAS_LIMIT protection
contract MockMaliciousAA {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        // Infinite loop to consume all gas
        while (true) {}
        return 0x1626ba7e;
    }
}
