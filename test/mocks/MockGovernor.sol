// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Minimal governor stand-in exposing only what `StandardRuleset` consumes
///      (`proposalSnapshot`). Doubles as the `onlyGovernor` caller in tests — the ruleset
///      is constructed with this contract's address, so pranking as it exercises the same
///      authorization path a real governor would.
contract MockGovernor {
    mapping(uint256 => uint256) public proposalSnapshot;

    function setSnapshot(uint256 proposalId, uint256 snapshot) external {
        proposalSnapshot[proposalId] = snapshot;
    }
}
