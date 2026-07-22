// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IProposalValidator
/// @notice Optional ruleset extension: propose-time validation of a proposal's content.
///         A ruleset advertising this interface via ERC165 gets `validateProposal` called
///         by the governor before the proposal is created; reverting blocks creation.
/// @dev Detected once at type registration and pinned on the type's registry line, so a
///      ruleset cannot gain or lose the gate after the DAO approved it. Declared non-view
///      so implementations are free to record propose-time state. Implementations MUST
///      restrict the caller to their governor (anyone else can pass arbitrary arguments)
///      and MUST check the three array lengths match before any indexing — the governor
///      calls this before the stock `_propose` length validation runs.
interface IProposalValidator {
    /// @notice Validates a proposal's content before creation; MUST revert iff the
    ///         proposal must not be created under this ruleset's type.
    /// @param proposer The account creating the proposal.
    /// @param targets Call targets, one per action.
    /// @param values ETH values, one per action.
    /// @param calldatas Encoded calls, one per action.
    function validateProposal(
        address proposer,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external;
}
