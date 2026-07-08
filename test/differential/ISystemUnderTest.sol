// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Implementation-neutral handles for the system under differential test.
///      Function and error signatures mirror the draft repo's public surface
///      (governor-nexus v0.1) — selectors are signature-derived, so `expectRevert`
///      and `abi.encodeCall` against these types hit any implementation that keeps
///      the same ABI. This surface is frozen in docs/spec/v1.md §Vector surface;
///      loosening it for a clean-room reimplementation is a spec change, not a
///      test-harness edit.

/// @dev Governor under test: stock IGovernor surface + the Nexus extensions.
interface INexus {
    // ── errors (core) ──
    error UnknownProposalType(uint8 proposalType);
    error ProposerActiveLimitReached(address proposer, uint256 limit);
    error BatchLengthMismatch();
    error RulesetsAlreadyInitialized();
    error NotRulesetInitializer(address caller);
    error NonexistentProposal(uint256 proposalId);

    // ── stock governor surface used by the vectors ──
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256);
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);
    function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        external
        returns (uint256);
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external payable returns (uint256);
    function castVote(uint256 proposalId, uint8 support) external returns (uint256);
    function state(uint256 proposalId) external view returns (uint8);
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);
    function proposalDeadline(uint256 proposalId) external view returns (uint256);
    function getVotes(address account, uint256 timepoint) external view returns (uint256);
    function hasVoted(uint256 proposalId, address account) external view returns (bool);
    function quorum(uint256 timepoint) external view returns (uint256);

    // ── Nexus extensions ──
    function proposeWithType(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint8 proposalType
    ) external returns (uint256);
    function castVoteBatch(uint256[] calldata proposalIds, uint8[] calldata supportValues, string[] calldata reasons)
        external
        returns (uint256[] memory weights);
    function initializeRulesets(uint8[] calldata typeIds, address[] calldata rulesets) external;
    function setRuleset(uint8 proposalType, address ruleset) external;
    function ruleset(uint8 proposalType) external view returns (address);
    function proposalType(uint256 proposalId) external view returns (uint8);
    function proposalRuleset(uint256 proposalId) external view returns (address);
    function activeProposalCount(address proposer) external view returns (uint256);
}

/// @dev Errors shared by every ruleset implementation.
interface IRulesetErrors {
    error InvalidSupport(uint8 support);
}

/// @dev Standard ruleset handle: per-support tallies exposed for tally-conservation vectors.
interface IStandardRulesetVector {
    function tally(uint256 proposalId, uint8 support) external view returns (uint256);
}

/// @dev Bond ruleset handle (bond-backed proposals, RFC §2.4).
interface IBondRulesetVector {
    error ProposalNotTerminal(uint256 proposalId, uint8 state);
    error BondAlreadyResolved(uint256 proposalId);

    function bonds(uint256 proposalId) external view returns (address proposer, uint96 amount, bool resolved);
    function resolveBond(uint256 proposalId) external;
}

/// @dev Optimistic ruleset handle (veto-based proposals, RFC §2.7).
interface IOptimisticRulesetVector {
    error ProposerNotAllowed(address proposer);
    error ActionNotAllowed(address target, bytes4 selector);
    error ValueNotAllowed(address target, uint256 value);
    error CalldataTooShort(address target);

    function setAllowedProposer(address proposer, bool allowed) external;
    function setAllowedAction(address target, bytes4 selector, bool allowed) external;
}
