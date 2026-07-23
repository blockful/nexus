// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {BondRuleset} from "../src/BondRuleset.sol";
import {BondRulesetTestBase} from "./BondRulesetTestBase.sol";

/// @dev Integration suite for `resolveBond` against the real `GovernorNexus` + timelock —
///      the spam-slash predicate (a defeated proposal forfeits its bond when the vote judges it
///      spam), the terminal-states-only guard, and the proposer-exclusion carve-out, each
///      exercised end to end through the actual propose → vote → queue/execute/cancel lifecycle
///      rather than a mocked governor.
contract GovernorNexusBondTest is BondRulesetTestBase {
    function test_endToEnd_permissionlessPropose_zeroVP() public {
        (uint256 id,,,,) = _proposeBonded("bonded");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
        (address proposer, uint96 amount,) = bondRuleset.bondOf(id);
        assertEq(proposer, bob);
        assertEq(amount, BOND_AMOUNT);
    }

    function test_resolve_executed_refunds() public {
        // alice (2M ENS) already funded by base fixture
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("passes");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);
        governor.queue(t, v, c, h);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(t, v, c, h);

        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
        (,, bool settled) = bondRuleset.bondOf(id);
        assertTrue(settled);
    }

    function test_resolve_defeated_slashWins_forfeits() public {
        address slasher = makeAddr("slasher");
        _fund(slasher, 500_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("slashed");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain)); // quorum without approval
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));

        uint256 before = token.balanceOf(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit BondRuleset.BondSlashed(id, BOND_AMOUNT, BondRuleset.SlashReason.SlashVote);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT);
    }

    function test_resolve_defeated_plainNoMajority_refunds() public {
        // Against 500k > Slash 100k → second clause fails → refund despite defeat
        address noVoter = makeAddr("noVoter");
        address slasher = makeAddr("slasher");
        _fund(noVoter, 500_000e18);
        _fund(slasher, 100_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("defeated not slashed");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(noVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);

        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    /// @dev Corrected from the brief's original draft ("quorumFailOnly_refunds"): with only
    ///      `AgainstAndSlash 100k` cast (For 0, Against 0), BOTH slash clauses hold — rejections
    ///      100k > For 0, and Slash 100k > Against 0 — so this genuinely forfeits. The quorum-
    ///      fail carve-out is about approvals ≥ rejections, which is not this shape.
    function test_resolve_defeated_quorumFailOnly_slashLeads_forfeits() public {
        address slasher = makeAddr("slasher");
        _fund(slasher, 100_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("quorum fail");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));

        uint256 before = token.balanceOf(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit BondRuleset.BondSlashed(id, BOND_AMOUNT, BondRuleset.SlashReason.SlashVote);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT);
    }

    /// @dev The true quorum-fail carve-out: a tiny For vote below quorum defeats the
    ///      proposal, but clause 1 (rejections > For) is false, so it refunds.
    function test_resolve_defeated_quorumFail_forVotesLead_refunds() public {
        address forVoter = makeAddr("forVoter");
        _fund(forVoter, 1e18); // way below 1% quorum of ~2M supply
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("quorum fail, for leads");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated)); // quorum missed
        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT); // clause 1 false → refund
    }

    // ─────────────────────── Proposer-exclusion tests ───────────────────────

    function test_resolve_proposerPlainNoDilution_excluded_slashes() public {
        // Community: Slash 200k. Proposer dumps plain-No 300k to force No > Slash.
        // Exclusion removes the proposer's 300k → Slash 200k > No 0 → forfeit.
        address slasher = makeAddr("slasher");
        _fund(slasher, 200_000e18);
        _fund(bob, 300_000e18); // bob now HAS voting power for this test
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("dilution attempt");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.prank(bob);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against)); // the proposer-exclusion move
        vm.roll(governor.proposalDeadline(id) + 1);

        uint256 before = token.balanceOf(address(timelock));
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT); // slashed anyway
    }

    function test_resolve_proposerSlashVote_alsoExcluded() public {
        // Only the proposer voted AgainstAndSlash (weird but possible): excluded → 0 > 0 false → refund
        _fund(bob, 300_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("self slash");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(bob);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    // ─────────────────────────────── Guard tests ───────────────────────────────

    function test_resolve_revertsWhileLive() public {
        (uint256 id,,,,) = _proposeBonded("live");
        vm.expectRevert(
            abi.encodeWithSelector(BondRuleset.BondNotResolvable.selector, id, IGovernor.ProposalState.Pending)
        );
        bondRuleset.resolveBond(id);
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(BondRuleset.BondNotResolvable.selector, id, IGovernor.ProposalState.Active)
        );
        bondRuleset.resolveBond(id);
    }

    function test_resolve_revertsWhileQueued() public {
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("queued");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);
        governor.queue(t, v, c, h);
        vm.expectRevert(
            abi.encodeWithSelector(BondRuleset.BondNotResolvable.selector, id, IGovernor.ProposalState.Queued)
        );
        bondRuleset.resolveBond(id); // veto window open — no early refund
    }

    function test_resolve_replayReverts() public {
        address slasher = makeAddr("slasher");
        _fund(slasher, 500_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("replay");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);

        bondRuleset.resolveBond(id); // settles (forfeit)
        vm.expectRevert(abi.encodeWithSelector(BondRuleset.BondAlreadySettled.selector, id));
        bondRuleset.resolveBond(id);
    }

    function test_resolve_noBondReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BondRuleset.NoBond.selector, uint256(123)));
        bondRuleset.resolveBond(123);
    }

    // ─────────────────────── Cancel-partition tests ───────────────────────

    function test_cancel_pending_refunds() public {
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("pending cancel");
        vm.prank(bob);
        governor.cancel(t, v, c, h); // still Pending
        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    function test_cancel_active_forfeitsInFull() public {
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("active cancel");
        vm.roll(governor.proposalSnapshot(id) + 1); // Active
        vm.prank(bob);
        governor.cancel(t, v, c, h);
        uint256 before = token.balanceOf(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit BondRuleset.BondSlashed(id, BOND_AMOUNT, BondRuleset.SlashReason.ActiveSelfCancel);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT);
    }

    function test_timelockVeto_forfeits_canceledAtZero() public {
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("vetoed");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);
        governor.queue(t, v, c, h);

        // Security-council veto: cancel directly on the timelock (GovernorTimelockControl salt).
        bytes32 salt = bytes20(address(governor)) ^ h;
        bytes32 opId = timelock.hashOperationBatch(t, v, c, 0, salt);
        vm.prank(council);
        timelock.cancel(opId);

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
        assertEq(governor.proposalCanceledAt(id), 0); // never canceled via the governor

        uint256 before = token.balanceOf(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit BondRuleset.BondSlashed(id, BOND_AMOUNT, BondRuleset.SlashReason.TimelockVeto);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT);
    }

    function test_thirdPartyCancel_impossible_zeroThresholdLine() public {
        // bond line has proposalThreshold = 0 → permissionless-cancel clause never fires.
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("griefing target");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(eoa); // bob has zero VP — under a thresholded line ANYONE could cancel
        vm.expectRevert(); // GovernorUnableToCancel
        governor.cancel(t, v, c, h);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));
    }

    // ─────────────────── Cross-mechanism interaction tests ───────────────────

    /// @dev Batch voting against bond proposals: one call casts AgainstAndSlash on
    ///      one proposal and For on another — each bucket lands on its own proposal only.
    function test_interaction_batchVote_supportThree() public {
        address slasher = makeAddr("slasher");
        _fund(slasher, 200_000e18);
        vm.roll(block.number + 1);
        (uint256 id1,,,,) = _proposeBonded("batch one");
        (uint256 id2,,,,) = _proposeBonded("batch two");
        vm.roll(governor.proposalSnapshot(id2) + 1);

        uint256[] memory pids = new uint256[](2);
        pids[0] = id1;
        pids[1] = id2;
        uint8[] memory supportValues = new uint8[](2);
        supportValues[0] = uint8(BondRuleset.VoteType.AgainstAndSlash);
        supportValues[1] = uint8(BondRuleset.VoteType.For);
        string[] memory reasons = new string[](2);
        bytes[] memory params = new bytes[](2);

        vm.prank(slasher);
        governor.castVoteWithReasonAndParamsBatch(pids, supportValues, reasons, params);

        (,,, uint256 slash1) = bondRuleset.proposalVotes(id1);
        (, uint256 for2,,) = bondRuleset.proposalVotes(id2);
        assertEq(slash1, 200_000e18);
        assertEq(for2, 200_000e18);
    }

    /// @dev Mutable re-vote (RulesetCounting semantics) against a bond proposal: a
    ///      voter that flips from AgainstAndSlash to For fully drains the slash bucket —
    ///      the old vote does not linger as residue.
    function test_interaction_revote_drainsSlashBucket() public {
        address swinger = makeAddr("swinger");
        _fund(swinger, 200_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("revote");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.startPrank(swinger);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        governor.castVote(id, uint8(BondRuleset.VoteType.For)); // replace — slash bucket back to 0
        vm.stopPrank();
        (,,, uint256 slash) = bondRuleset.proposalVotes(id);
        assertEq(slash, 0);
    }

    /// @dev Late-flip anti-snipe extension against a bond proposal, proving the
    ///      mechanism is type-agnostic (the late-flip extension applies to every proposal type).
    ///      Mirrors the proven trigger from
    ///      `GovernorNexus.lateFlip.t.sol`: the pre-count observation inside the final
    ///      `extensionWindow` sees the still-failing tally (alice's earlier Against, not yet
    ///      overtaken by the flipper's own vote) and arms `FailingObserved`; the assertion
    ///      is read only after rolling past the original deadline, since the deadline view
    ///      promises nothing pre-deadline (`test_deadlineViewUnchangedBeforeOriginalDeadline`).
    function test_interaction_lateFlip_extendsBondProposal() public {
        // failing → passing inside the window must extend (the late-flip extension applies to every proposal type)
        address flipper = makeAddr("flipper");
        _fund(flipper, 2_500_000e18); // outweighs alice
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("late flip");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against)); // failing
        uint256 originalDeadline = governor.proposalDeadline(id);
        vm.roll(originalDeadline - 5); // inside EXTENSION_WINDOW (20 blocks)
        vm.prank(flipper);
        governor.castVote(id, uint8(BondRuleset.VoteType.For)); // flip to passing
        vm.roll(originalDeadline + 1); // past the original deadline: extension is decided by now
        assertGt(governor.proposalDeadline(id), originalDeadline);
    }
}
