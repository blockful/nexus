// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {OptimisticRuleset} from "../src/OptimisticRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";
import {Box} from "./mocks/Box.sol";

/// @dev Integration suite for the optimistic type on a live GovernorNexus: the ruleset's
///      validation rules propagating through the propose-time gate, allowlist entries
///      landing through the full governance loop, the end-to-end lifecycle (zero-vote
///      success, veto defeat), and the veto-withdrawal interaction with the anti-snipe
///      extension. The gate mechanism itself is covered in
///      `GovernorNexus.proposalValidation.t.sol`.
contract GovernorNexusOptimisticTest is GovernorNexusTestBase {
    /// @dev OZ `GovernorPreventLateQuorum` event ABI, adopted verbatim by the extension.
    event ProposalExtended(uint256 indexed proposalId, uint64 extendedDeadline);

    uint256 internal constant VETO_THRESHOLD = 500_000e18;
    uint8 internal constant OPTIMISTIC_TYPE = 1;

    OptimisticRuleset internal optimistic;
    Box internal box;

    address internal bob = makeAddr("bob"); // vetoer, funded above the threshold

    function setUp() public virtual override {
        super.setUp();
        _fund(bob, 600_000e18);
        vm.roll(block.number + 1);

        box = new Box(address(timelock));
        optimistic = new OptimisticRuleset(address(governor), address(timelock), VETO_THRESHOLD);

        // Proposer threshold 0: under this ruleset the proposer gate is the allowlist, not
        // voting power (registration choice, mirroring the intended production line).
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (optimistic, VOTING_DELAY, VOTING_PERIOD, uint256(0))),
            "register optimistic type"
        );
        assertEq(governor.typeCount(), 2);
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _allowAlice() internal {
        vm.startPrank(address(timelock));
        optimistic.setProposerAllowed(alice, true);
        optimistic.setActionAllowed(address(box), Box.setValue.selector, true);
        vm.stopPrank();
    }

    function _boxProposal(uint256 newValue)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(box);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Box.setValue, (newValue));
    }

    /// @dev Propose `box.setValue(newValue)` through the optimistic type and roll into
    ///      Active. Returns the id and the ORIGINAL deadline.
    function _proposeOptimistic(uint256 newValue, string memory description)
        internal
        returns (uint256 id, uint256 originalDeadline)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(newValue);
        vm.prank(alice);
        id = governor.proposeWithType(targets, values, calldatas, description, OPTIMISTIC_TYPE);
        vm.roll(governor.proposalSnapshot(id) + 1);
        originalDeadline = governor.proposalDeadline(id);
    }

    function _vote(address voter, uint256 id, uint8 support) internal {
        vm.prank(voter);
        governor.castVote(id, support);
    }

    // ─────────────────────────── validation rules through the gate ───────────────────────────

    function test_proposeWithType_revertsForNonAllowlistedProposer() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ProposerNotAllowed.selector, alice));
        governor.proposeWithType(targets, values, calldatas, "not allowlisted", OPTIMISTIC_TYPE);
    }

    function test_proposeWithType_revertsForOffListAction() public {
        vm.prank(address(timelock));
        optimistic.setProposerAllowed(alice, true);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticRuleset.ActionNotAllowed.selector, address(box), Box.setValue.selector)
        );
        governor.proposeWithType(targets, values, calldatas, "action off-list", OPTIMISTIC_TYPE);
    }

    function test_proposeWithType_revertsForNonZeroValue() public {
        _allowAlice();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        values[0] = 1 ether;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ValueNotAllowed.selector, 0));
        governor.proposeWithType(targets, values, calldatas, "value forbidden", OPTIMISTIC_TYPE);
    }

    // ─────────────────────────── allowlists governed by the timelock ───────────────────────────

    function test_allowlistEntryLandsThroughFullGovernanceLoop() public {
        // The production path for "the DAO votes entries in": a standard proposal whose
        // action targets the ruleset's setter, executed by the timelock.
        address[] memory targets = new address[](1);
        targets[0] = address(optimistic);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(OptimisticRuleset.setProposerAllowed, (alice, true));
        string memory description = "allowlist alice as optimistic proposer";

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(id) + 1);
        _vote(alice, id, 1);
        vm.roll(governor.proposalDeadline(id) + 1);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertTrue(optimistic.allowedProposers(alice));
    }

    // ─────────────────────────── optimistic lifecycle e2e ───────────────────────────

    function test_e2e_zeroVoteProposalSucceedsAndExecutes() public {
        _allowAlice();
        (uint256 id,) = _proposeOptimistic(42, "zero-vote optimistic");

        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(
            uint8(governor.state(id)),
            uint8(IGovernor.ProposalState.Succeeded),
            "pass-by-default: zero votes cast, proposal succeeds"
        );

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(42);
        bytes32 descriptionHash = keccak256(bytes("zero-vote optimistic"));
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(box.value(), 42, "optimistic path must actually execute");
    }

    function test_e2e_vetoAtThresholdDefeats() public {
        _allowAlice();
        (uint256 id,) = _proposeOptimistic(7, "vetoed optimistic");

        _vote(bob, id, 0); // 600k Against >= 500k threshold

        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_e2e_forVotesDoNotSaveVetoedProposal() public {
        _allowAlice();
        (uint256 id,) = _proposeOptimistic(7, "for votes irrelevant");

        _vote(alice, id, 1); // 2M For
        _vote(bob, id, 0); // 600k Against — veto wins regardless

        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ─────────────────────── veto withdrawal × anti-snipe extension ───────────────────────

    function test_earlyVetoWithdrawal_noExtension() public {
        _allowAlice();
        (uint256 id, uint256 originalDeadline) = _proposeOptimistic(1, "early veto in and out");

        // Veto placed and withdrawn BEFORE the final window: no failing state is observed
        // in-window, so no extension arms.
        vm.roll(originalDeadline - EXTENSION_WINDOW - 5);
        _vote(bob, id, 0);
        _vote(bob, id, 1);

        vm.roll(originalDeadline + 1);
        assertEq(governor.proposalDeadline(id), originalDeadline, "no in-window failing witness, no extension");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_lateVetoWithdrawal_extendsAndSucceedsIfNotReVetoed() public {
        _allowAlice();
        (uint256 id, uint256 originalDeadline) = _proposeOptimistic(1, "late veto withdrawal");

        // Veto lands inside the final window (proposal observed failing), then the vetoer
        // withdraws — the snipe shape the extension exists for.
        vm.roll(originalDeadline - 5);
        _vote(bob, id, 0);
        _vote(bob, id, 1);

        vm.roll(originalDeadline + 1);
        assertEq(
            governor.proposalDeadline(id),
            originalDeadline + EXTENSION_DURATION,
            "failing->passing flip inside the window must extend voting"
        );
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active), "extension keeps voting open");

        vm.roll(originalDeadline + EXTENSION_DURATION + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_lateVetoWithdrawal_reVetoDuringExtensionDefeats() public {
        _allowAlice();
        (uint256 id, uint256 originalDeadline) = _proposeOptimistic(1, "re-veto during extension");

        vm.roll(originalDeadline - 5);
        _vote(bob, id, 0);
        _vote(bob, id, 1);

        // First cast past the original deadline materializes the extension (event emitted),
        // and the re-assembled veto inside the extension defeats the proposal.
        vm.roll(originalDeadline + 1);
        vm.expectEmit(true, false, false, true, address(governor));
        // forge-lint: disable-next-line(unsafe-typecast)
        emit ProposalExtended(id, uint64(originalDeadline + EXTENSION_DURATION));
        _vote(bob, id, 0);

        vm.roll(originalDeadline + EXTENSION_DURATION + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }
}
