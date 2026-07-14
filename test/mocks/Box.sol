// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Simple governance target owned by the timelock: proposals call `setValue` and
///      tests assert the effect landed. The minimal observable "thing governance does".
contract Box {
    address public immutable owner;
    uint256 public value;

    constructor(address owner_) {
        owner = owner_;
    }

    function setValue(uint256 value_) external {
        require(msg.sender == owner, "not owner");
        value = value_;
    }
}
