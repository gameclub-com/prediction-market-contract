// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockRejectUSDT — ERC20 that can be toggled to reject transfer() calls.
/// @dev Used to test _collectFee fallback to unclaimedFees (M-3).
contract MockRejectUSDT is ERC20 {
    bool public rejectTransfers;

    constructor() ERC20("Tether USD", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRejectTransfers(bool _reject) external {
        rejectTransfers = _reject;
    }

    /// @dev transfer() returns false when rejectTransfers is on.
    ///      transferFrom() always works (so settlement can pull funds normally).
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (rejectTransfers) {
            return false;
        }
        return super.transfer(to, amount);
    }
}
