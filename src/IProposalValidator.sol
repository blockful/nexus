// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IProposalValidator
/// @notice Optional ruleset extension: a propose-time hook the governor calls before the
///         stock proposal-creation body runs (N7 D50, amended by N8 D62). Detected once via
///         ERC165 at registration and pinned on the type line (D51).
/// @dev MUST revert iff the proposal must not be created under this ruleset's type.
///      Implementations MUST be restricted to the governor and MUST perform their own
///      length-equality checks before indexing the arrays. `descriptionHash` lets an
///      implementation derive the canonical proposalId (D62).
interface IProposalValidator {
    function validateProposal(
        address proposer,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external;
}
