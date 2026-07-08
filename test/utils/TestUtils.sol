// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @dev Mintable ERC20Votes stand-in for the ENS token (block-number clock, like ENS).
contract MockVotesToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Mock ENS", "mENS") ERC20Permit("Mock ENS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

/// @dev Simple governance target owned by the timelock.
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
