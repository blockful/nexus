// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockENSToken} from "./MockENSToken.sol";

/// @dev ERC20Votes mock that burns 1% on every transfer — exercises the measured-delta
///      custody rule (the bond amount is derived from the balance actually received, not the
///      amount requested). Never a real deployment concern (ENS is plain); the invariant
///      must not depend on that assumption.
/// @dev Adaptation: fee logic sits at `transfer`/`transferFrom` rather than `_update` —
///      `MockENSToken._update` is not `virtual` (it is the terminal override in that
///      contract's chain), so it cannot be overridden further. `transfer`/`transferFrom` are
///      `virtual` on base `ERC20` and untouched by `ERC20Votes`/`ERC20Permit`, and
///      `transferFrom` is the exact path `SafeERC20.safeTransferFrom` exercises.
contract FeeOnTransferToken is MockENSToken {
    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 fee = value / 100;
        super.transfer(address(0xdead), fee);
        return super.transfer(to, value - fee);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 fee = value / 100;
        super.transferFrom(from, address(0xdead), fee);
        return super.transferFrom(from, to, value - fee);
    }
}
