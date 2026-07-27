// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {IRuleset} from "../../src/interfaces/IRuleset.sol";
import {StandardRuleset} from "../../src/rulesets/StandardRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";
import {RevertingViewsRuleset, StatefulPoisonRuleset} from "../mocks/MaliciousRulesets.sol";

/// @dev Per-proposer cap on concurrently live (Pending|Active) proposals, lazily pruned
///      at propose time. `bob`/`carol` are the spam subjects so `alice` stays free for
///      the governance loop the setters need.
contract GovernorNexusSpamLimitTest is GovernorNexusTestBase {
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        _fund(bob, 200_000e18);
        _fund(carol, 200_000e18);
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

    function _cancelAs(address proposer, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args(description);
        vm.prank(proposer);
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    function _expectLimitRevert(address proposer) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorNexus.ProposerActiveLimitReached.selector, proposer, governor.maxActiveProposals()
            )
        );
    }

    // ─────────────────────────── Cap behavior ───────────────────────────

    function test_thirdLiveProposal_reverts() public {
        _proposeAs(bob, "p1");
        _proposeAs(bob, "p2");
        _expectLimitRevert(bob);
        vm.prank(bob);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _args("p3");
        governor.propose(targets, values, calldatas, "p3");
    }

    function test_bothDoors_enforceAndRecord() public {
        // one proposal through each door, then both doors reject the third
        _proposeAs(bob, "door1");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _args("door2");
        vm.prank(bob);
        governor.proposeWithType(targets, values, calldatas, "door2", 0);

        assertEq(governor.activeProposalCount(bob), 2);

        (targets, values, calldatas,) = _args("door3");
        _expectLimitRevert(bob);
        vm.prank(bob);
        governor.propose(targets, values, calldatas, "door3");

        _expectLimitRevert(bob);
        vm.prank(bob);
        governor.proposeWithType(targets, values, calldatas, "door3", 0);
    }

    // ─────────────────────── Prune per exit state ───────────────────────

    function test_canceledProposal_freesSlot_sameBlock() public {
        _proposeAs(bob, "p1");
        _proposeAs(bob, "p2");
        // concurrency cap, not a rate limit: cancel-then-repropose succeeds in the same block
        _cancelAs(bob, "p1");
        uint256 id3 = _proposeAs(bob, "p3");
        assertEq(uint8(governor.state(id3)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_defeatedProposal_freesSlot() public {
        uint256 id1 = _proposeAs(bob, "p1");
        _proposeAs(bob, "p2");
        vm.roll(governor.proposalDeadline(id1) + 1); // nobody voted: quorum unmet → Defeated
        assertEq(uint8(governor.state(id1)), uint8(IGovernor.ProposalState.Defeated));
        _proposeAs(bob, "p3");
        // p2 shared p1's deadline (same creation block) so both are Defeated; only p3 occupies
        assertEq(governor.activeProposalCount(bob), 1);
    }

    function test_succeededProposal_freesSlot() public {
        uint256 id1 = _proposeAs(bob, "p1");
        _proposeAs(bob, "p2");
        vm.roll(governor.proposalSnapshot(id1) + 1);
        vm.prank(alice);
        governor.castVote(id1, 1);
        vm.roll(governor.proposalDeadline(id1) + 1);
        assertEq(uint8(governor.state(id1)), uint8(IGovernor.ProposalState.Succeeded));
        _proposeAs(bob, "p3"); // p2 is Defeated by now as well; only p3 occupies
        assertEq(governor.activeProposalCount(bob), 1);
    }

    function test_queuedProposal_doesNotOccupySlot() public {
        // Queued survived the vote — it is no longer contestable attention-spam
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args("queued");
        vm.prank(bob);
        uint256 id1 = governor.propose(targets, values, calldatas, "queued");
        _proposeAs(bob, "p2");

        vm.roll(governor.proposalSnapshot(id1) + 1);
        vm.prank(alice);
        governor.castVote(id1, 1);
        vm.roll(governor.proposalDeadline(id1) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(id1)), uint8(IGovernor.ProposalState.Queued));

        // p2 hit its deadline unvoted (Defeated); only the new proposal occupies afterwards
        _proposeAs(bob, "p3");
        assertEq(governor.activeProposalCount(bob), 1);
    }

    function test_executedProposal_freesSlot() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _args("executed");
        vm.prank(bob);
        uint256 id1 = governor.propose(targets, values, calldatas, "executed");
        vm.roll(governor.proposalSnapshot(id1) + 1);
        vm.prank(alice);
        governor.castVote(id1, 1);
        vm.roll(governor.proposalDeadline(id1) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(id1)), uint8(IGovernor.ProposalState.Executed));

        _proposeAs(bob, "p2");
        _proposeAs(bob, "p3");
        assertEq(governor.activeProposalCount(bob), 2);
    }

    // ─────────────────────────── Setter guards ───────────────────────────

    function test_constructor_rejectsZeroAndAboveCeiling() public {
        // A reverting CREATE still consumes the deployer's nonce, so each attempt needs its
        // own next-address-bound ruleset — deployed before expectRevert arms.
        StandardRuleset rs0 = _rulesetForNextGovernor();
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.InvalidMaxActiveProposals.selector, 0));
        new GovernorNexus(
            "t",
            IVotes(address(token)),
            timelock,
            rs0,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            0,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );

        StandardRuleset rs11 = _rulesetForNextGovernor();
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.InvalidMaxActiveProposals.selector, 11));
        new GovernorNexus(
            "t",
            IVotes(address(token)),
            timelock,
            rs11,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            11,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );
    }

    function test_constructor_acceptsBounds() public {
        GovernorNexus g1 = new GovernorNexus(
            "t",
            IVotes(address(token)),
            timelock,
            _rulesetForNextGovernor(),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            1,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );
        assertEq(g1.maxActiveProposals(), 1);
        GovernorNexus g10 = new GovernorNexus(
            "t",
            IVotes(address(token)),
            timelock,
            _rulesetForNextGovernor(),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            10,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );
        assertEq(g10.maxActiveProposals(), 10);
    }

    function test_setter_onlyGovernance() public {
        vm.expectRevert();
        vm.prank(eoa);
        governor.setMaxActiveProposals(3);
    }

    function test_setter_viaGovernance_updatesAndEmits() public {
        bytes memory call = abi.encodeWithSelector(GovernorNexus.setMaxActiveProposals.selector, uint8(3));
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _prepareSelfCall(call, "set max 3");
        vm.expectEmit(address(governor));
        emit GovernorNexus.MaxActiveProposalsSet(3);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.maxActiveProposals(), 3);
    }

    // ─────────────────── Cap lowered below live count ───────────────────

    function test_capLoweredBelowLiveCount_blocksUntilBelowNewCap() public {
        _proposeAs(bob, "p1");
        uint256 id2 = _proposeAs(bob, "p2");
        // deadline of bob's proposals must outlive the governance loop; re-propose late instead:
        // run the loop first, then check bob. Governance sets cap 2 → 1 while bob has 2 live.
        _executeSelfCall(abi.encodeWithSelector(GovernorNexus.setMaxActiveProposals.selector, uint8(1)), "set max 1");

        // bob's p1/p2 have long passed deadline (Defeated) during the loop → re-arm 2 live now
        assertEq(governor.activeProposalCount(bob), 0);
        _proposeAs(bob, "p3");
        _expectLimitRevert(bob); // cap is now 1
        vm.prank(bob);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _args("p4");
        governor.propose(targets, values, calldatas, "p4");

        _cancelAs(bob, "p3");
        uint256 id5 = _proposeAs(bob, "p5");
        assertEq(uint8(governor.state(id5)), uint8(IGovernor.ProposalState.Pending));
        assertEq(governor.activeProposalCount(bob), 1);
        // silence unused warnings meaningfully: id2 really is dead
        assertEq(uint8(governor.state(id2)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ─────────────────────────── Views + independence ───────────────────────────

    function test_activeProposalCount_neverCountsDeadUnprunedIds() public {
        assertEq(governor.activeProposalCount(bob), 0);
        _proposeAs(bob, "p1");
        _proposeAs(bob, "p2");
        assertEq(governor.activeProposalCount(bob), 2);
        // cancel without any propose (no prune runs): the view must filter the dead id
        _cancelAs(bob, "p2");
        assertEq(governor.activeProposalCount(bob), 1);
    }

    // ─────────────────── Containment: poisoned ruleset cannot brick propose ───────────────────

    function test_poisonedRulesetProposal_doesNotBrickProposersNextPropose() public {
        // register a ruleset whose outcome views revert (the adversarial mock)
        RevertingViewsRuleset rv = new RevertingViewsRuleset(address(governor));
        uint8 badType = uint8(governor.typeCount());
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (IRuleset(rv), VOTING_DELAY, VOTING_PERIOD, 0)),
            "register reverting-views ruleset"
        );

        // bob proposes under the poisoned type and the proposal passes its deadline:
        // state(id) now reverts ViewPoisoned — but the prune must settle liveness on the
        // deadline alone and never reach the ruleset.
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _args("poisoned");
        vm.prank(bob);
        uint256 id = governor.proposeWithType(targets, values, calldatas, "poisoned", badType);
        vm.roll(governor.proposalDeadline(id) + 1);
        vm.expectRevert(RevertingViewsRuleset.ViewPoisoned.selector);
        governor.state(id);

        assertEq(governor.activeProposalCount(bob), 0); // the view is poison-proof too
        _proposeAs(bob, "after poison 1");
        _proposeAs(bob, "after poison 2"); // full cap available again
        assertEq(governor.activeProposalCount(bob), 2);
    }

    /// @dev Containment through the late-flip path the unconditional mock cannot reach: a ruleset
    ///      that behaves while voting is open (so a final-window cast arms `FailingObserved`) and
    ///      only reverts after the deadline. Pre-fix, `_isLive` read the OVERRIDDEN
    ///      `proposalDeadline`, whose `FailingObserved` branch calls `_wouldPass` → the poisoned
    ///      ruleset → revert, bricking the proposer's prune (and every future propose). The probe
    ///      must instead settle liveness on the original deadline + late-flip stage alone.
    function test_statefulPoisonedRuleset_afterFailingObserved_doesNotBrickPropose() public {
        StatefulPoisonRuleset poison = new StatefulPoisonRuleset(address(governor));
        uint8 badType = uint8(governor.typeCount());
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (IRuleset(poison), VOTING_DELAY, VOTING_PERIOD, 0)),
            "register stateful-poison ruleset"
        );

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _args("stateful poison");
        vm.prank(bob);
        uint256 id = governor.proposeWithType(targets, values, calldatas, "stateful poison", badType);

        // Cast inside the final window while the ruleset still behaves (views return failing):
        // this arms the late-flip `FailingObserved` stage — the state the unconditional mock
        // can never produce.
        vm.roll(governor.proposalDeadline(id) - 1);
        vm.prank(alice);
        governor.castVote(id, 1);

        // Past the conservative window (originalDeadline + extensionDuration), then poison it.
        vm.roll(governor.proposalDeadline(id) + EXTENSION_DURATION + 1);
        poison.poison();

        // Containment boundary: state() legitimately reaches the ruleset post-deadline, so it
        // still reverts — but the liveness probe must not, so propose stays available.
        vm.expectRevert(StatefulPoisonRuleset.ViewPoisoned.selector);
        governor.state(id);

        assertEq(governor.activeProposalCount(bob), 0); // probe is ruleset-free: dead id, no revert
        _proposeAs(bob, "after stateful poison 1");
        _proposeAs(bob, "after stateful poison 2"); // full cap available again
        assertEq(governor.activeProposalCount(bob), 2);
    }

    function test_capIsPerProposer() public {
        _proposeAs(bob, "b1");
        _proposeAs(bob, "b2");
        // bob at cap; carol unaffected
        uint256 c1 = _proposeAs(carol, "c1");
        assertEq(uint8(governor.state(c1)), uint8(IGovernor.ProposalState.Pending));
        assertEq(governor.activeProposalCount(carol), 1);
    }
}
