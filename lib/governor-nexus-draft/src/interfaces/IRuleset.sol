// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRuleset
/// @notice A ruleset defines the type-specific governance rules for proposals routed
///         through GovernorNexus: proposer eligibility, voting period, quorum, vote
///         counting (including which support options are valid), and success criteria.
///         The core governor owns the proposal lifecycle and dispatches to the ruleset
///         bound to each proposal at creation time.
interface IRuleset {
    /// @notice Validates proposer eligibility and performs type-specific setup
    ///         (e.g. pulling a bond, checking action allowlists). MUST revert if the
    ///         proposal is not eligible under this ruleset. Only callable by the governor.
    function onPropose(
        uint256 proposalId,
        address proposer,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external;

    /// @notice Records a vote. Re-votes MUST replace the voter's previous vote
    ///         (mutable voting). Reverts on unsupported `support` values.
    ///         Only callable by the governor.
    /// @return votedWeight The weight credited for this vote.
    function countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 totalWeight,
        bytes calldata params
    ) external returns (uint256 votedWeight);

    /// @notice Voting period in governor clock units. Returning 0 means
    ///         "use the governor's default voting period".
    function votingPeriod() external view returns (uint256);

    /// @notice Quorum required for this proposal (absolute token amount). Informational
    ///         alongside `quorumReached`, which is the authoritative check.
    function quorum(uint256 proposalId) external view returns (uint256);

    /// @notice Whether the proposal has reached quorum under this ruleset.
    function quorumReached(uint256 proposalId) external view returns (bool);

    /// @notice Whether the proposal has succeeded under this ruleset's approval rule.
    function voteSucceeded(uint256 proposalId) external view returns (bool);

    /// @notice Whether `account` has a currently-counted vote on `proposalId`.
    function hasVoted(uint256 proposalId, address account) external view returns (bool);

    /// @notice Whether proposals under this ruleset require the proposer to hold the
    ///         governor's proposal threshold — at creation AND continuously thereafter
    ///         (below-threshold proposals become cancelable by any address).
    function requiresProposerThreshold() external view returns (bool);

    /// @notice ERC-712-style counting mode descriptor for this ruleset.
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external view returns (string memory);
}
