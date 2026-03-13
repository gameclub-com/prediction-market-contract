// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title MockSimpleAA — Simple AA wallet that validates signatures (~30k gas)
/// @dev For testing normal AA signature verification within SIG_VERIFY_GAS_LIMIT
contract MockSimpleAA {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return 0x1626ba7e; // IERC1271.isValidSignature.selector
        }
        return 0xffffffff;
    }
}
