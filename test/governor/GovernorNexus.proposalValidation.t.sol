// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {IRuleset} from "../../src/interfaces/IRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";
import {
    AcceptingValidatorRuleset,
    GasBurnValidatorRuleset,
    PoisonedValidatorRuleset,
    ToggleableValidatorRuleset
} from "../mocks/ValidatorRulesets.sol";

/// @dev Integration suite for the propose-time validation gate, using only mock validators —
///      the gate is a core feature independent of any production ruleset. Pins:
///      `hasProposalValidation` detection at registration and its immutability, validator
///      revert propagation (a rejected proposal is never created), byte-identical behavior
///      for validator-less types, and misbehaving-validator blast-radius containment.
///      The optimistic ruleset's use of the gate is covered in `GovernorNexus.optimistic.t.sol`.
contract GovernorNexusProposalValidationTest is GovernorNexusTestBase {
    uint8 internal constant ACCEPTING_TYPE = 1;

    AcceptingValidatorRuleset internal accepting;

    function setUp() public virtual override {
        super.setUp();
        accepting = new AcceptingValidatorRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (accepting, VOTING_DELAY, VOTING_PERIOD, uint256(0))),
            "register accepting validator type"
        );
        assertEq(governor.typeCount(), 2);
    }

    // ─────────────────────────── helpers ───────────────────────────

    /// @dev A well-formed single-action proposal; content is irrelevant to every mock here.
    function _dummyProposal()
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = makeAddr("target");
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = hex"12345678";
    }

    /// @dev Registers `ruleset` as the next type through the governance loop.
    function _registerRuleset(IRuleset ruleset, string memory description) internal returns (uint8 id) {
        id = governor.typeCount();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (ruleset, VOTING_DELAY, VOTING_PERIOD, uint256(0))), description
        );
    }

    // ─────────────────────────── detection at registration ───────────────────────────

    function test_registerType_pinsHasProposalValidationTrueForValidatorRuleset() public view {
        assertTrue(governor.getTypeConfig(ACCEPTING_TYPE).hasProposalValidation);
    }

    function test_registerType_pinsHasProposalValidationFalseForStandardRuleset() public view {
        assertFalse(
            governor.getTypeConfig(0).hasProposalValidation, "bootstrap standard type must not have a validator"
        );
    }

    function test_hasProposalValidationIsPinnedAtRegistration_neverRequeried() public {
        ToggleableValidatorRuleset toggleable = new ToggleableValidatorRuleset();
        // Registered while NOT advertising the validator interface -> pinned false.
        uint8 typeId = _registerRuleset(toggleable, "register toggleable");
        assertFalse(governor.getTypeConfig(typeId).hasProposalValidation);

        // Flipping the advertisement afterwards must change nothing: the pinned line rules.
        toggleable.setAdvertiseValidator(true);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        vm.prank(alice);
        uint256 id = governor.proposeWithType(targets, values, calldatas, "post-flip propose", typeId);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
    }

    // ─────────────────────────── revert propagation ───────────────────────────

    function test_validatorRevertLeavesProposalUncreated() public {
        PoisonedValidatorRuleset poisoned = new PoisonedValidatorRuleset();
        uint8 poisonedType = _registerRuleset(poisoned, "register poisoned validator");

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        string memory description = "rejected by validator";
        uint256 wouldBeId = governor.hashProposal(targets, values, calldatas, keccak256(bytes(description)));

        vm.prank(alice);
        vm.expectRevert(PoisonedValidatorRuleset.ValidatorPoisoned.selector);
        governor.proposeWithType(targets, values, calldatas, description, poisonedType);

        assertEq(governor.proposalSnapshot(wouldBeId), 0, "rejected proposal must not exist");
    }

    function test_validatorLessDefaultPathNeverTouchesValidator() public {
        // Default (standard) type while validator types exist: must pass — the gate
        // belongs to the types whose rulesets opted in.
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();
        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "standard path untouched");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
    }

    // ─────────────────────────── misbehaving-validator containment ───────────────────────────

    function test_poisonedValidator_bricksOnlyItsOwnType() public {
        PoisonedValidatorRuleset poisoned = new PoisonedValidatorRuleset();
        uint8 poisonedType = _registerRuleset(poisoned, "register poisoned validator");
        assertTrue(governor.getTypeConfig(poisonedType).hasProposalValidation);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();

        // Its own type: propose bricked (revert IS the gate's behavior, blast radius = itself).
        vm.prank(alice);
        vm.expectRevert(PoisonedValidatorRuleset.ValidatorPoisoned.selector);
        governor.proposeWithType(targets, values, calldatas, "poisoned type", poisonedType);

        // Default type and the healthy validated type: unaffected.
        vm.prank(alice);
        governor.propose(targets, values, calldatas, "default path alive");

        (address[] memory t2, uint256[] memory v2, bytes[] memory c2) = _dummyProposal();
        vm.prank(alice);
        governor.proposeWithType(t2, v2, c2, "healthy validated type alive", ACCEPTING_TYPE);
    }

    function test_gasBurnValidator_bricksOnlyItsOwnType() public {
        GasBurnValidatorRuleset gasBurner = new GasBurnValidatorRuleset();
        uint8 burnType = _registerRuleset(gasBurner, "register gas burner");

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _dummyProposal();

        vm.prank(alice);
        vm.expectRevert();
        governor.proposeWithType{gas: 2_000_000}(targets, values, calldatas, "gas burn type", burnType);

        vm.prank(alice);
        governor.propose(targets, values, calldatas, "default path alive after burn");
    }
}
