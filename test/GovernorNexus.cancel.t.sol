// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";
import {RevertingViewsRuleset} from "./mocks/MaliciousRulesets.sol";

/// @dev Cancellation policy: cancel is possible only while the proposal is Pending|Active —
///      by the proposer unconditionally, or by ANYONE when the proposer's prior-block votes
///      fall below the pinned type's threshold. Once voting ends (Succeeded/Defeated/Queued
///      and beyond) no one can cancel. `bob` is the proposer under test, `carol` the
///      third-party canceller; `alice` stays on governance-loop duty.
contract GovernorNexusCancelTest is GovernorNexusTestBase {
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        _fund(bob, 200_000e18);
        vm.roll(block.number + 1);
    }

    // ─────────────────────────── Helpers ───────────────────────────

    /// @dev Unique single-action proposal; the description carries the salt.
    function _args(string memory description)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(0xBEEF);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = "";
        descriptionHash = keccak256(bytes(description));
    }

    function _proposeAs(address proposer, string memory description) internal returns (uint256 proposalId) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _args(description);
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function _cancelAs(address caller, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args(description);
        vm.prank(caller);
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev Drives `proposalId` from Pending into the target state. Assumes the standard
    ///      `_args` payload and that nobody but (optionally) alice votes.
    function _reachState(uint256 proposalId, string memory description, IGovernor.ProposalState target) internal {
        if (target == IGovernor.ProposalState.Pending) return;
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        if (target == IGovernor.ProposalState.Active) return;
        if (target != IGovernor.ProposalState.Defeated) {
            vm.prank(alice);
            governor.castVote(proposalId, 1);
        }
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        if (target == IGovernor.ProposalState.Succeeded || target == IGovernor.ProposalState.Defeated) return;
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args(description);
        governor.queue(targets, values, calldatas, descriptionHash);
        if (target == IGovernor.ProposalState.Queued) return;
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    /// @dev Drops `account` below any nonzero threshold: undelegate, then advance one block
    ///      so `getVotes(account, clock() - 1)` reads the zeroed checkpoint.
    function _dipBelowThreshold(address account) internal {
        vm.prank(account);
        token.delegate(address(0));
        vm.roll(block.number + 1);
    }

    function _expectUnableToCancel(uint256 proposalId, address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, caller));
    }

    /// @dev Timelock operation id as GovernorTimelockControl derives it.
    function _timelockId(string memory description) internal view returns (bytes32) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args(description);
        bytes32 salt = bytes32(bytes20(address(governor))) ^ descriptionHash;
        return timelock.hashOperationBatch(targets, values, calldatas, 0, salt);
    }

    // ─────────────────────── Baseline: healthy proposals stay uncancellable ───────────────────────

    function test_thirdParty_cannotCancelHealthyProposal_anyState() public {
        IGovernor.ProposalState[4] memory states = [
            IGovernor.ProposalState.Pending,
            IGovernor.ProposalState.Active,
            IGovernor.ProposalState.Succeeded,
            IGovernor.ProposalState.Queued
        ];
        for (uint256 i = 0; i < states.length; ++i) {
            // fresh proposer per iteration: Pending|Active proposals occupy spam-limit slots
            address proposer = makeAddr(string.concat("healthy-proposer", vm.toString(i)));
            _fund(proposer, 200_000e18);
            vm.roll(block.number + 1);
            string memory description = string.concat("healthy", vm.toString(i));
            uint256 id = _proposeAs(proposer, description);
            _reachState(id, description, states[i]);
            _expectUnableToCancel(id, carol);
            _cancelAs(carol, description);
        }
    }

    function test_cancelNonexistentProposal_reverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args("never proposed");
        uint256 id = governor.getProposalId(targets, values, calldatas, descriptionHash);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, id));
        vm.prank(carol);
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    // ─────────────────────── Self-cancel: Pending|Active only ───────────────────────

    function test_selfCancel_pending() public {
        uint256 id = _proposeAs(bob, "p");
        vm.expectEmit(address(governor));
        emit IGovernor.ProposalCanceled(id);
        _cancelAs(bob, "p");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_selfCancel_active() public {
        uint256 id = _proposeAs(bob, "p");
        _reachState(id, "p", IGovernor.ProposalState.Active);
        _cancelAs(bob, "p");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_selfCancel_afterVotingEnds_reverts_whileAboveThreshold() public {
        uint256 id = _proposeAs(bob, "p");
        _reachState(id, "p", IGovernor.ProposalState.Succeeded);
        _expectUnableToCancel(id, bob);
        _cancelAs(bob, "p");

        uint256 idQ = _proposeAs(bob, "q");
        _reachState(idQ, "q", IGovernor.ProposalState.Queued);
        _expectUnableToCancel(idQ, bob);
        _cancelAs(bob, "q");
    }

    // ─────────────────── Continuous threshold: permissionless cancel ───────────────────

    function test_belowThreshold_anyoneCancels_pending() public {
        uint256 id = _proposeAs(bob, "p");
        _dipBelowThreshold(bob);
        _cancelAs(carol, "p");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_belowThreshold_anyoneCancels_active() public {
        uint256 id = _proposeAs(bob, "p");
        _reachState(id, "p", IGovernor.ProposalState.Active);
        _dipBelowThreshold(bob);
        _cancelAs(carol, "p");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_belowThreshold_votingEnded_uncancellable() public {
        // once voting ends the proposal is settled for cancellation purposes: below-threshold
        // proposers no longer expose it, in any post-vote state.
        IGovernor.ProposalState[3] memory states =
            [IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Queued];
        for (uint256 i = 0; i < states.length; ++i) {
            address proposer = makeAddr(string.concat("ended-proposer", vm.toString(i)));
            _fund(proposer, 200_000e18);
            vm.roll(block.number + 1);
            string memory description = string.concat("ended", vm.toString(i));
            uint256 id = _proposeAs(proposer, description);
            _reachState(id, description, states[i]);
            _dipBelowThreshold(proposer);
            _expectUnableToCancel(id, carol);
            _cancelAs(carol, description);
        }
    }

    function test_belowThreshold_queued_staysScheduled() public {
        uint256 id = _proposeAs(bob, "p");
        _reachState(id, "p", IGovernor.ProposalState.Queued);
        _dipBelowThreshold(bob);

        _expectUnableToCancel(id, carol);
        _cancelAs(carol, "p");

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
        assertTrue(timelock.isOperation(_timelockId("p")));
    }

    function test_belowThreshold_proposerCannotCancel_postVote() public {
        uint256 id = _proposeAs(bob, "p");
        _reachState(id, "p", IGovernor.ProposalState.Succeeded);
        _dipBelowThreshold(bob);
        _expectUnableToCancel(id, bob);
        _cancelAs(bob, "p");
    }

    function test_belowThreshold_executedProposal_uncancellable() public {
        uint256 id = _proposeAs(bob, "p");
        _reachState(id, "p", IGovernor.ProposalState.Executed);
        _dipBelowThreshold(bob);
        _expectUnableToCancel(id, carol);
        _cancelAs(carol, "p");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_exactlyAtThreshold_notCancellable() public {
        address eve = makeAddr("eve");
        _fund(eve, PROPOSAL_THRESHOLD); // exactly at threshold: `<` must not fire
        vm.roll(block.number + 1);
        uint256 id = _proposeAs(eve, "p");
        vm.roll(block.number + 1);
        _expectUnableToCancel(id, carol);
        _cancelAs(carol, "p");
    }

    // ─────────────────────── F5: prior-block read, churn window ───────────────────────

    function test_dipAtPriorBlock_cancellableEvenIfRestoredNow() public {
        uint256 id = _proposeAs(bob, "p");

        vm.prank(bob);
        token.delegate(address(0)); // checkpoint N: 0 votes
        vm.roll(block.number + 1);
        vm.prank(bob);
        token.delegate(bob); // checkpoint N+1: restored — but clock()-1 reads N

        _cancelAs(carol, "p");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    // ─────────────────────── Pin discipline: per-type threshold ───────────────────────

    function test_pinnedTypeThreshold_drivesTheCheck_notDefaultType() public {
        // register a 300k-threshold type; bob (200k) proposes under type 0 (100k) fine,
        // and is NOT cancellable — the pinned line, not the highest or newest, applies.
        StandardRuleset rs = _newRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs, VOTING_DELAY, VOTING_PERIOD, 300_000e18)),
            "register 300k type"
        );

        uint256 id = _proposeAs(bob, "under type 0");
        vm.roll(block.number + 1);
        _expectUnableToCancel(id, carol);
        _cancelAs(carol, "under type 0");

        // and a proposal pinned to the 300k line IS cancellable once its proposer dips below
        // 300k — even though they stay above type 0's 100k.
        address whale = makeAddr("whale");
        _fund(whale, 400_000e18);
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _args("under type 1");
        vm.prank(whale);
        uint256 idTyped = governor.proposeWithType(targets, values, calldatas, "under type 1", 1);

        vm.prank(whale);
        assertTrue(token.transfer(bob, 250_000e18)); // whale: 150k — above 100k, below pinned 300k
        vm.roll(block.number + 1);

        _cancelAs(carol, "under type 1");
        assertEq(uint8(governor.state(idTyped)), uint8(IGovernor.ProposalState.Canceled));
    }

    // ─────────────────── Threshold-based types only (threshold == 0) ───────────────────

    function test_zeroThresholdType_neverPermissionlesslyCancellable() public {
        StandardRuleset rs = _newRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs, VOTING_DELAY, VOTING_PERIOD, uint256(0))),
            "register zero-threshold type"
        );

        // dave holds zero votes — proposes under the zero-threshold type
        address dave = makeAddr("dave");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args("bondlike");
        vm.prank(dave);
        uint256 id = governor.proposeWithType(targets, values, calldatas, "bondlike", 1);

        _expectUnableToCancel(id, carol);
        _cancelAs(carol, "bondlike");

        // self-cancel still works for the zero-threshold type's proposer
        vm.prank(dave);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    // ─────────────────── Interactions & containment ───────────────────

    function test_permissionlessCancel_freesSpamLimitSlot() public {
        _proposeAs(bob, "p1");
        _proposeAs(bob, "p2"); // bob at the cap (2)
        _dipBelowThreshold(bob);
        _cancelAs(carol, "p1");
        assertEq(governor.activeProposalCount(bob), 1);
    }

    function test_poisonedRulesetType_selfCancelWorks_withinDeadline() public {
        // a ruleset with reverting views must not block cancel while state() still
        // resolves from core storage (pre-deadline) — Nexus 1 containment boundary.
        RevertingViewsRuleset poisoned = new RevertingViewsRuleset(address(governor));
        _executeSelfCall(
            abi.encodeCall(
                GovernorNexus.registerType, (IRuleset(address(poisoned)), VOTING_DELAY, VOTING_PERIOD, uint256(0))
            ),
            "register poisoned type"
        );

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args("poisoned");
        vm.prank(bob);
        uint256 id = governor.proposeWithType(targets, values, calldatas, "poisoned", 1);

        vm.prank(bob);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    // ─────────────────────── proposalCanceledAt ───────────────────────

    function test_proposalCanceledAt_zeroBeforeCancel() public {
        uint256 id = _proposeAs(bob, "canceled-at zero");
        assertEq(governor.proposalCanceledAt(id), 0);
    }

    function test_proposalCanceledAt_recordsClockOnSelfCancel() public {
        uint256 id = _proposeAs(bob, "canceled-at self");
        vm.roll(block.number + 1); // still Pending
        uint48 expected = uint48(block.number);
        _cancelAs(bob, "canceled-at self");
        assertEq(governor.proposalCanceledAt(id), expected);
    }
}
