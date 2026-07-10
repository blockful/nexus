// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusHarness.sol";

contract GovernorNexusProposeTest is GovernorNexusTestBase {
    // Type-1 line: every parameter distinct from type 0 (delay 1, period 50, threshold 100k)
    // so frozen-from-the-line assertions cannot pass by accident.
    uint48 internal constant T1_DELAY = 5;
    uint32 internal constant T1_PERIOD = 100;
    uint256 internal constant T1_THRESHOLD = 1_000_000e18;

    // Mirror of GovernorNexus / IGovernor events for vm.expectEmit.
    event ProposalTypedCreated(uint256 indexed proposalId, uint8 indexed typeId, IRuleset indexed ruleset);
    event ProposalCreated(
        uint256 proposalId,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 voteStart,
        uint256 voteEnd,
        string description
    );

    address internal bob = makeAddr("bob"); // above type-0 threshold, below type-1's

    function setUp() public override {
        super.setUp();
        _fund(bob, 500_000e18);
        vm.roll(block.number + 1);
    }

    // ─────────────────────────── Helpers ───────────────────────────

    /// @dev Unique single-action payload; `seed` differentiates proposal ids.
    function _payload(bytes memory seed)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(0xCAFE);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = seed;
    }

    /// @dev Registers type 1 (T1_DELAY / T1_PERIOD / T1_THRESHOLD) through the governance loop.
    function _registerType1() internal returns (StandardRuleset rs) {
        rs = _newRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs, T1_DELAY, T1_PERIOD, T1_THRESHOLD)), "register type 1"
        );
    }

    // ─────────────────────── 1. Pin written + typed event ───────────────────────

    function test_proposeWithType_writesPinAndEmitsTypedEvent() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("pin-0");
        vm.prank(alice);
        uint256 id0 = governor.proposeWithType(t, v, c, "pin type 0", 0);
        assertEq(governor.proposalType(id0), 0);
        assertEq(address(governor.proposalRuleset(id0)), address(standardRuleset));

        StandardRuleset rs1 = _registerType1();
        (t, v, c) = _payload("pin-1");
        uint256 predicted = governor.hashProposal(t, v, c, keccak256(bytes("pin type 1")));

        vm.expectEmit(true, true, true, true, address(governor));
        emit ProposalTypedCreated(predicted, 1, rs1);
        vm.prank(alice);
        uint256 id1 = governor.proposeWithType(t, v, c, "pin type 1", 1);

        assertEq(id1, predicted);
        assertEq(governor.proposalType(id1), 1);
        assertEq(address(governor.proposalRuleset(id1)), address(rs1));
    }

    // ─────────────────── 2. Delay/period frozen from the type line ───────────────────

    function test_proposeWithType_freezesTimingFromTypeLine() public {
        _registerType1();
        uint256 nowClock = governor.clock();

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("typed-timing");
        vm.prank(alice);
        uint256 id1 = governor.proposeWithType(t, v, c, "typed timing", 1);
        assertEq(governor.proposalSnapshot(id1), nowClock + T1_DELAY);
        assertEq(governor.proposalDeadline(id1), nowClock + T1_DELAY + T1_PERIOD);

        // A type-0 proposal in the same block keeps type-0 numbers — no cross-contamination.
        (t, v, c) = _payload("default-timing");
        vm.prank(alice);
        uint256 id0 = governor.proposeWithType(t, v, c, "default timing", 0);
        assertEq(governor.proposalSnapshot(id0), nowClock + VOTING_DELAY);
        assertEq(governor.proposalDeadline(id0), nowClock + VOTING_DELAY + VOTING_PERIOD);
    }

    // ─────────────────────────── 3. Per-type threshold ───────────────────────────

    function test_proposeWithType_enforcesPerTypeThreshold() public {
        _registerType1();
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("threshold");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, bob, 500_000e18, T1_THRESHOLD)
        );
        governor.proposeWithType(t, v, c, "bob over type 1", 1);

        // Same proposer, same payload, type 0 (threshold 100k) — succeeds.
        vm.prank(bob);
        uint256 id = governor.proposeWithType(t, v, c, "bob over type 0", 0);
        assertEq(governor.proposalType(id), 0);
    }

    // ──────────────────── 4. `#proposer=` suffix on both doors ────────────────────

    function test_suffixDefense_enforcedOnBothDoors() public {
        string memory desc = string.concat("restricted #proposer=", Strings.toChecksumHexString(alice));
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("suffix");

        // Wrong proposer, stock door.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorRestrictedProposer.selector, bob));
        governor.propose(t, v, c, desc);

        // Wrong proposer, typed door.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorRestrictedProposer.selector, bob));
        governor.proposeWithType(t, v, c, desc, 0);

        // Named proposer succeeds on both doors (distinct payloads → distinct ids).
        vm.prank(alice);
        governor.propose(t, v, c, desc);

        (t, v, c) = _payload("suffix-typed");
        vm.prank(alice);
        governor.proposeWithType(t, v, c, desc, 0);
    }

    // ─────────────────────── 5. Unknown / inactive type ───────────────────────

    function test_proposeWithType_revertsOnUnknownType() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("unknown");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.NonexistentType.selector, uint8(7)));
        governor.proposeWithType(t, v, c, "unknown type", 7);
    }

    function test_proposeWithType_revertsOnInactiveType() public {
        _registerType1();
        _executeSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (uint8(1), false)), "deactivate 1");

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("inactive");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.TypeInactive.selector, uint8(1)));
        governor.proposeWithType(t, v, c, "inactive type", 1);
    }

    // ─────────────────────── 6. Stock ProposalCreated parity ───────────────────────

    function test_proposeWithType_emitsStockProposalCreatedWithFrozenTiming() public {
        _registerType1();
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("stock-event");
        string memory desc = "stock event parity";
        uint256 predicted = governor.hashProposal(t, v, c, keccak256(bytes(desc)));
        uint256 snapshot = governor.clock() + T1_DELAY;

        vm.expectEmit(true, true, true, true, address(governor));
        emit ProposalCreated(predicted, alice, t, v, new string[](1), c, snapshot, snapshot + T1_PERIOD, desc);
        vm.prank(alice);
        governor.proposeWithType(t, v, c, desc, 1);
    }

    // ──────────────── 7. Default routing follows the default pointer ────────────────

    function test_propose_pinsDefaultTypeAndFollowsPointer() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("default-0");
        vm.prank(alice);
        uint256 id0 = governor.propose(t, v, c, "stock door default 0");
        assertEq(governor.proposalType(id0), 0);

        StandardRuleset rs1 = _registerType1();
        _executeSelfCall(abi.encodeCall(GovernorNexus.setDefaultType, (uint8(1))), "default to 1");

        (t, v, c) = _payload("default-1");
        vm.prank(alice);
        uint256 id1 = governor.propose(t, v, c, "stock door default 1");
        assertEq(governor.proposalType(id1), 1);
        assertEq(address(governor.proposalRuleset(id1)), address(rs1));
    }

    // ─────────────── 8. Duplicate payload reverts across types (D2) ───────────────

    function test_duplicatePayload_revertsAcrossTypes() public {
        _registerType1();
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("dup");
        string memory desc = "duplicate payload";

        vm.prank(alice);
        uint256 id = governor.proposeWithType(t, v, c, desc, 0);

        // Same payload+description under type 1 → same id (typeId is NOT hashed) → already exists.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector, id, IGovernor.ProposalState.Pending, bytes32(0)
            )
        );
        governor.proposeWithType(t, v, c, desc, 1);
    }

    // ──────────── 9+10. Pin invariant on both doors + transient context cleared ────────────
    // D10: `_propose` cannot be sealed (it is the sole ProposalCore writer, reached via
    // `super`), so the invariant it protected is asserted instead: every proposal created
    // through either public door carries a pin (also asserted in tests 1 and 7), and the
    // transient type context never leaks into a later propose in the same transaction.

    function test_transientTypeContext_doesNotLeakIntoNextPropose() public {
        _registerType1();

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _payload("typed-first");
        vm.prank(alice);
        uint256 id1 = governor.proposeWithType(t, v, c, "typed first", 1);
        assertEq(governor.proposalType(id1), 1);

        // At rest, the arg-less views read the default row again.
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);

        // Foundry runs the whole test in one transaction, so transient storage persists
        // across these calls — a leaked slot would give this proposal type-1 timing.
        (t, v, c) = _payload("stock-second");
        vm.prank(alice);
        uint256 id0 = governor.propose(t, v, c, "stock second");
        uint256 nowClock = governor.clock();

        assertEq(governor.proposalType(id0), 0);
        assertEq(governor.proposalSnapshot(id0), nowClock + VOTING_DELAY);
        assertEq(governor.proposalDeadline(id0), nowClock + VOTING_DELAY + VOTING_PERIOD);
    }
}
