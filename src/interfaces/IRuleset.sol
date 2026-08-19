// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IRuleset
/// @notice Pluggable vote-counting module a GovernorNexus core delegates `countVote` to.
///         Rulesets own quorum/success rules and one-vote-per-voter enforcement — the
///         core only routes calls and reads outcomes back through this interface.
/// @dev `IERC165` lets a registry verify support at registration time (see
///      `StandardRuleset.supportsInterface`).
interface IRuleset is IERC165 {
    /// Called by the governor once per cast vote. MUST revert on rule violations
    /// (e.g. already voted for immutable-vote rulesets). Returns the weight counted.
    function countVote(uint256 proposalId, address voter, uint8 support, uint256 weight, bytes calldata params)
        external
        returns (uint256);

    /// @notice Whether `proposalId` has accumulated enough votes to meet quorum, per this
    ///         ruleset's own accounting.
    /// @dev Mirrors `hasVoted`'s unknown-id contract: a `proposalId` this ruleset never
    ///      counted is answered from empty-tally defaults, never a revert. That means this
    ///      can read `true` for an uncounted id whenever `quorum(0) == 0` — callers must
    ///      gate on proposal existence (the governor does via `state()`).
    ///
    ///      **MAY be non-monotonic.** A mutable-vote ruleset moves weight between buckets while
    ///      voting is open, so this can flip in *both* directions before the deadline (an
    ///      immutable-vote ruleset is monotonic — the guarantee is not part of this interface
    ///      either way). A consumer requiring finality MUST evaluate at/near the deadline and
    ///      MUST NOT arm one-shot state on a tally-crossing event — an attacker could cross the
    ///      threshold early, re-vote back below it, and burn a once-only trigger before the
    ///      crossing that matters.
    function quorumReached(uint256 proposalId) external view returns (bool);

    /// @notice Whether `proposalId`'s tallied votes satisfy this ruleset's pass/fail rule.
    /// @dev MAY be non-monotonic under a mutable-vote ruleset — see `quorumReached`. Consumers
    ///      needing finality must read it at/near the deadline, never arm one-shot state on a flip.
    function voteSucceeded(uint256 proposalId) external view returns (bool);

    /// @notice Whether `voter` has already cast a vote on `proposalId` under this ruleset.
    /// @dev MUST NOT revert on unknown proposal ids: implementations answer from their own
    ///      tally storage, so a `proposalId` this ruleset never counted reads as `false`
    ///      (empty-tally default), never as an error.
    function hasVoted(uint256 proposalId, address voter) external view returns (bool);

    /// @notice The governor this ruleset is bound to — its sole authorized `countVote` caller.
    /// @dev Read once at type registration: a governor refuses rulesets bound elsewhere, so a
    ///      mis-wired deployment reverts at `registerType` instead of shipping a type that
    ///      bricks on first propose/vote.
    function governor() external view returns (address);

    /// Tooling/view support only — never used for outcome logic (that is `quorumReached`).
    function quorum(uint256 timepoint) external view returns (uint256);

    /// @notice Machine-readable description of the vote-counting scheme (Bravo-style).
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external view returns (string memory);
}
