// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockENSToken} from "./MockENSToken.sol";

/// @dev ERC20Votes mock that burns 1% on every transfer — exercises the under-delivery guard
///      (a token that delivers less than requested makes a bond lock revert). Never a real
///      deployment concern (ENS is plain); the guard must not depend on that assumption.
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
