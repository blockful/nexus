// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {MockENSToken} from "./mocks/MockENSToken.sol";

/// @dev Test-only harness: supplies working `GovernorCountingSimple` counting so the full
///      governance loop (propose → vote → queue → execute) can run. Production
///      `GovernorNexus` keeps its Task 4 revert stubs; this exists ONLY to reach the
///      `onlyGovernance` setters through real execution. The surface under test is
///      100% `GovernorNexus`.
contract GovernorNexusHarness is GovernorNexus, GovernorCountingSimple {
    constructor(
        IVotes token,
        TimelockController timelock,
        IRuleset standardRuleset,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_
    ) GovernorNexus(token, timelock, standardRuleset, votingDelay_, votingPeriod_, proposalThreshold_) {}

    function quorum(uint256) public pure override(Governor, GovernorNexus) returns (uint256) {
        return 1; // trivial: any cast vote clears it
    }

    function proposalThreshold() public view override(Governor, GovernorNexus) returns (uint256) {
        return super.proposalThreshold();
    }

    function COUNTING_MODE() public pure override(GovernorNexus, GovernorCountingSimple) returns (string memory) {
        return GovernorCountingSimple.COUNTING_MODE();
    }

    function hasVoted(uint256 proposalId, address account)
        public
        view
        override(GovernorNexus, GovernorCountingSimple)
        returns (bool)
    {
        return GovernorCountingSimple.hasVoted(proposalId, account);
    }

    function _quorumReached(uint256 proposalId)
        internal
        view
        override(GovernorNexus, GovernorCountingSimple)
        returns (bool)
    {
        return GovernorCountingSimple._quorumReached(proposalId);
    }

    function _voteSucceeded(uint256 proposalId)
        internal
        view
        override(GovernorNexus, GovernorCountingSimple)
        returns (bool)
    {
        return GovernorCountingSimple._voteSucceeded(proposalId);
    }

    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params)
        internal
        override(GovernorNexus, GovernorCountingSimple)
        returns (uint256)
    {
        return GovernorCountingSimple._countVote(proposalId, account, support, weight, params);
    }

    // Diamond re-resolution: GovernorNexus's overrides vs the Governor copy reached
    // through GovernorCountingSimple. `super` routes back to GovernorNexus.

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(Governor, GovernorNexus) returns (uint256) {
        return super.propose(targets, values, calldatas, description);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorNexus) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorNexus) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorNexus) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorNexus) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorNexus) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorNexus) returns (address) {
        return super._executor();
    }
}

/// @dev Shared fixture for GovernorNexus unit suites: deploys token + timelock + harness
///      governor + bootstrap ruleset, funds a majority voter, and provides the governance
///      loop that is the only path to the `onlyGovernance` setters.
abstract contract GovernorNexusTestBase is Test {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 50;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;

    MockENSToken internal token;
    TimelockController internal timelock;
    GovernorNexusHarness internal governor;
    StandardRuleset internal standardRuleset;

    address internal alice = makeAddr("alice"); // proposer + majority voter
    address internal eoa = makeAddr("eoa"); // unauthorized caller

    function setUp() public virtual {
        vm.roll(1000);
        vm.warp(1_700_000_000);

        token = new MockENSToken();
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), new address[](0), address(this));

        // Governor arg is irrelevant to these unit suites (countVote is never reached here).
        standardRuleset = new StandardRuleset(address(0xBEEF), IVotes(address(token)), 1);

        governor = new GovernorNexusHarness(
            IVotes(address(token)), timelock, standardRuleset, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        _fund(alice, 2_000_000e18);
        vm.roll(block.number + 1);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.delegate(account);
    }

    /// @dev Deploys a fresh StandardRuleset (a valid IRuleset) for registration tests.
    function _newRuleset() internal returns (StandardRuleset) {
        return new StandardRuleset(address(governor), IVotes(address(token)), 1);
    }

    // ───────────────── Governance loop (the only path to the setters) ─────────────────

    /// @dev Propose (self-call) → vote → queue → warp past timelock; leaves the proposal
    ///      ready to `execute`. Caller executes so it can wrap `execute` with expectEmit /
    ///      expectRevert as needed.
    function _prepareSelfCall(bytes memory data, string memory description)
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = data;
        descriptionHash = keccak256(bytes(description));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
    }

    /// @dev Full loop including a successful execute.
    function _executeSelfCall(bytes memory data, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _prepareSelfCall(data, description);
        governor.execute(targets, values, calldatas, descriptionHash);
    }
}
