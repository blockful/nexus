// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusHarness.sol";
import {Box} from "./mocks/Box.sol";
import {
    LyingRuleset,
    ReentrantRuleset,
    RevertingRuleset,
    RevertingViewsRuleset,
    WeightInflatingRuleset
} from "./mocks/MaliciousRulesets.sol";

/// @dev Supports ERC165 but NOT IRuleset — a ruleset that lies about its interface. Mirrors the
///      registry suite's `Mock165`; used here from the attack angle in the consolidated
///      registration-hardening test.
contract FakeInterfaceRuleset is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @title GovernorNexus adversarial suite
/// @notice Attack-first tests pinning the EXACT blast radius the spec (§8) promises: a
///         malicious/broken ruleset can break voting on ITS OWN proposals only. It must never
///         corrupt core lifecycle state, reach `onlyGovernance` surface, affect proposals
///         pinned to other types, let third parties stuff tallies, or let the registry accept
///         junk. Rulesets are DAO-vote-gated code (trust boundary is procedural — spec D3), so
///         some outcomes (e.g. LyingRuleset succeeding with zero votes) are ACCEPTED risks this
///         suite documents rather than bugs the core prevents.
/// @dev Reuses `GovernorNexusTestBase` (alice funds the whole supply, so any standard-quorum
///      proposal she votes For on passes) plus its governance loop for registering the
///      malicious types via vote. Malicious types are registered with a zero proposal
///      threshold so the reentrancy mock (zero voting power) can also propose.
contract GovernorNexusAdversarialTest is GovernorNexusTestBase {
    /// @dev Mirror of IGovernor.VoteCast for vm.expectEmit.
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 weight, string reason);

    Box internal box;

    function setUp() public override {
        super.setUp();
        // Execution target for victim/lifecycle proposals; owned by the timelock executor.
        box = new Box(address(timelock));
    }

    // ─────────────────────────── Helpers ───────────────────────────

    /// @dev Register `rs` as a new type via the governance loop; returns its assigned id.
    function _registerType(IRuleset rs, uint256 threshold, string memory desc) internal returns (uint8 typeId) {
        typeId = governor.typeCount();
        _executeSelfCall(abi.encodeCall(GovernorNexus.registerType, (rs, VOTING_DELAY, VOTING_PERIOD, threshold)), desc);
    }

    function _boxCall(uint256 newValue, string memory desc)
        internal
        view
        returns (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h)
    {
        t = new address[](1);
        t[0] = address(box);
        v = new uint256[](1);
        c = new bytes[](1);
        c[0] = abi.encodeCall(Box.setValue, (newValue));
        h = keccak256(bytes(desc));
    }

    /// @dev Alice proposes a box call on `typeId` and we roll into the active window.
    function _proposeActiveBox(uint256 newValue, string memory desc, uint8 typeId)
        internal
        returns (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h)
    {
        (t, v, c, h) = _boxCall(newValue, desc);
        vm.prank(alice);
        id = governor.proposeWithType(t, v, c, desc, typeId);
        vm.roll(governor.proposalSnapshot(id) + 1);
    }

    function _vote(uint256 id, address voter, uint8 support) internal {
        vm.prank(voter);
        governor.castVote(id, support);
    }

    /// @dev Roll forward (never backward) to just past a proposal's deadline.
    function _rollPastDeadline(uint256 id) internal {
        uint256 target = governor.proposalDeadline(id) + 1;
        if (block.number < target) vm.roll(target);
    }

    /// @dev Queue → warp past timelock → execute a proposal that reached Succeeded.
    function _queueAndExecute(address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) internal {
        governor.queue(t, v, c, h);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(t, v, c, h);
    }

    function _stateOf(uint256 id) internal view returns (IGovernor.ProposalState) {
        return governor.state(id);
    }

    // ═══════════════════════ RevertingRuleset ═══════════════════════

    /// @dev countVote reverts → voting on its OWN proposal is blocked, but state() stays
    ///      consistent: Active until the deadline, Defeated after (quorumReached honest-false).
    ///      state() never reverts, because it consults the outcome views, not countVote.
    function test_revertingRuleset_blocksOwnVotingButStateStaysConsistent() public {
        RevertingRuleset rr = new RevertingRuleset(address(governor));
        uint8 typeId = _registerType(rr, 0, "register reverting ruleset");

        (uint256 id,,,,) = _proposeActiveBox(1, "reverting proposal", typeId);
        assertEq(uint8(_stateOf(id)), uint8(IGovernor.ProposalState.Active));

        // Voting is blocked on this proposal — countVote reverts, so castVote reverts.
        vm.prank(alice);
        vm.expectRevert(RevertingRuleset.CountVoteDisabled.selector);
        governor.castVote(id, 1);

        // Lifecycle bookkeeping is untouched: still Active before the deadline.
        assertEq(uint8(_stateOf(id)), uint8(IGovernor.ProposalState.Active));

        // After the deadline state() resolves to Defeated (quorum not reached) — no revert.
        _rollPastDeadline(id);
        assertEq(uint8(_stateOf(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    /// @dev While a reverting-ruleset proposal is permanently stuck, a proposal on ANOTHER type
    ///      (the default StandardRuleset) runs its full propose→vote→queue→execute lifecycle.
    function test_revertingRuleset_otherTypeProposalCompletesFullLifecycle() public {
        RevertingRuleset rr = new RevertingRuleset(address(governor));
        uint8 badType = _registerType(rr, 0, "register reverting ruleset");

        // The doomed proposal on the bad type.
        (uint256 badId,,,,) = _proposeActiveBox(1, "reverting proposal", badType);
        vm.prank(alice);
        vm.expectRevert(RevertingRuleset.CountVoteDisabled.selector);
        governor.castVote(badId, 1);

        // The victim proposal on type 0 votes and executes normally, in parallel.
        (uint256 victimId, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _proposeActiveBox(42, "victim proposal", 0);
        _vote(victimId, alice, 1);
        _rollPastDeadline(victimId);
        assertEq(uint8(_stateOf(victimId)), uint8(IGovernor.ProposalState.Succeeded));
        _queueAndExecute(t, v, c, h);
        assertEq(box.value(), 42);
        assertEq(uint8(_stateOf(victimId)), uint8(IGovernor.ProposalState.Executed));

        // The bad proposal is still stuck (Defeated, never counted), containment intact.
        assertEq(uint8(_stateOf(badId)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ═══════════════════════ LyingRuleset ═══════════════════════

    /// @dev ACCEPTED RISK (spec D3): a ruleset whose outcome views always return true carries
    ///      its proposal to Succeeded — and through queue/execute — with ZERO votes cast. This
    ///      is the trust model: rulesets are DAO-vote-gated code, so this is caught by process
    ///      (audit + the registration vote), not by the core. The test documents the blast
    ///      radius and pins that proposals on OTHER types are unaffected.
    function test_lyingRuleset_succeedsAndExecutesWithZeroVotes_acceptedRiskD3() public {
        LyingRuleset lyingRuleset = new LyingRuleset(address(governor));
        uint8 badType = _registerType(lyingRuleset, 0, "register lying ruleset");

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _boxCall(7, "lying proposal");
        vm.prank(alice);
        uint256 badId = governor.proposeWithType(t, v, c, "lying proposal", badType);

        // No votes are ever cast. After the deadline the lying views force Succeeded.
        _rollPastDeadline(badId);
        assertFalse(governor.hasVoted(badId, alice));
        assertEq(uint8(_stateOf(badId)), uint8(IGovernor.ProposalState.Succeeded));

        // Full blast radius: a zero-vote proposal executes and mutates state.
        _queueAndExecute(t, v, c, h);
        assertEq(box.value(), 7);
        assertEq(uint8(_stateOf(badId)), uint8(IGovernor.ProposalState.Executed));

        // Containment: a type-0 proposal with no votes still honestly resolves to Defeated.
        (uint256 victimId,,,,) = _proposeActiveBox(99, "honest zero-vote proposal", 0);
        _rollPastDeadline(victimId);
        assertEq(uint8(_stateOf(victimId)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ═══════════════════════ RevertingViewsRuleset ═══════════════════════

    /// @dev The outcome views revert. state() consults them ONLY in its deadline-passed branch
    ///      (Governor.state, OZ v5.6.1): so the proposal is queryable (Pending, then Active) up
    ///      to the deadline, and state() begins reverting only AFTER it. Queue/execute become
    ///      impossible for this proposal (both route through state()), while the governor's own
    ///      bookkeeping views keep answering. Other types stay fully functional.
    function test_revertingViewsRuleset_stateRevertsOnlyAfterDeadline() public {
        RevertingViewsRuleset rv = new RevertingViewsRuleset(address(governor));
        uint8 badType = _registerType(rv, 0, "register reverting-views ruleset");

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _boxCall(1, "poisoned views proposal");
        vm.prank(alice);
        uint256 id = governor.proposeWithType(t, v, c, "poisoned views proposal", badType);

        // PROBE: before the snapshot the proposal is Pending — state() does NOT reach the views.
        assertEq(uint8(_stateOf(id)), uint8(IGovernor.ProposalState.Pending));

        // In the active window state() still resolves (deadline branch not yet taken).
        vm.roll(governor.proposalSnapshot(id) + 1);
        assertEq(uint8(_stateOf(id)), uint8(IGovernor.ProposalState.Active));

        // PIN: only after the deadline does state() reach _quorumReached and revert.
        _rollPastDeadline(id);
        vm.expectRevert(RevertingViewsRuleset.ViewPoisoned.selector);
        governor.state(id);

        // Consequently queue (routes through _validateStateBitmap → state()) is impossible.
        vm.expectRevert(RevertingViewsRuleset.ViewPoisoned.selector);
        governor.queue(t, v, c, h);

        // But the governor's own bookkeeping views still answer for the poisoned proposal.
        assertGt(governor.proposalSnapshot(id), 0);
        assertGt(governor.proposalDeadline(id), 0);
        assertEq(governor.proposalProposer(id), alice);
        assertEq(governor.proposalType(id), badType);

        // Containment: a type-0 proposal remains fully functional through execution.
        (uint256 victimId, address[] memory vt, uint256[] memory vv, bytes[] memory vc, bytes32 vh) =
            _proposeActiveBox(55, "views victim proposal", 0);
        _vote(victimId, alice, 1);
        _rollPastDeadline(victimId);
        _queueAndExecute(vt, vv, vc, vh);
        assertEq(box.value(), 55);
        assertEq(uint8(_stateOf(victimId)), uint8(IGovernor.ProposalState.Executed));
    }

    // ═══════════════════════ WeightInflatingRuleset ═══════════════════════

    /// @dev countVote returns weight * 1000. Per OZ `_castVote` (v5.6.1) the returned weight
    ///      feeds ONLY the VoteCast event's weight field and castVote's return value. It cannot
    ///      touch checkpointed voting power or any OTHER ruleset's quorum math. The inflating
    ///      ruleset even tallies the true weight internally — only the reported number lies.
    function test_weightInflatingRuleset_returnValueBlastRadiusIsLimited() public {
        WeightInflatingRuleset wi = new WeightInflatingRuleset(address(governor));
        uint8 badType = _registerType(wi, 0, "register weight-inflating ruleset");

        (uint256 id,,,,) = _proposeActiveBox(1, "inflating proposal", badType);
        uint256 snapshot = governor.proposalSnapshot(id);
        uint256 trueWeight = token.getPastVotes(alice, snapshot);
        uint256 inflated = trueWeight * wi.INFLATION();

        // The VoteCast event carries the inflated weight...
        vm.expectEmit(true, false, false, true, address(governor));
        emit VoteCast(alice, id, 1, inflated, "");
        vm.prank(alice);
        uint256 returned = governor.castVote(id, 1);

        // ...and so does castVote's return — that is the entire blast radius.
        assertEq(returned, inflated);

        // Checkpointed voting power is untouched: the token never saw the inflated number.
        assertEq(token.getPastVotes(alice, snapshot), trueWeight);
        assertEq(token.getVotes(alice), trueWeight);

        // A type-0 proposal's quorum math (its own StandardRuleset) is computed independently
        // and is unaffected: the victim resolves on real weights and executes.
        (uint256 victimId, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _proposeActiveBox(88, "inflation victim proposal", 0);
        _vote(victimId, alice, 1);
        assertTrue(standardRuleset.quorumReached(victimId));
        _rollPastDeadline(victimId);
        _queueAndExecute(t, v, c, h);
        assertEq(box.value(), 88);
    }

    // ═══════════════════════ ReentrantRuleset ═══════════════════════

    /// @dev countVote re-enters an onlyGovernance setter. The reentry's msg.sender is the
    ///      ruleset, not the timelock executor, so _checkGovernance rejects it with
    ///      GovernorOnlyExecutor — reentrancy cannot reach governance-only surface. The outer
    ///      vote still tallies, and the type table is uncorrupted (type 0 stays active).
    function test_reentrantRuleset_cannotReachOnlyGovernanceSurface() public {
        ReentrantRuleset rr = new ReentrantRuleset(address(governor), ReentrantRuleset.Reentry.CallGovernance, 0);
        uint8 badType = _registerType(rr, 0, "register reentrant-governance ruleset");

        (uint256 id,,,,) = _proposeActiveBox(1, "reentrant governance proposal", badType);
        _vote(id, alice, 1); // triggers the reentry inside countVote

        // The reentrant onlyGovernance call was rejected with GovernorOnlyExecutor(ruleset).
        assertEq(
            rr.governanceReentryRevert(), abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(rr))
        );

        // Core invariants intact: type 0 still active, and the outer vote counted normally.
        assertTrue(governor.getTypeConfig(0).active);
        assertTrue(rr.hasVoted(id, alice));
        assertTrue(rr.quorumReached(id));
    }

    /// @dev countVote opens a fresh proposal mid-tally. The reentrant propose succeeds as an
    ///      ordinary proposal (proposer = ruleset), but cannot corrupt the outer castVote:
    ///      OZ freezes totalWeight from the snapshot BEFORE calling countVote, so the outer
    ///      vote still returns the honest weight and the type table is unchanged.
    function test_reentrantRuleset_reentrantProposeCannotCorruptOuterAccounting() public {
        // A zero-threshold StandardRuleset type the (zero-vote) reentrant ruleset can propose on.
        StandardRuleset openType = _newRuleset();
        uint8 openTypeId = _registerType(openType, 0, "register zero-threshold type");

        ReentrantRuleset rr = new ReentrantRuleset(address(governor), ReentrantRuleset.Reentry.Propose, openTypeId);
        uint8 badType = _registerType(rr, 0, "register reentrant-propose ruleset");
        assertEq(governor.typeCount(), 3); // bootstrap + open + reentrant

        (uint256 outerId,,,,) = _proposeActiveBox(1, "reentrant propose proposal", badType);
        uint256 snapshot = governor.proposalSnapshot(outerId);
        uint256 expectedWeight = token.getPastVotes(alice, snapshot);

        vm.prank(alice);
        uint256 returned = governor.castVote(outerId, 1);

        // Outer accounting is honest: weight frozen from the snapshot, not disturbed by reentry.
        assertEq(returned, expectedWeight);
        assertTrue(rr.hasVoted(outerId, alice));

        // A real proposal was minted by the reentry, proposed BY the ruleset, pinned to openType.
        uint256 reentrantId = rr.reentrantProposalId();
        assertGt(reentrantId, 0);
        assertGt(governor.proposalSnapshot(reentrantId), 0);
        assertEq(governor.proposalProposer(reentrantId), address(rr));
        assertEq(governor.proposalType(reentrantId), openTypeId);

        // The registry was not corrupted by the reentry: no new type appeared.
        assertEq(governor.typeCount(), 3);
    }

    // ═══════════════════════ Registry hardening (attack angle) ═══════════════════════

    /// @dev A ruleset that lies about ERC165 (advertises IERC165 but not IRuleset) cannot be
    ///      registered — registration reverts inside governance execution. The full matrix
    ///      (EOA, non-165 contract, address(0), unauthorized caller) is exhaustively covered in
    ///      GovernorNexus.registry.t.sol; this is the consolidated attack-angle assertion and
    ///      deliberately does not duplicate that suite.
    function test_registry_rejectsRulesetLyingAboutInterface() public {
        FakeInterfaceRuleset fake = new FakeInterfaceRuleset();
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _prepareSelfCall(
            abi.encodeCall(
                GovernorNexus.registerType, (IRuleset(address(fake)), VOTING_DELAY, VOTING_PERIOD, uint256(0))
            ),
            "register interface liar"
        );
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.RulesetInterfaceUnsupported.selector, address(fake)));
        governor.execute(t, v, c, h);
    }

    // ═══════════════════════ In-flight proposals survive registry ops ═══════════════════════

    /// @dev Deactivating a type does NOT touch its in-flight proposals: the pin is what governs
    ///      counting, `active` gates NEW proposals only. An in-flight type-1 proposal completes
    ///      its full lifecycle (counted through its pinned ruleset) after deactivation, while
    ///      new proposals on type 1 revert; reactivation restores them.
    function test_deactivation_doesNotTouchInFlightProposal() public {
        StandardRuleset rs1 = _newRuleset();
        uint8 type1 = _registerType(rs1, PROPOSAL_THRESHOLD, "register type 1");

        // In-flight proposal on type 1, voted while active.
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _proposeActiveBox(21, "in-flight type-1 proposal", type1);
        _vote(id, alice, 1);
        assertTrue(rs1.hasVoted(id, alice));

        // Deactivate type 1 mid-flight.
        _executeSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (type1, false)), "deactivate type 1");
        assertFalse(governor.getTypeConfig(type1).active);

        // The in-flight proposal still completes: counted via its pinned (type-1) ruleset.
        _rollPastDeadline(id);
        assertEq(uint8(_stateOf(id)), uint8(IGovernor.ProposalState.Succeeded));
        _queueAndExecute(t, v, c, h);
        assertEq(box.value(), 21);

        // NEW proposals on the deactivated type revert.
        (address[] memory nt, uint256[] memory nv, bytes[] memory nc,) = _boxCall(1, "new on inactive type 1");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.TypeInactive.selector, type1));
        governor.proposeWithType(nt, nv, nc, "new on inactive type 1", type1);

        // Reactivation restores new proposals on type 1.
        _executeSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (type1, true)), "reactivate type 1");
        vm.prank(alice);
        uint256 reactivatedId = governor.proposeWithType(nt, nv, nc, "new on inactive type 1", type1);
        assertEq(governor.proposalType(reactivatedId), type1);
    }

    /// @dev Moving the default pointer does NOT touch in-flight proposals: a proposal created
    ///      through the stock door under default type 0 keeps counting via type 0's ruleset
    ///      after the default moves to type 1, while NEW stock-door proposals pin type 1.
    function test_defaultPointerMove_doesNotTouchInFlightProposal() public {
        StandardRuleset rs1 = _newRuleset();
        uint8 type1 = _registerType(rs1, PROPOSAL_THRESHOLD, "register type 1");

        // In-flight proposal through the stock door → pinned to the current default (type 0).
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _boxCall(33, "in-flight default proposal");
        vm.prank(alice);
        uint256 id = governor.propose(t, v, c, "in-flight default proposal");
        assertEq(governor.proposalType(id), 0);
        vm.roll(governor.proposalSnapshot(id) + 1);
        _vote(id, alice, 1);

        // Move the default pointer to type 1 mid-flight.
        _executeSelfCall(abi.encodeCall(GovernorNexus.setDefaultType, (type1)), "move default to type 1");
        assertEq(governor.defaultTypeId(), type1);

        // The in-flight proposal still counts via type 0's ruleset — the pin is immutable.
        assertEq(governor.proposalType(id), 0);
        assertEq(address(governor.proposalRuleset(id)), address(standardRuleset));
        assertTrue(standardRuleset.hasVoted(id, alice));
        assertFalse(rs1.hasVoted(id, alice));

        // And it completes its lifecycle counted through type 0.
        _rollPastDeadline(id);
        assertEq(uint8(_stateOf(id)), uint8(IGovernor.ProposalState.Succeeded));
        _queueAndExecute(t, v, c, h);
        assertEq(box.value(), 33);

        // A NEW stock-door proposal now pins type 1 (the new default).
        (address[] memory nt, uint256[] memory nv, bytes[] memory nc,) = _boxCall(44, "new default proposal");
        vm.prank(alice);
        uint256 newId = governor.propose(nt, nv, nc, "new default proposal");
        assertEq(governor.proposalType(newId), type1);
        assertEq(address(governor.proposalRuleset(newId)), address(rs1));
    }
}
