// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Vm} from "forge-std/Vm.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {GovernorPreventLateFlip} from "../../src/GovernorPreventLateFlip.sol";
import {StandardRuleset} from "../../src/rulesets/StandardRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";

/// @dev Anti-snipe late-vote extension. The mechanism's public surface is deliberately
///      minimal: the `proposalDeadline` view, the `ProposalExtended` event, and the two
///      immutable params — every test here asserts through those only.
///
///      Trigger semantics under test ("window low-water mark"): the extension fires iff the
///      proposal was observed failing at any point inside the final `extensionWindow` AND
///      would pass at the original deadline — with no state armed on tally crossings, so
///      mutable-vote oscillation cannot burn it. Anchor: original deadline +
///      `extensionDuration`, regardless of flip timing.
contract GovernorNexusLateFlipTest is GovernorNexusTestBase {
    /// @dev OZ `GovernorPreventLateQuorum` event ABI, adopted verbatim.
    event ProposalExtended(uint256 indexed proposalId, uint64 extendedDeadline);

    address internal bob = makeAddr("bob"); // can out-vote alice alone
    address internal carol = makeAddr("carol"); // dust weight: materializes, never flips
    address internal dave = makeAddr("dave"); // can out-vote alice + bob together

    function setUp() public virtual override {
        super.setUp();
        _fund(bob, 3_000_000e18);
        _fund(carol, 100e18);
        _fund(dave, 6_000_000e18);
        vm.roll(block.number + 1);
    }

    // ─────────────────────────── helpers ───────────────────────────

    /// @dev Propose through the default (standard) type and roll into Active.
    ///      Returns the id and the ORIGINAL deadline T (read before any extension can exist).
    function _proposeActive(string memory description) internal returns (uint256 id, uint256 t) {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(alice);
        id = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(id) + 1);
        t = governor.proposalDeadline(id);
    }

    function _vote(address voter, uint256 id, uint8 support) internal {
        vm.prank(voter);
        governor.castVote(id, support);
    }

    /// @dev "Would pass right now" exactly as the core evaluates it.
    function _wouldPass(uint256 id) internal view returns (bool) {
        return standardRuleset.quorumReached(id) && standardRuleset.voteSucceeded(id);
    }

    // ─────────────────────────── constructor surface ───────────────────────────

    function test_constructor_extensionParamsExposed() public view {
        assertEq(governor.extensionWindow(), EXTENSION_WINDOW);
        assertEq(governor.extensionDuration(), EXTENSION_DURATION);
    }

    function test_constructor_revertsWhenVotingPeriodNotBeyondExtensionWindow() public {
        StandardRuleset rs = _rulesetForNextGovernor();
        vm.expectRevert(
            abi.encodeWithSelector(GovernorNexus.VotingPeriodTooShort.selector, EXTENSION_WINDOW, EXTENSION_WINDOW)
        );
        new GovernorNexus(
            "GovernorNexus",
            IVotes(address(token)),
            timelock,
            rs,
            VOTING_DELAY,
            // votingPeriod == window: the "final 24h" would be the whole vote. The cast is
            // safe: EXTENSION_WINDOW is 20.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32(EXTENSION_WINDOW),
            PROPOSAL_THRESHOLD,
            2,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );
    }

    function test_constructor_revertsOnZeroExtensionParams() public {
        vm.expectRevert(GovernorPreventLateFlip.InvalidExtensionConfig.selector);
        new GovernorNexus(
            "GovernorNexus",
            IVotes(address(token)),
            timelock,
            standardRuleset,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            2,
            0,
            EXTENSION_DURATION
        );

        vm.expectRevert(GovernorPreventLateFlip.InvalidExtensionConfig.selector);
        new GovernorNexus(
            "GovernorNexus",
            IVotes(address(token)),
            timelock,
            standardRuleset,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            2,
            EXTENSION_WINDOW,
            0
        );
    }

    /// @dev The `registerType` guard shares `_registerType` with the constructor (single
    ///      registration path), so the constructor case above exercises the same check the
    ///      governance door hits.

    // ─────────────────────────── trigger matrix ───────────────────────────

    /// @dev The headline case: failing at window entry, flipped passing inside the
    ///      window → extended by exactly `extensionDuration` past the ORIGINAL deadline.
    function test_flipInsideWindow_extendsDeadlineByExtensionDuration() public {
        (uint256 id, uint256 t) = _proposeActive("flip inside window");

        _vote(alice, id, 0); // failing: Against 2M, For 0
        vm.roll(t - 10); // inside the final window
        _vote(bob, id, 1); // flip: For 3M > Against 2M, quorum met

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), t + EXTENSION_DURATION, "extended by duration from original deadline");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active), "voting stays open");

        vm.roll(t + EXTENSION_DURATION);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active), "open through the last block");

        vm.roll(t + EXTENSION_DURATION + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded), "final tally decides at T+E");
    }

    /// @dev Before the original deadline the view promises nothing: a mid-window flip can
    ///      still revert, so the extension is undecidable until T.
    function test_deadlineViewUnchangedBeforeOriginalDeadline() public {
        (uint256 id, uint256 t) = _proposeActive("undecidable before T");

        _vote(alice, id, 0);
        vm.roll(t - 10);
        _vote(bob, id, 1); // flip observed in window

        assertEq(governor.proposalDeadline(id), t, "no tentative extension mid-window");
        vm.roll(t);
        assertEq(governor.proposalDeadline(id), t, "still the original deadline at T itself");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active), "T is a voting block either way");
    }

    /// @dev Normal proposals are not delayed when outcome direction is stable —
    ///      passing through the whole window (with in-window activity) never extends.
    function test_stablePassingThroughWindow_noExtension() public {
        (uint256 id, uint256 t) = _proposeActive("stable passing");

        _vote(bob, id, 1); // passing well before the window
        vm.roll(t - 10);
        _vote(carol, id, 1); // in-window vote observes passing → no low-water mark

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), t, "no extension");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded), "decided at T");
    }

    function test_stableFailing_noExtension_defeatedAtOriginalDeadline() public {
        (uint256 id, uint256 t) = _proposeActive("stable failing");

        _vote(alice, id, 0);

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), t, "no extension");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated), "defeated at T");
    }

    /// @dev The dip-snipe — the scenario a two-point boundary comparison misses. Passing at
    ///      window entry AND at T, but failing in between: the low-water mark catches the
    ///      mid-window failing state, so the late re-flip still extends.
    function test_dipAndRecover_passingAtBothBoundaries_stillExtends() public {
        (uint256 id, uint256 t) = _proposeActive("dip and recover");

        _vote(bob, id, 1); // passing before the window opens
        vm.roll(t - 15);
        _vote(bob, id, 0); // re-vote creates a failing state inside the window (the dip)
        vm.roll(t - 1);
        _vote(bob, id, 1); // late re-flip back to passing

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), t + EXTENSION_DURATION, "dip inside the window forces the extension");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active), "response window open");
    }

    /// @dev The oscillation that burns OZ-style one-shot slots. Crossing early, re-voting
    ///      down, and sniping late must CAUSE the extension, not consume it.
    function test_oscillation_cannotBurnExtension() public {
        (uint256 id, uint256 t) = _proposeActive("threshold oscillation");

        _vote(alice, id, 0); // failing baseline
        vm.roll(t - 18);
        _vote(bob, id, 1); // cross early inside the window
        vm.roll(t - 15);
        _vote(bob, id, 0); // re-vote down — this is where OZ's slot would already be burned
        vm.roll(t - 1);
        _vote(bob, id, 1); // the snipe

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), t + EXTENSION_DURATION, "extension not burnable by oscillation");
    }

    /// @dev One-directional trigger: a late flip TO failing gets no extension — the proposal
    ///      simply dies at T. A failing observation alone is not enough; it must pass at T.
    function test_lateFlipToFailing_noExtension() public {
        (uint256 id, uint256 t) = _proposeActive("late flip to failing");

        _vote(bob, id, 1); // passing before the window
        vm.roll(t - 5);
        _vote(bob, id, 0); // late re-vote: failing at T

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), t, "no extension for a failing outcome");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated), "dies at T");
    }

    // ─────────────────────── lazy materialization & event ───────────────────────

    /// @dev The first cast after T materializes the (already-determined) extension and emits
    ///      the OZ-shaped event — exactly once, anchored at T + duration.
    function test_firstPostDeadlineCast_materializesAndEmitsOnce() public {
        (uint256 id, uint256 t) = _proposeActive("materialization");

        _vote(alice, id, 0);
        vm.roll(t - 10);
        _vote(bob, id, 1); // flip in window

        vm.roll(t + 5);
        vm.expectEmit(true, false, false, true);
        emit ProposalExtended(id, uint64(t + EXTENSION_DURATION));
        _vote(carol, id, 1); // dust vote: materializes, cannot flip anything

        // A second cast during the extension must not re-emit.
        vm.recordLogs();
        _vote(carol, id, 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("ProposalExtended(uint256,uint64)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "ProposalExtended emitted more than once");
        }
    }

    /// @dev Degenerate case: nobody votes during the extension — the event never fires, but
    ///      the views stay correct forever off the tally frozen since T.
    function test_noVotesDuringExtension_viewsConsistent_noEvent() public {
        (uint256 id, uint256 t) = _proposeActive("silent extension");

        _vote(alice, id, 0);
        vm.roll(t - 10);
        _vote(bob, id, 1);

        vm.roll(t + EXTENSION_DURATION + 1);
        assertEq(governor.proposalDeadline(id), t + EXTENSION_DURATION, "extension visible without materialization");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded), "outcome = tally at T, unchanged");
    }

    /// @dev A post-T cast on a NON-extended proposal reverts wholesale — no partial state,
    ///      no extension residue.
    function test_postDeadlineCastOnNonExtendedProposal_revertsWholesale() public {
        (uint256 id, uint256 t) = _proposeActive("no zombie votes");

        _vote(alice, id, 0); // stable failing → no extension

        vm.roll(t + 1);
        vm.prank(bob);
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.castVote(id, 1);

        assertEq(governor.proposalDeadline(id), t, "no residue from the reverted cast");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated), "still defeated");
    }

    // ─────────────────────── free voting during the extension ───────────────────────

    /// @dev Votes stay free in both directions during the extension; the tally at T+E decides.
    ///      Here the community uses the response window to defeat the sniped proposal.
    function test_votingFreeDuringExtension_finalTallyDecides() public {
        (uint256 id, uint256 t) = _proposeActive("extension defends");

        _vote(alice, id, 0);
        vm.roll(t - 10);
        _vote(bob, id, 1); // snipe: For 3M vs Against 2M

        vm.roll(t + 10);
        _vote(dave, id, 0); // the response the window exists for: Against 8M

        assertEq(governor.proposalDeadline(id), t + EXTENSION_DURATION, "deadline stable during the extension");
        vm.roll(t + EXTENSION_DURATION + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated), "snipe defeated in the extension");
    }

    /// @dev One extension only: a flip inside the extension never re-extends — T + E is a
    ///      hard ceiling.
    function test_noSecondExtension_flipInsideExtensionDoesNotReExtend() public {
        (uint256 id, uint256 t) = _proposeActive("no re-extension");

        _vote(alice, id, 0);
        vm.roll(t - 10);
        _vote(bob, id, 1); // extended

        vm.roll(t + 10);
        _vote(dave, id, 0); // failing inside the extension
        vm.roll(t + EXTENSION_DURATION - 2);
        _vote(dave, id, 1); // flips back passing right before T+E — no second extension

        assertEq(governor.proposalDeadline(id), t + EXTENSION_DURATION, "ceiling holds");
        vm.roll(t + EXTENSION_DURATION + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded), "decided at the ceiling");
    }

    // ─────────────────────── cast-path coverage: bySig ───────────────────────

    /// @dev The hooks live on the internal `_castVote`, so the sig paths (which skip the
    ///      public `castVote*` overrides) are covered too: a bySig flip inside the window
    ///      extends.
    function test_castVoteBySig_insideWindow_triggersExtension() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        _fund(signer, 5_000_000e18);
        vm.roll(block.number + 1);

        (uint256 id, uint256 t) = _proposeActive("bySig flip");
        _vote(alice, id, 0); // failing

        vm.roll(t - 10);
        bytes memory ballot = _signBallot(id, 1, signer, signerKey, governor.nonces(signer));
        governor.castVoteBySig(id, 1, signer, ballot); // flip through the sig path

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), t + EXTENSION_DURATION, "sig-path flip extends");
    }

    // ─────────────────────── property fuzz ───────────────────────

    /// @dev The core invariant, model-checked: for arbitrary bounded cast sequences,
    ///      the effective deadline is T+E iff (some in-window evaluation — pre- or post-cast —
    ///      observed a failing state) AND (the outcome at T is passing); otherwise T. The
    ///      model mirrors the implementation's observation points exactly, which is sound
    ///      because tallies only change inside casts.
    function testFuzz_extensionMatchesLowWaterPredicate(uint8[4] memory sups, uint8[4] memory offsets) public {
        (uint256 id, uint256 t) = _proposeActive("fuzz low-water");
        uint256 snapshot = governor.proposalSnapshot(id);

        // Normalize: supports into {0,1,2}, offsets into (snapshot, T] ascending.
        uint256[4] memory blocks_;
        for (uint256 i = 0; i < 4; i++) {
            sups[i] = sups[i] % 3;
            blocks_[i] = snapshot + 1 + (uint256(offsets[i]) % VOTING_PERIOD); // (snapshot, T]
        }
        // insertion sort, ascending
        for (uint256 i = 1; i < 4; i++) {
            for (uint256 j = i; j > 0 && blocks_[j - 1] > blocks_[j]; j--) {
                (blocks_[j - 1], blocks_[j]) = (blocks_[j], blocks_[j - 1]);
                (sups[j - 1], sups[j]) = (sups[j], sups[j - 1]);
            }
        }

        address[2] memory voters = [bob, dave];
        bool sawFailing = false;
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(blocks_[i]);
            bool inWindow = blocks_[i] >= t - EXTENSION_WINDOW; // ≤ T by construction
            if (inWindow && !_wouldPass(id)) sawFailing = true;
            _vote(voters[i % 2], id, sups[i]);
            if (inWindow && !_wouldPass(id)) sawFailing = true;
        }

        vm.roll(t);
        bool passesAtT = _wouldPass(id);
        uint256 expected = (sawFailing && passesAtT) ? t + EXTENSION_DURATION : t;

        vm.roll(t + 1);
        assertEq(governor.proposalDeadline(id), expected, "deadline matches the low-water predicate");
        if (!(sawFailing && passesAtT)) {
            assertEq(
                uint8(governor.state(id)),
                uint8(passesAtT ? IGovernor.ProposalState.Succeeded : IGovernor.ProposalState.Defeated),
                "non-extended outcome decided at T"
            );
        } else {
            assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active), "extension keeps voting open");
        }
    }

    // ─────────────────────────── helpers (sig path) ───────────────────────────

    function _signBallot(uint256 proposalId, uint8 support, address voter, uint256 key, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, support, voter, nonce));
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            governor.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
