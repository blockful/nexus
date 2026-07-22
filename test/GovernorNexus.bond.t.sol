// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {BondRuleset} from "../src/BondRuleset.sol";
import {BondRulesetTestBase} from "./BondRulesetTestBase.sol";

/// @dev Integration suite for `resolveBond` against the real `GovernorNexus` + timelock —
///      the EP 5.15 predicate (D56), the terminal-states-only guard (D61), and the
///      proposer-exclusion carve-out (F3), each exercised end to end through the actual
///      propose → vote → queue/execute/cancel lifecycle rather than a mocked governor.
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
    ///      `AgainstAndSlash 100k` cast (For 0, Against 0), BOTH D56 clauses hold — rejections
    ///      100k > For 0, and Slash 100k > Against 0 — so this genuinely forfeits. The quorum-
    ///      fail carve-out in D56 is about approvals ≥ rejections, which is not this shape.
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

    // ─────────────────────── Proposer-exclusion tests (F3) ───────────────────────

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
        governor.castVote(id, uint8(BondRuleset.VoteType.Against)); // the F3 move
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
}
