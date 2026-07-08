// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {ENSParams} from "../../src/ENSParams.sol";
import {Box, ForkFixture, IGov} from "./ForkFixture.sol";

/// @dev Behavioral parity: the stock v5 scaffold must be observationally equivalent to
///      the live ENS governor for configuration, proposal identity, and the full
///      propose → vote → queue → execute lifecycle. Divergences that are inherent to
///      the OZ v4 → v5 upgrade are pinned in the Divergences contract below so they
///      stay documented and intentional.
contract ForkParityTest is ForkFixture {
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

    function test_parity_quorum() public {
        // v5 checkpoints the quorum numerator at deployment, so query from the deploy
        // block onward (the pre-deployment window is pinned in Divergences).
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

    function test_parity_revoteRejectedOnBothSides() public {
        uint256 liveId = _propose(liveGov, liveBox, 9, "revote");
        uint256 scaffoldId = _propose(scaffoldGov, scaffoldBox, 9, "revote");
        vm.roll(liveGov.proposalSnapshot(liveId) + 1);

        vm.startPrank(WHALE);
        liveGov.castVote(liveId, 1);
        scaffoldGov.castVote(scaffoldId, 1);

        // Same behavior (revote rejected); error shape differs and is pinned in Divergences.
        vm.expectRevert();
        liveGov.castVote(liveId, 0);
        vm.expectRevert();
        scaffoldGov.castVote(scaffoldId, 0);
        vm.stopPrank();
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
contract ForkParityDivergencesTest is ForkFixture {
    /// v4 expresses 1% as 100/10000, v5 as 1/100 — the effective quorum is identical
    /// (asserted in test_parity_quorum); only the raw numerator/denominator differ.
    function test_divergence_quorumFractionEncoding() public view {
        assertEq(liveGov.quorumNumerator(), 100);
        assertEq(liveGov.quorumDenominator(), 10_000);
        assertEq(scaffoldGov.quorumNumerator(), 1);
        assertEq(scaffoldGov.quorumDenominator(), 100);
        assertEq(
            liveGov.quorumNumerator() * scaffoldGov.quorumDenominator(),
            scaffoldGov.quorumNumerator() * liveGov.quorumDenominator()
        );
    }

    /// v5 tracks the quorum numerator in a checkpoint history that starts at deployment:
    /// quorum() for timepoints before the deploy block resolves to numerator 0. The live
    /// v4 governor holds a plain storage numerator and answers any past timepoint.
    /// Irrelevant post-migration (only timepoints after deployment are ever queried),
    /// but pinned so the difference stays intentional.
    function test_divergence_quorumBeforeDeploymentWindow() public {
        vm.roll(FORK_BLOCK + 1);
        assertEq(scaffoldGov.quorum(FORK_BLOCK - 1), 0);
        assertGt(liveGov.quorum(FORK_BLOCK - 1), 0);
    }

    /// v4 reverts with a require string, v5 with a typed error. Behavior (revote
    /// rejected) is identical; only the revert data differs.
    function test_divergence_revoteErrorShape() public {
        uint256 liveId = _propose(liveGov, liveBox, 1, "err shape");
        uint256 scaffoldId = _propose(scaffoldGov, scaffoldBox, 1, "err shape");
        vm.roll(liveGov.proposalSnapshot(liveId) + 1);

        vm.startPrank(WHALE);
        liveGov.castVote(liveId, 1);
        scaffoldGov.castVote(scaffoldId, 1);

        vm.expectRevert(bytes("GovernorVotingSimple: vote already cast"));
        liveGov.castVote(liveId, 0);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, WHALE));
        scaffoldGov.castVote(scaffoldId, 0);
        vm.stopPrank();
    }
}
