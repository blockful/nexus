// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {INexus} from "./ISystemUnderTest.sol";
import {VectorsFixture} from "./VectorsFixture.sol";

/// @dev Core governor vectors — port of the draft repo's GovernorNexus.t.sol (24 tests),
///      verbatim except for interface-typed handles. Do not edit test bodies here without
///      a spec change: they are the shared behavioral record both implementations must match.
abstract contract GovernorCoreVectors is VectorsFixture {
    // ─────────────────────────── Lifecycle & settings ───────────────────────────

    function test_fullLifecycle_standardProposal() public {
        uint256 proposalId = _proposeStandard(alice, 42, "set 42");

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
        assertEq(governor.proposalType(proposalId), TYPE_STANDARD);
        assertEq(governor.proposalRuleset(proposalId), address(standardRuleset));

        _rollToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 1); // For, 200e18 >= quorum

        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        _queueAndExecute(42, "set 42");
        assertEq(box.value(), 42);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_votingDelay_appliesBeforeSnapshot() public {
        uint256 proposalId = _proposeStandard(alice, 1, "delay check");
        assertEq(governor.proposalSnapshot(proposalId), block.number + VOTING_DELAY);

        // cannot vote before the snapshot
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_quorumView_returnsStandardQuorum() public view {
        assertEq(governor.quorum(0), QUORUM);
    }

    function test_defeated_whenQuorumNotReached() public {
        uint256 proposalId = _proposeStandard(alice, 1, "no quorum");
        _rollToActive(proposalId);
        vm.prank(carol);
        governor.castVote(proposalId, 1); // 50e18 < 100e18 quorum
        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ─────────────────────────── Mutable votes ───────────────────────────

    function test_mutableVote_revoteReplacesPrevious() public {
        uint256 proposalId = _proposeStandard(alice, 1, "mutable");
        _rollToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 1);
        assertEq(standardRuleset.tally(proposalId, 1), 200e18);

        vm.prank(alice);
        governor.castVote(proposalId, 0); // change vote
        assertEq(standardRuleset.tally(proposalId, 1), 0);
        assertEq(standardRuleset.tally(proposalId, 0), 200e18);
        assertTrue(governor.hasVoted(proposalId, alice));

        vm.prank(alice);
        governor.castVote(proposalId, 2); // change again
        assertEq(standardRuleset.tally(proposalId, 0), 0);
        assertEq(standardRuleset.tally(proposalId, 2), 200e18);
    }

    function testFuzz_mutableVote_tallyConservation(uint8 first, uint8 second) public {
        first = uint8(bound(first, 0, 2));
        second = uint8(bound(second, 0, 2));
        uint256 proposalId = _proposeStandard(alice, 1, "fuzz mutable");
        _rollToActive(proposalId);

        vm.startPrank(alice);
        governor.castVote(proposalId, first);
        governor.castVote(proposalId, second);
        vm.stopPrank();

        uint256 total;
        for (uint8 s = 0; s <= 2; ++s) {
            total += standardRuleset.tally(proposalId, s);
        }
        assertEq(total, 200e18); // weight never double-counted
        assertEq(standardRuleset.tally(proposalId, second), 200e18);
    }

    // ─────────────────────────── Per-proposer active limit ───────────────────────────

    function test_activeLimit_blocksThirdConcurrentProposal() public {
        _proposeStandard(alice, 1, "p1");
        _proposeStandard(alice, 2, "p2");
        assertEq(governor.activeProposalCount(alice), 2);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(3, "p3");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INexus.ProposerActiveLimitReached.selector, alice, 2));
        governor.propose(targets, values, calldatas, "p3");
    }

    function test_activeLimit_freesSlotAfterCancel() public {
        uint256 p1 = _proposeStandard(alice, 1, "p1");
        _proposeStandard(alice, 2, "p2");

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(1, "p1");
        vm.prank(alice);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(p1)), uint8(IGovernor.ProposalState.Canceled));

        _proposeStandard(alice, 3, "p3"); // slot freed
        assertEq(governor.activeProposalCount(alice), 2);
    }

    function test_activeLimit_freesSlotAfterVotingEnds() public {
        uint256 p1 = _proposeStandard(alice, 1, "p1");
        _proposeStandard(alice, 2, "p2");
        _rollPastDeadline(p1); // both proposals past deadline (same schedule)

        _proposeStandard(alice, 3, "p3");
    }

    // ─────────────────────────── Cancellation ───────────────────────────

    function test_selfCancel_whileActive() public {
        uint256 proposalId = _proposeStandard(alice, 1, "self cancel");
        _rollToActive(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(1, "self cancel");
        vm.prank(alice);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_strangerCannotCancel_whenProposerAboveThreshold() public {
        uint256 proposalId = _proposeStandard(alice, 1, "protected");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(1, "protected");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, bob));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    function test_anyoneCanCancel_whenProposerDropsBelowThreshold() public {
        uint256 proposalId = _proposeStandard(alice, 1, "threshold drop");
        _rollToActive(proposalId);

        // alice dumps her voting power after proposing (RFC §2.1 attack)
        vm.prank(alice);
        token.delegate(address(0xdead));
        vm.roll(block.number + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(1, "threshold drop");
        vm.prank(bob); // any address
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_cancelNotPossible_afterVotingEnds() public {
        uint256 proposalId = _proposeStandard(alice, 1, "too late");
        _rollToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        _rollPastDeadline(proposalId);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(1, "too late");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, alice));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    // ─────────────────────────── Batch voting ───────────────────────────

    function test_castVoteBatch_votesOnMultipleProposals() public {
        uint256 p1 = _proposeStandard(alice, 1, "batch 1");
        uint256 p2 = _proposeStandard(bob, 2, "batch 2");
        _rollToActive(p2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = p1;
        ids[1] = p2;
        uint8[] memory supportValues = new uint8[](2);
        supportValues[0] = 1;
        supportValues[1] = 0;
        string[] memory reasons = new string[](2);
        reasons[0] = "yes";
        reasons[1] = "no";

        vm.prank(carol);
        uint256[] memory weights = governor.castVoteBatch(ids, supportValues, reasons);
        assertEq(weights[0], 50e18);
        assertEq(weights[1], 50e18);
        assertTrue(governor.hasVoted(p1, carol));
        assertTrue(governor.hasVoted(p2, carol));
        assertEq(standardRuleset.tally(p1, 1), 50e18);
        assertEq(standardRuleset.tally(p2, 0), 50e18);
    }

    function test_castVoteBatch_lengthMismatchReverts() public {
        uint256[] memory ids = new uint256[](2);
        uint8[] memory supportValues = new uint8[](1);
        string[] memory reasons = new string[](2);
        vm.expectRevert(INexus.BatchLengthMismatch.selector);
        governor.castVoteBatch(ids, supportValues, reasons);
    }

    // ─────────────────────────── Late vote extension ───────────────────────────

    function test_lateFlip_extendsDeadlineOnce() public {
        uint256 proposalId = _proposeStandard(alice, 1, "late flip");
        uint256 originalDeadline = governor.proposalDeadline(proposalId);

        // inside the late window, proposal failing (no votes)
        vm.roll(originalDeadline - LATE_WINDOW / 2);
        vm.prank(alice);
        governor.castVote(proposalId, 1); // flips failing -> passing

        uint256 extendedDeadline = governor.proposalDeadline(proposalId);
        assertEq(extendedDeadline, block.number + LATE_EXTENSION);
        assertGt(extendedDeadline, originalDeadline);

        // still Active past the original deadline
        vm.roll(originalDeadline + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // a second genuine flip inside the extended window cannot extend again
        vm.roll(extendedDeadline - 10);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // passing -> failing
        vm.prank(alice);
        governor.castVote(proposalId, 1); // failing -> passing again
        assertEq(governor.proposalDeadline(proposalId), extendedDeadline);

        vm.roll(extendedDeadline + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_earlyFlip_doesNotExtend() public {
        uint256 proposalId = _proposeStandard(alice, 1, "early flip");
        uint256 originalDeadline = governor.proposalDeadline(proposalId);

        _rollToActive(proposalId); // far before the late window
        vm.prank(alice);
        governor.castVote(proposalId, 1); // failing -> passing, but early
        assertEq(governor.proposalDeadline(proposalId), originalDeadline);
    }

    function test_lateVote_withoutFlip_doesNotExtend() public {
        uint256 proposalId = _proposeStandard(alice, 1, "no flip");
        uint256 originalDeadline = governor.proposalDeadline(proposalId);

        _rollToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 1); // passing early

        vm.roll(originalDeadline - 10);
        vm.prank(carol);
        governor.castVote(proposalId, 1); // already passing; late vote, no flip
        assertEq(governor.proposalDeadline(proposalId), originalDeadline);
    }

    // ─────────────────────────── Ruleset registry & types ───────────────────────────

    function test_unknownProposalType_reverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(1, "bad type");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INexus.UnknownProposalType.selector, 9));
        governor.proposeWithType(targets, values, calldatas, "bad type", 9);
    }

    function test_initializeRulesets_isOneShot() public {
        uint8[] memory typeIds = new uint8[](0);
        address[] memory rulesets = new address[](0);
        vm.expectRevert(INexus.RulesetsAlreadyInitialized.selector);
        governor.initializeRulesets(typeIds, rulesets);
    }

    function test_initializeRulesets_onlyDeployer() public {
        uint8[] memory typeIds = new uint8[](0);
        address[] memory rulesets = new address[](0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(INexus.NotRulesetInitializer.selector, bob));
        governor.initializeRulesets(typeIds, rulesets);
    }

    function test_setRuleset_onlyGovernance() public {
        vm.prank(bob);
        vm.expectRevert();
        governor.setRuleset(5, address(0x1234));
    }

    function test_setRuleset_throughGovernance() public {
        address newRuleset = address(standardRuleset); // reuse as a stand-in module
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(INexus.setRuleset, (5, newRuleset));
        string memory description = "register future module";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        _rollToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        _rollPastDeadline(proposalId);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(governor.ruleset(5), newRuleset);
    }

    function test_proposalType_immutableAndQueryable() public {
        uint256 proposalId = _proposeStandard(alice, 1, "typed");
        assertEq(governor.proposalType(proposalId), TYPE_STANDARD);
        vm.expectRevert(abi.encodeWithSelector(INexus.NonexistentProposal.selector, 12345));
        governor.proposalType(12345);
    }
}
