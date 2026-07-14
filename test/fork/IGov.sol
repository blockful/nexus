// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Minimal surface shared by the live ENS governor (OZ v4-era) and the v5 scaffold.
///      Deliberately the INTERSECTION of what both sides expose: selectors are
///      signature-derived, so calls through this type hit either implementation, and a
///      parity test cannot call anything the live governor lacks — that fails at
///      compile time instead of reverting at runtime.
interface IGov {
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256);
    function castVote(uint256 proposalId, uint8 support) external returns (uint256);
    function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        external
        returns (uint256);
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external payable returns (uint256);
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);
    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external pure returns (uint256);
    function state(uint256 proposalId) external view returns (uint8);
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);
    function proposalDeadline(uint256 proposalId) external view returns (uint256);
    function proposalEta(uint256 proposalId) external view returns (uint256);
    function hasVoted(uint256 proposalId, address account) external view returns (bool);
    function getVotes(address account, uint256 timepoint) external view returns (uint256);
    function name() external view returns (string memory);
    function votingDelay() external view returns (uint256);
    function votingPeriod() external view returns (uint256);
    function proposalThreshold() external view returns (uint256);
    function quorum(uint256 timepoint) external view returns (uint256);
    function quorumNumerator() external view returns (uint256);
    function quorumDenominator() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external view returns (string memory);
    function token() external view returns (address);
    function timelock() external view returns (address);
}
