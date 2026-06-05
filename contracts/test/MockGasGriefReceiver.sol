// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockGasGriefReceiver — QGM-52 (follow-up) regression mock.
/// @notice A contract-wallet "receiver" whose ERC-165 `supportsInterface()` is hostile to the
///         relayer in two ways CertiK called out in the 06/04 review:
///           mode 1 — returns an OVERSIZED payload (2048 bytes) whose first word looks canonical.
///                    The hardened probe requires `returndatasize() == 32`, so this is rejected
///                    (false) rather than mis-read as a valid receiver.
///           mode 2 — a GAS BOMB: spins burning gas until it runs out. With the probe's gas cap
///                    (RECEIVER_PROBE_GAS) the sub-call OOGs and returns false; the relayer loses
///                    only the capped gas and the surrounding settleBatch is NOT aborted.
/// @dev Pre-fix, `_canReceiveERC1155()` used a high-level `staticcall` (uncapped gas, full
///      return-data copy), so mode 2 could grief relayer gas and mode 1's oversized payload was
///      copied wholesale into memory. The bounded-assembly probe treats both as `false` without
///      reverting, so on the complementary path only the offending fill is skipped ("bri").
contract MockGasGriefReceiver {
    IERC20 public immutable usdt;
    address public immutable exchange;
    uint256 public mode; // 0 = canonical true, 1 = oversized payload, 2 = gas bomb

    // usdt/exchange let the test fund this contract buyer and approve the exchange, so the
    // complementary settlement passes the buyer balance/allowance pre-checks ("bib"/"bia") and
    // actually REACHES the receiver probe — otherwise the fill would skip before the probe and
    // the test would pass for the wrong reason.
    constructor(address _usdt, address _exchange) {
        usdt = IERC20(_usdt);
        exchange = _exchange;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    /// @notice Approve the exchange to pull this wallet's USDT (set up before settlement).
    function approveUsdt(uint256 amount) external {
        usdt.approve(exchange, amount);
    }

    // Accept any signature so this wallet's maker order validates via EIP-1271.
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e; // IERC1271.isValidSignature.selector
    }

    function supportsInterface(bytes4) external view returns (bool) {
        uint256 m = mode;
        if (m == 1) {
            // Oversized but "canonical-looking" return: first word == 1, total size 2048 bytes.
            assembly {
                mstore(0x00, 1)
                return(0x00, 0x800)
            }
        }
        if (m == 2) {
            // Gas bomb: burn gas via keccak (SSTORE is illegal under staticcall). Under the
            // probe's gas cap this hits out-of-gas and the staticcall returns success=false.
            uint256 x = 7;
            for (uint256 i = 0; i < 1_000_000; i++) {
                x = uint256(keccak256(abi.encode(x, i)));
            }
            return x != 0; // unreachable under the cap
        }
        return true; // canonical
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
