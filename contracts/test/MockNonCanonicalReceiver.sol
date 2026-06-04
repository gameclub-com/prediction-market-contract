// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockNonCanonicalReceiver — QGM-52 regression mock.
/// @notice A contract whose `supportsInterface()` returns a NON-CANONICAL boolean payload —
///         the 32-byte word `2`, which is neither 0 nor 1.
/// @dev Pre-fix, `ExchangeCLOB._canReceiveERC1155()` did `abi.decode(result, (bool))`, which
///      raises Panic(0x21) on a non-canonical bool and — in the complementary path that treats
///      the probe as a soft "bri" skip — reverted the ENTIRE settleBatch. Post-fix the probe
///      decodes as `uint256` and accepts only the canonical `1`, so this contract is treated as
///      an incompatible receiver ("bri") and only its own fill is skipped; the batch survives.
contract MockNonCanonicalReceiver {
    // Accept any signature so this wallet's maker order validates via EIP-1271.
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e; // IERC1271.isValidSignature.selector
    }

    // ERC-165 probe: return a non-canonical 32-byte word (value 2) for ANY interfaceId.
    function supportsInterface(bytes4) external pure returns (bool) {
        assembly {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }

    function onERC1155Received(
        address, address, uint256, uint256, bytes calldata
    ) external pure returns (bytes4) {
        return 0xf23a6e61; // IERC1155Receiver.onERC1155Received.selector
    }

    function onERC1155BatchReceived(
        address, address, uint256[] calldata, uint256[] calldata, bytes calldata
    ) external pure returns (bytes4) {
        return 0xbc197c81; // IERC1155Receiver.onERC1155BatchReceived.selector
    }
}
