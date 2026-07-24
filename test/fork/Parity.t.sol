// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {ENSParams} from "../../src/ENSParams.sol";
import {StandardRuleset} from "../../src/StandardRuleset.sol";
import {Box, BaseTest} from "./Base.t.sol";
import {IGov} from "./IGov.sol";

/// @dev Behavioral parity: the stock v5 scaffold must be observationally equivalent to
///      the live ENS governor for configuration, proposal identity, and the full
///      propose → vote → queue → execute lifecycle. Divergences that are inherent to
///      the OZ v4 → v5 upgrade are pinned in the Divergences contract below so they
///      stay documented and intentional.
contract ParityTest is BaseTest {
    // ─────────────────────────── Configuration ───────────────────────────

    function test_parity_configuration() public view {
        assertEq(scaffoldGov.name(), liveGov.name());
        assertEq(scaffoldGov.votingDelay(), liveGov.votingDelay());
        assertEq(scaffoldGov.votingPeriod(), liveGov.votingPeriod());
        assertEq(scaffoldGov.proposalThreshold(), liveGov.proposalThreshold());
        assertEq(scaffoldGov.COUNTING_MODE(), liveGov.COUNTING_MODE());
        assertEq(scaffoldGov.token(), liveGov.token());
        assertEq(scaffoldGov.timelock(), liveGov.timelock());
    }

    /// @dev The governor's clock is sourced from the token: v5 `GovernorVotes.clock()` adopts
    ///      `token().clock()` and only falls back to block-number when the token predates
    ///      ERC-6372. The live ENS token is old `ERC20Votes` with no clock, so the scaffold
    ///      resolves to block-number — which is what makes the block-denominated VOTING_DELAY
    ///      / VOTING_PERIOD mean blocks. If a future token swap/upgrade ever flipped the clock
    ///      to timestamp mode, `45_818` would silently become ~12.7h instead of ~1 week; this
    ///      assertion turns that regression red. (Live gov predates ERC-6372, so this is a
    ///      scaffold-side invariant, not an A/B assertion.)
    function test_scaffold_clockIsBlockNumber() public view {
        assertEq(scaffold.CLOCK_MODE(), "mode=blocknumber&from=default");
        assertEq(uint256(scaffold.clock()), block.number);
    }

    function test_parity_quorum() public {
        // The type-0 StandardRuleset holds an IMMUTABLE numerator with NO checkpoint history,
        // so quorum() answers any timepoint directly — like the live v4 governor. The roll to
        // FORK_BLOCK + 1 is still required (not for checkpoints): quorum() reads
        // getPastTotalSupply(FORK_BLOCK), which reverts as a future lookup until the chain has
        // advanced past FORK_BLOCK — an ERC-5805 constraint that binds both sides identically.
        vm.roll(FORK_BLOCK + 1);
        assertEq(scaffoldGov.quorum(FORK_BLOCK), liveGov.quorum(FORK_BLOCK));
        assertGt(scaffoldGov.quorum(FORK_BLOCK), 0);
    }

    function test_parity_votingPowerReads() public view {
        assertEq(scaffoldGov.getVotes(WHALE, FORK_BLOCK - 1), liveGov.getVotes(WHALE, FORK_BLOCK - 1));
    }

    // ─────────────────────────── Proposal identity ───────────────────────────

    function test_parity_proposalIdHashing() public view {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _actions(liveBox, 1);
        bytes32 dh = keccak256(bytes("same actions, same id"));
        assertEq(scaffoldGov.hashProposal(t, v, c, dh), liveGov.hashProposal(t, v, c, dh));
    }

    // ─────────────────────────── Lifecycle ───────────────────────────

    /// @dev Runs the same proposal shape through both governors and compares every
    ///      observable step: snapshot/deadline offsets, vote weight, state transitions,
    ///      timelock eta, and execution effect.
    function test_parity_fullLifecycle() public {
        uint256 proposedAt = block.number;
        uint256 liveId = _propose(liveGov, liveBox, 42, "parity");
        uint256 scaffoldId = _propose(scaffoldGov, scaffoldBox, 42, "parity");

        assertEq(uint8(liveGov.state(liveId)), uint8(IGovernor.ProposalState.Pending));
        assertEq(scaffoldGov.state(scaffoldId), liveGov.state(liveId));

        assertEq(liveGov.proposalSnapshot(liveId), proposedAt + ENSParams.VOTING_DELAY);
        assertEq(scaffoldGov.proposalSnapshot(scaffoldId), liveGov.proposalSnapshot(liveId));
        assertEq(scaffoldGov.proposalDeadline(scaffoldId), liveGov.proposalDeadline(liveId));

        vm.roll(liveGov.proposalSnapshot(liveId) + 1);
        assertEq(scaffoldGov.state(scaffoldId), liveGov.state(liveId)); // both Active

        vm.prank(WHALE);
        uint256 liveWeight = liveGov.castVote(liveId, 1);
        vm.prank(WHALE);
        uint256 scaffoldWeight = scaffoldGov.castVote(scaffoldId, 1);
        assertEq(scaffoldWeight, liveWeight);
        assertGt(scaffoldWeight, scaffoldGov.quorum(proposedAt)); // whale alone clears quorum
        assertEq(scaffoldGov.hasVoted(scaffoldId, WHALE), liveGov.hasVoted(liveId, WHALE));

        vm.roll(liveGov.proposalDeadline(liveId) + 1);
        assertEq(uint8(liveGov.state(liveId)), uint8(IGovernor.ProposalState.Succeeded));
        assertEq(scaffoldGov.state(scaffoldId), liveGov.state(liveId));

        _queueBoth(42, "parity");
        assertEq(uint8(liveGov.state(liveId)), uint8(IGovernor.ProposalState.Queued));
        assertEq(scaffoldGov.state(scaffoldId), liveGov.state(liveId));
        assertEq(scaffoldGov.proposalEta(scaffoldId), liveGov.proposalEta(liveId));

        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
        _executeBoth(42, "parity");
        assertEq(uint8(liveGov.state(liveId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(scaffoldGov.state(scaffoldId), liveGov.state(liveId));
        assertEq(liveBox.value(), 42);
        assertEq(scaffoldBox.value(), liveBox.value());
    }

    function test_parity_defeatedWithoutQuorum() public {
        uint256 liveId = _propose(liveGov, liveBox, 7, "no quorum");
        uint256 scaffoldId = _propose(scaffoldGov, scaffoldBox, 7, "no quorum");

        vm.roll(liveGov.proposalDeadline(liveId) + 1); // nobody votes
        assertEq(uint8(liveGov.state(liveId)), uint8(IGovernor.ProposalState.Defeated));
        assertEq(scaffoldGov.state(scaffoldId), liveGov.state(liveId));
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _queueBoth(uint256 newValue, string memory desc) internal {
        bytes32 dh = keccak256(bytes(desc));
        (address[] memory lt, uint256[] memory lv, bytes[] memory lc) = _actions(liveBox, newValue);
        liveGov.queue(lt, lv, lc, dh);
        (address[] memory st, uint256[] memory sv, bytes[] memory sc) = _actions(scaffoldBox, newValue);
        scaffoldGov.queue(st, sv, sc, dh);
    }

    function _executeBoth(uint256 newValue, string memory desc) internal {
        bytes32 dh = keccak256(bytes(desc));
        (address[] memory lt, uint256[] memory lv, bytes[] memory lc) = _actions(liveBox, newValue);
        liveGov.execute(lt, lv, lc, dh);
        (address[] memory st, uint256[] memory sv, bytes[] memory sc) = _actions(scaffoldBox, newValue);
        scaffoldGov.execute(st, sv, sc, dh);
    }
}

/// @dev Divergences inherent to OZ v4 → v5. Each one is asserted, not just noted:
///      if an upgrade ever makes these converge (or drift further), the suite flags it.
contract ParityDivergencesTest is BaseTest {
    /// Encoding-only divergence: v4 expresses 1% as 100/10000; the Nexus type-0 ruleset
    /// (StandardRuleset) as 1/100. The effective quorum is identical (asserted in
    /// test_parity_quorum); only the raw numerator/denominator differ. The fraction does not
    /// live on the governor — GovernorNexus has no GovernorVotesQuorumFraction, so no
    /// quorumNumerator()/quorumDenominator(). The numerator lives on the immutable ruleset
    /// (public quorumNumerator()); the denominator is fixed at 100 inside StandardRuleset
    /// (private constant, never surfaced). Read the fixture's ruleset reference and keep the
    /// cross-encoding equality assert vs live.
    function test_divergence_quorumFractionEncoding() public view {
        uint256 scaffoldNumerator = standardRuleset.quorumNumerator();
        uint256 scaffoldDenominator = 100; // StandardRuleset.QUORUM_DENOMINATOR (fixed, unexposed)

        assertEq(liveGov.quorumNumerator(), 100);
        assertEq(liveGov.quorumDenominator(), 10_000);
        assertEq(scaffoldNumerator, 1);
        assertEq(scaffoldDenominator, 100);
        assertEq(liveGov.quorumNumerator() * scaffoldDenominator, scaffoldNumerator * liveGov.quorumDenominator());
    }

    /// CONVERGENCE pin. StandardRuleset's numerator is IMMUTABLE with no checkpoint history,
    /// so the scaffold answers pre-deployment timepoints exactly like the live v4 governor
    /// (which holds a plain numerator and answers any past timepoint). A checkpointed
    /// numerator — v5's GovernorVotesQuorumFraction checkpoints from the deploy block — would
    /// resolve pre-deploy quorum() to 0; this pins the convergence (both > 0 and equal) so a
    /// regression to checkpoint behavior turns the suite red.
    function test_divergence_quorumBeforeDeploymentWindow() public {
        vm.roll(FORK_BLOCK + 1);
        assertEq(scaffoldGov.quorum(FORK_BLOCK - 1), liveGov.quorum(FORK_BLOCK - 1));
        assertGt(scaffoldGov.quorum(FORK_BLOCK - 1), 0);
    }

    /// BEHAVIORAL divergence, shipped on purpose: the live v4 governor rejects a second vote
    /// ("vote already cast"); GovernorNexus *replaces* it, moving the voter's weight from the
    /// old bucket to the new one. Parity's posture is "identical to live, minus the
    /// mechanisms we ship on purpose" — each deliberate mechanism divergence gets its pin here.
    ///
    /// Integrator note: the re-vote emits a second `VoteCast` for the same (proposal,
    /// voter); consumers must take the latest in log order as canonical, not sum them.
    function test_divergence_revoteReplacesInsteadOfReverting() public {
        uint256 liveId = _propose(liveGov, liveBox, 1, "revote");
        uint256 scaffoldId = _propose(scaffoldGov, scaffoldBox, 1, "revote");
        vm.roll(liveGov.proposalSnapshot(liveId) + 1);

        vm.startPrank(WHALE);
        liveGov.castVote(liveId, 1);
        scaffoldGov.castVote(scaffoldId, 1);

        // Live: the second vote is refused outright.
        vm.expectRevert(bytes("GovernorVotingSimple: vote already cast"));
        liveGov.castVote(liveId, 0);

        // Nexus: the second vote replaces the first.
        scaffoldGov.castVote(scaffoldId, 0);
        vm.stopPrank();

        uint256 weight = scaffoldGov.getVotes(WHALE, scaffoldGov.proposalSnapshot(scaffoldId));
        (uint256 against, uint256 for_,) = standardRuleset.proposalVotes(scaffoldId);
        assertEq(for_, 0, "the whale's weight left the For bucket");
        assertEq(against, weight, "and is counted exactly once in Against");
        assertTrue(scaffoldGov.hasVoted(scaffoldId, WHALE), "the whale still has a standing vote");
    }

    /// BEHAVIORAL divergence, shipped on purpose: a failing→passing
    /// flip inside the final `extensionWindow` (24h) extends Nexus voting by
    /// `extensionDuration` (48h) past the ORIGINAL deadline; the live governor closes on
    /// schedule regardless of when the outcome flipped. Here the flip is the simplest kind:
    /// the proposal sits failing (no votes → quorum unmet) until the WHALE flips it passing
    /// inside the window.
    function test_divergence_lateFlipExtendsNexusButNotLive() public {
        uint256 liveId = _propose(liveGov, liveBox, 2, "late flip");
        uint256 scaffoldId = _propose(scaffoldGov, scaffoldBox, 2, "late flip");
        vm.roll(liveGov.proposalSnapshot(liveId) + 1);

        uint256 liveDeadline = liveGov.proposalDeadline(liveId);
        uint256 scaffoldDeadline = scaffoldGov.proposalDeadline(scaffoldId);
        assertEq(scaffoldDeadline, liveDeadline, "identical periods before any flip");

        // Flip failing→passing inside the final window, same block on both governors.
        vm.roll(scaffoldDeadline - 100);
        vm.startPrank(WHALE);
        liveGov.castVote(liveId, 1);
        scaffoldGov.castVote(scaffoldId, 1);
        vm.stopPrank();

        vm.roll(scaffoldDeadline + 1);
        // Live: decided at the original deadline, snipe window and all.
        assertEq(liveGov.proposalDeadline(liveId), liveDeadline, "live never extends");
        assertEq(liveGov.state(liveId), 4, "live is already Succeeded"); // ProposalState.Succeeded
        // Nexus: 48h of response time, anchored at the original deadline.
        assertEq(
            scaffoldGov.proposalDeadline(scaffoldId),
            scaffoldDeadline + ENSParams.EXTENSION_DURATION,
            "nexus extends by 48h from the original deadline"
        );
        assertEq(scaffoldGov.state(scaffoldId), 1, "nexus voting stays open"); // ProposalState.Active
    }
}
