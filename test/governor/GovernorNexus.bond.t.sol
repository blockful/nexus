// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {BondRuleset} from "../../src/rulesets/BondRuleset.sol";
import {BondRulesetTestBase} from "../rulesets/BondRulesetTestBase.sol";

/// @dev Integration suite for `resolveBond` against the real `GovernorNexus` + timelock —
///      the ratified spam-slash predicate (EP 5.15 verbatim: combined rejections strictly
///      beat For AND slash-weight strictly beats plain Against) and the Pending/Active-only
///      guard, each exercised end to end through the actual propose → vote → queue/execute/
///      cancel lifecycle rather than a mocked governor.
contract GovernorNexusBondTest is BondRulesetTestBase {
    function test_endToEnd_permissionlessPropose_zeroVP() public {
        (uint256 id,,,,) = _proposeBonded("bonded");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
        (address proposer,) = bondRuleset.bondOf(id);
        assertEq(proposer, bob);
        assertEq(bondRuleset.bondAmount(), BOND_AMOUNT); // every bond holds exactly bondAmount
    }

    /// @dev The bond keys on the id the GOVERNOR computed (passed through
    ///      `IProposalValidator.validateProposal`), never a ruleset-side re-derivation —
    ///      pinned by matching the bond record against `hashProposal` for the same content.
    function test_bondKeyedByGovernorCanonicalId() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _proposeBonded("canonical");
        assertEq(id, governor.hashProposal(t, v, c, h));
        (address proposer,) = bondRuleset.bondOf(governor.hashProposal(t, v, c, h));
        assertEq(proposer, bob);
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
        (, bool settled) = bondRuleset.bondOf(id);
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
        // Against 500k > Slash 100k → slash does not beat plain rejection → refund despite defeat
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
    ///      proposal, but the (empty) rejections don't beat For, so it refunds.
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
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT); // rejections 0 ≯ For → refund
    }

    /// @dev Legitimate proposal that missed quorum with real support: For outweighs a smaller
    ///      slash vote → refund.
    function test_resolve_defeated_quorumFail_forOutweighsSlash_refunds() public {
        address forVoter = makeAddr("forVoter");
        address slasher = makeAddr("slasher");
        _fund(forVoter, 2e18); // both way below 1% quorum
        _fund(slasher, 1e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("quorum fail, supported");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    // ─────────────── Ratified predicate (EP 5.15) boundary tests ───────────────

    /// @dev A proposer defending with real voting weight via plain Against is legitimate
    ///      defense — the ratified rule reads raw buckets, and the per-address exclusion an
    ///      earlier revision layered on top was sybil-bypassable anyway: Against 300k >
    ///      Slash 200k kills the second clause → refund.
    function test_resolve_proposerAgainstDefense_realWeight_refunds() public {
        address slasher = makeAddr("slasher");
        _fund(slasher, 200_000e18);
        _fund(bob, 300_000e18); // bob now HAS voting power for this test
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("against defense");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.prank(bob);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against));
        vm.roll(governor.proposalDeadline(id) + 1);

        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT); // slash is not the plurality
    }

    /// @dev Raw tallies, no per-address carve-out: a proposer voting AgainstAndSlash on
    ///      their own proposal counts like anyone else's slash weight → forfeit.
    function test_resolve_proposerSelfSlash_rawTally_slashes() public {
        _fund(bob, 300_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("self slash");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(bob);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        uint256 before = token.balanceOf(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit BondRuleset.BondSlashed(id, BOND_AMOUNT, BondRuleset.SlashReason.SlashVote);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT);
    }

    /// @dev Mass plain rejection is not a confiscation mandate: Against 900k dwarfs a small
    ///      slash vote that nonetheless beats For → refund.
    function test_resolve_massAgainst_smallSlashBeatsFor_refunds() public {
        address noVoter = makeAddr("noVoter");
        address slasher = makeAddr("slasher");
        address forVoter = makeAddr("forVoter");
        _fund(noVoter, 900_000e18);
        _fund(slasher, 50_000e18);
        _fund(forVoter, 10_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("mass rejection");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(noVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));

        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    /// @dev "Rejected" must be STRICT (EP 5.15: "rejections bigger than approvals"): with no
    ///      Against votes, slash tied with For means rejections tied with For → refund.
    function test_resolve_tieSlashFor_refunds() public {
        address forVoter = makeAddr("forVoter");
        address slasher = makeAddr("slasher");
        _fund(forVoter, 100_000e18);
        _fund(slasher, 100_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("tie slash-for");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated)); // tie ≠ success
        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    /// @dev The penalty clause must be STRICT: slash tied with Against refunds.
    function test_resolve_tieSlashAgainst_refunds() public {
        address noVoter = makeAddr("noVoter");
        address slasher = makeAddr("slasher");
        _fund(noVoter, 100_000e18);
        _fund(slasher, 100_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("tie slash-against");
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

    /// @dev EP 5.15 counts REJECTIONS, not the slash bucket alone, against For: slash tied
    ///      with For still forfeits when plain Against pushes the combined rejections over.
    ///      (F=100k, A=50k, S=100k → rejections 150k > 100k ∧ slash 100k > 50k.)
    function test_resolve_tieSlashFor_withAgainst_slashes() public {
        address forVoter = makeAddr("forVoter");
        address noVoter = makeAddr("noVoter");
        address slasher = makeAddr("slasher");
        _fund(forVoter, 100_000e18);
        _fund(noVoter, 50_000e18);
        _fund(slasher, 100_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("tie slash-for, against present");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.prank(noVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against));
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

    /// @dev Rejections exactly tied with For never slash, even with slash leading Against:
    ///      the defeat clause is strict. (F=100k, A=30k, S=70k → rejections 100k ≯ 100k.)
    function test_resolve_tieRejectionsFor_slashLeadsAgainst_refunds() public {
        address forVoter = makeAddr("forVoter");
        address noVoter = makeAddr("noVoter");
        address slasher = makeAddr("slasher");
        _fund(forVoter, 100_000e18);
        _fund(noVoter, 30_000e18);
        _fund(slasher, 70_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("rejections tie for");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.prank(noVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated)); // tie ≠ success

        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    /// @dev The ratified rule forfeits when the proposal is rejected and slash leads plain
    ///      Against, even though slash alone does not beat For. (F=100k, A=60k, S=70k →
    ///      rejections 130k > 100k ∧ slash 70k > 60k.)
    function test_resolve_rejectedSlashLeadsAgainst_slashBelowFor_slashes() public {
        address forVoter = makeAddr("forVoter");
        address noVoter = makeAddr("noVoter");
        address slasher = makeAddr("slasher");
        _fund(forVoter, 100_000e18);
        _fund(noVoter, 60_000e18);
        _fund(slasher, 70_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("rejected, slash leads against");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.prank(noVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against));
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

    /// @dev Slash strictly above BOTH expressive buckets → forfeit.
    function test_resolve_strictPluralityOverBoth_slashes() public {
        address forVoter = makeAddr("forVoter");
        address noVoter = makeAddr("noVoter");
        address slasher = makeAddr("slasher");
        _fund(forVoter, 100_000e18);
        _fund(noVoter, 100_000e18);
        _fund(slasher, 150_000e18);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("strict plurality");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.Abstain));
        vm.prank(forVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.prank(noVoter);
        governor.castVote(id, uint8(BondRuleset.VoteType.Against));
        vm.prank(slasher);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);

        uint256 before = token.balanceOf(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit BondRuleset.BondSlashed(id, BOND_AMOUNT, BondRuleset.SlashReason.SlashVote);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT);
    }

    /// @dev ACCEPTED RESIDUAL (see README): at zero turnout a single wei of slash weight
    ///      satisfies both clauses and confiscates. The defense is attracting any single vote in
    ///      either expressive bucket; a participation floor was deliberately rejected so a
    ///      sybil spam wave can be slashed proposal-by-proposal without gathering quorum each time.
    function test_resolve_zeroTurnout_oneWeiSlash_slashes_acceptedResidual() public {
        address griefer = makeAddr("griefer");
        _fund(griefer, 1);
        vm.roll(block.number + 1);
        (uint256 id,,,,) = _proposeBonded("zero turnout");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(griefer);
        governor.castVote(id, uint8(BondRuleset.VoteType.AgainstAndSlash));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));

        uint256 before = token.balanceOf(address(timelock));
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), before + BOND_AMOUNT);
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

    function test_resolve_refundsWhileQueued() public {
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

        uint256 before = token.balanceOf(bob);
        vm.expectEmit(true, true, false, true);
        emit BondRuleset.BondRefunded(id, bob, BOND_AMOUNT);
        bondRuleset.resolveBond(id); // veto window still open — early refund is the accepted trade-off
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
        (, bool settled) = bondRuleset.bondOf(id);
        assertTrue(settled);
    }

    function test_resolve_refundsWhileSucceeded() public {
        (uint256 id,,,,) = _proposeBonded("succeeded refund");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        uint256 before = token.balanceOf(bob);
        vm.expectEmit(true, true, false, true);
        emit BondRuleset.BondRefunded(id, bob, BOND_AMOUNT);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    /// @dev Anyone may trigger the early refund; funds always go to the proposer.
    function test_resolve_thirdPartyTriggersEarlyRefund_fundsGoToProposer() public {
        (uint256 id,,,,) = _proposeBonded("stranger settles");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);

        uint256 strangerBefore = token.balanceOf(eoa);
        uint256 proposerBefore = token.balanceOf(bob);
        vm.prank(eoa);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), proposerBefore + BOND_AMOUNT);
        assertEq(token.balanceOf(eoa), strangerBefore);
    }

    /// @dev Early settle at Succeeded, then the proposal queues and executes normally —
    ///      resolution replay reverts, no double payout.
    function test_resolve_earlySettleThenExecute_replayReverts() public {
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("settle then execute");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);

        bondRuleset.resolveBond(id); // refund at Succeeded

        governor.queue(t, v, c, h);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(t, v, c, h); // lifecycle unaffected by the settled bond
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));

        vm.expectRevert(abi.encodeWithSelector(BondRuleset.BondAlreadySettled.selector, id));
        bondRuleset.resolveBond(id);
    }

    /// @dev The accepted trade-off, pinned: bond settled while Queued, council vetoes
    ///      after — the forfeit is unreachable (replay reverts), the veto itself still lands.
    function test_resolve_earlySettleThenVeto_noForfeit() public {
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("settle then veto");
        vm.roll(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, uint8(BondRuleset.VoteType.For));
        vm.roll(governor.proposalDeadline(id) + 1);
        governor.queue(t, v, c, h);

        bondRuleset.resolveBond(id); // refund at Queued, before the veto

        bytes32 salt = bytes20(address(governor)) ^ h;
        bytes32 opId = timelock.hashOperationBatch(t, v, c, 0, salt);
        vm.prank(council);
        timelock.cancel(opId);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
        assertEq(governor.proposalCanceledAt(id), 0);

        uint256 treasuryBefore = token.balanceOf(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(BondRuleset.BondAlreadySettled.selector, id));
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(address(timelock)), treasuryBefore); // forfeit never happens
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
        vm.roll(block.number + 1); // clock == snapshot: still Pending, past the propose block
        vm.prank(bob);
        governor.cancel(t, v, c, h); // canceledAt == snapshot → the Pending-refund boundary
        uint256 before = token.balanceOf(bob);
        bondRuleset.resolveBond(id);
        assertEq(token.balanceOf(bob), before + BOND_AMOUNT);
    }

    /// @dev Pins that the atomic propose→cancel(→resolve) round-trip — which would let a
    ///      flash-borrowed bond enter and leave custody inside one transaction — is denied at
    ///      the cancel step, so the bond provably survives the propose block in custody.
    function test_cancel_sameBlockAsPropose_denied_bondStaysLocked() public {
        address[] memory t;
        uint256[] memory v;
        bytes[] memory c;
        bytes32 h;
        uint256 id;
        (id, t, v, c, h) = _proposeBonded("atomic round-trip");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, bob));
        governor.cancel(t, v, c, h);

        (, bool settled) = bondRuleset.bondOf(id);
        assertFalse(settled);
        vm.expectRevert(
            abi.encodeWithSelector(BondRuleset.BondNotResolvable.selector, id, IGovernor.ProposalState.Pending)
        );
        bondRuleset.resolveBond(id);
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
