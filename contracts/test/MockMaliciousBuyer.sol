// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockMaliciousBuyer — QGM-46 regression mock.
/// @notice A contract wallet that passes BOTH the EIP-1271 signature check and the
///         ERC-165 ERC1155-receiver check, yet attacks the complementary settlement
///         payment path from inside its onERC1155Received hook.
/// @dev Modes:
///      0 NORMAL — accept the ERC1155 share, do nothing (baseline happy path).
///      1 REVOKE — on receiving the share, revoke the contract's USDT allowance to the
///                 exchange. This is the QGM-46 TOCTOU attack: under the old (QGM-30)
///                 ordering the LATER usdt.safeTransferFrom would then revert and abort
///                 the whole batch. With the escrow-first fix the payment is already
///                 pulled before delivery, so this revoke is a no-op and the fill settles.
///      2 REVERT — reject the ERC1155 receipt by reverting in the hook. Exercises the
///                 QGM-30 "rcr" soft-fail path; with escrow-first the escrow is refunded.
contract MockMaliciousBuyer {
    IERC20 public immutable usdt;
    address public immutable exchange;
    uint8 public mode; // 0 NORMAL, 1 REVOKE, 2 REVERT

    constructor(address _usdt, address _exchange) {
        usdt = IERC20(_usdt);
        exchange = _exchange;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    /// @notice Approve the exchange to pull this wallet's USDT (set up before settlement).
    function approveUsdt(uint256 amount) external {
        usdt.approve(exchange, amount);
    }

    // ── EIP-1271: accept any signature so this wallet's order validates. ──
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e; // IERC1271.isValidSignature.selector
    }

    // ── ERC-165: advertise IERC1155Receiver support so _canReceiveERC1155 passes ("bri"). ──
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x4e2312e0 // type(IERC1155Receiver).interfaceId
            || interfaceId == 0x01ffc9a7; // type(IERC165).interfaceId
    }

    function onERC1155Received(
        address, address, uint256, uint256, bytes calldata
    ) external returns (bytes4) {
        if (mode == 1) {
            // TOCTOU attempt: yank the exchange's USDT allowance mid-settlement.
            usdt.approve(exchange, 0);
        } else if (mode == 2) {
            revert("buyer rejects ERC1155");
        }
        return 0xf23a6e61; // IERC1155Receiver.onERC1155Received.selector
    }

    function onERC1155BatchReceived(
        address, address, uint256[] calldata, uint256[] calldata, bytes calldata
    ) external pure returns (bytes4) {
        return 0xbc197c81; // IERC1155Receiver.onERC1155BatchReceived.selector
    }
}
