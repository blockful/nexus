// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IProposalValidator
/// @notice Optional ruleset extension: propose-time validation of a proposal's content.
///         A ruleset advertising this interface via ERC165 gets `validateProposal` called
///         by the governor before the proposal is created; reverting blocks creation.
interface IProposalValidator {
    /// @notice Validates a proposal's content before creation; MUST revert iff the
    ///         proposal must not be created under this ruleset's type.
    /// @param proposer The account creating the proposal.
    /// @param targets Call targets, one per action.
    /// @param values ETH values, one per action.
    /// @param calldatas Encoded calls, one per action.
    /// @param descriptionHash Hash of the proposal description.
    function validateProposal(
        address proposer,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external;
}
