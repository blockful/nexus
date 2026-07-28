// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IRuleset} from "./interfaces/IRuleset.sol";

/// @title RulesetQuorumFraction
/// @notice Shared fractional-quorum machinery for rulesets that anchor quorum to the voting
///         token's past total supply: `quorum(timepoint) = pastTotalSupply * numerator / 100`.
/// @dev Owns only the mechanical fraction. Which buckets count toward quorum
///      (`quorumReached`) stays in the inheriting ruleset — that is per-ruleset semantics,
///      not shared arithmetic. Immutable by design: no setters, matching the ruleset pattern.
abstract contract RulesetQuorumFraction is IRuleset {
    /// @dev Fixed at 100 so a numerator of 1 encodes 1%, matching OZ's default
    ///      `GovernorVotesQuorumFraction` denominator. Not exposed and not overridable.
    uint256 private constant QUORUM_DENOMINATOR = 100;

    /// @notice Voting token whose past total supply anchors `quorum`.
    IVotes public immutable token;
    /// @notice Quorum numerator over the fixed 100 denominator (e.g. `1` = 1%).
    uint256 public immutable quorumNumerator;

    /// @notice `numerator` is zero (disables the quorum gate entirely) or exceeds the
    ///         denominator (100, a quorum > 100%).
    error InvalidQuorumFraction(uint256 numerator, uint256 denominator);

    /// @param token_ Voting token backing `quorum`'s past-total-supply lookup.
    /// @param quorumNumerator_ Numerator over the fixed 100 denominator; reverts
    ///        `InvalidQuorumFraction` at zero (would make `quorumReached` unconditionally
    ///        true) and above 100.
    constructor(IVotes token_, uint256 quorumNumerator_) {
        if (quorumNumerator_ == 0 || quorumNumerator_ > QUORUM_DENOMINATOR) {
            revert InvalidQuorumFraction(quorumNumerator_, QUORUM_DENOMINATOR);
        }
        token = token_;
        quorumNumerator = quorumNumerator_;
    }

    /// @inheritdoc IRuleset
    /// @dev Fraction of the token's past total supply at `timepoint`.
    function quorum(uint256 timepoint) public view returns (uint256) {
        return token.getPastTotalSupply(timepoint) * quorumNumerator / QUORUM_DENOMINATOR;
    }
}
