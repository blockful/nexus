// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";
import {MockProposalValidator} from "./mocks/MockProposalValidator.sol";

/// @dev Supports ERC165 but NOT IRuleset — exercises the "165 but wrong interface" guardrail.
contract Mock165 is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Plain contract with no ERC165 at all.
contract NotARuleset {}

contract GovernorNexusRegistryTest is GovernorNexusTestBase {
    // Mirror of GovernorNexus events for vm.expectEmit.
    event TypeRegistered(
        uint8 indexed typeId,
        IRuleset indexed ruleset,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold
    );
    event TypeActiveSet(uint8 indexed typeId, bool active);
    event DefaultTypeSet(uint8 indexed typeId);

    // ─────────────────────────── Constructor bootstrap ───────────────────────────

    function test_constructor_bootstrapsRowZeroAsDefault() public view {
        assertEq(governor.typeCount(), 1);
        assertEq(governor.defaultTypeId(), 0);

        GovernorNexus.TypeConfig memory cfg = governor.getTypeConfig(0);
        assertEq(address(cfg.ruleset), address(standardRuleset));
        assertEq(cfg.votingDelay, VOTING_DELAY);
        assertEq(cfg.votingPeriod, VOTING_PERIOD);
        assertEq(cfg.proposalThreshold, PROPOSAL_THRESHOLD);
        assertTrue(cfg.active);
    }

    function test_constructor_defaultTypeViewsReadRowZero() public view {
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
    }

    function test_constructor_emitsTypeRegistered() public {
        vm.expectEmit(true, true, false, true);
        emit TypeRegistered(0, standardRuleset, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD);
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
            EXTENSION_DURATION
        );
    }

    function test_constructor_revertsOnZeroRuleset() public {
        vm.expectRevert(GovernorNexus.RulesetZeroAddress.selector);
        new GovernorNexus(
            "GovernorNexus",
            IVotes(address(token)),
            timelock,
            IRuleset(address(0)),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            2,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );
    }

    function test_constructor_revertsOnZeroVotingPeriod() public {
        vm.expectRevert(GovernorNexus.InvalidVotingPeriod.selector);
        new GovernorNexus(
            "GovernorNexus",
            IVotes(address(token)),
            timelock,
            standardRuleset,
            VOTING_DELAY,
            0,
            PROPOSAL_THRESHOLD,
            2,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );
    }

    function test_constructor_revertsOnNonRulesetInterface() public {
        Mock165 notRuleset = new Mock165();
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.RulesetInterfaceUnsupported.selector, address(notRuleset)));
        new GovernorNexus(
            "GovernorNexus",
            IVotes(address(token)),
            timelock,
            IRuleset(address(notRuleset)),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            2,
            EXTENSION_WINDOW,
            EXTENSION_DURATION
        );
    }

    // ─────────────────────────── registerType ───────────────────────────

    function test_registerType_appendsWithSequentialIdsAndStoresContent() public {
        StandardRuleset rs = _newRuleset();
        uint48 vd = 7;
        uint32 vp = 123;
        uint256 pt = 42e18;

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.registerType, (rs, vd, vp, pt)), "register type 1");
        vm.expectEmit(true, true, false, true, address(governor));
        emit TypeRegistered(1, rs, vd, vp, pt);
        governor.execute(t, v, c, h);

        assertEq(governor.typeCount(), 2);
        GovernorNexus.TypeConfig memory cfg = governor.getTypeConfig(1);
        assertEq(address(cfg.ruleset), address(rs));
        assertEq(cfg.votingDelay, vd);
        assertEq(cfg.votingPeriod, vp);
        assertEq(cfg.proposalThreshold, pt);
        assertTrue(cfg.active);

        // A second registration takes id 2.
        StandardRuleset rs2 = _newRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs2, uint48(2), uint32(29), uint256(1))), "register type 2"
        );
        assertEq(governor.typeCount(), 3);
        assertEq(address(governor.getTypeConfig(2).ruleset), address(rs2));
    }

    function test_registerType_revertsOnZeroRuleset() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _prepareSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (IRuleset(address(0)), VOTING_DELAY, VOTING_PERIOD, uint256(0))),
            "zero ruleset"
        );
        vm.expectRevert(GovernorNexus.RulesetZeroAddress.selector);
        governor.execute(t, v, c, h);
    }

    function test_registerType_revertsOnZeroVotingPeriod() public {
        StandardRuleset rs = _newRuleset();
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _prepareSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs, VOTING_DELAY, uint32(0), uint256(0))), "zero period"
        );
        vm.expectRevert(GovernorNexus.InvalidVotingPeriod.selector);
        governor.execute(t, v, c, h);
    }

    function test_registerType_revertsOnEOA() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _prepareSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (IRuleset(eoa), VOTING_DELAY, VOTING_PERIOD, uint256(0))),
            "eoa ruleset"
        );
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.RulesetInterfaceUnsupported.selector, eoa));
        governor.execute(t, v, c, h);
    }

    function test_registerType_revertsOnNon165Contract() public {
        NotARuleset notRuleset = new NotARuleset();
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _prepareSelfCall(
            abi.encodeCall(
                GovernorNexus.registerType, (IRuleset(address(notRuleset)), VOTING_DELAY, VOTING_PERIOD, uint256(0))
            ),
            "non-165 contract"
        );
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.RulesetInterfaceUnsupported.selector, address(notRuleset)));
        governor.execute(t, v, c, h);
    }

    function test_registerType_revertsOn165ButNotIRuleset() public {
        Mock165 notRuleset = new Mock165();
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _prepareSelfCall(
            abi.encodeCall(
                GovernorNexus.registerType, (IRuleset(address(notRuleset)), VOTING_DELAY, VOTING_PERIOD, uint256(0))
            ),
            "165 but not IRuleset"
        );
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.RulesetInterfaceUnsupported.selector, address(notRuleset)));
        governor.execute(t, v, c, h);
    }

    function test_registerType_revertsForUnauthorizedCaller() public {
        StandardRuleset rs = _newRuleset();
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, eoa));
        governor.registerType(rs, VOTING_DELAY, VOTING_PERIOD, 0);
    }

    // ─────────────────────────── Append-only discipline ───────────────────────────

    function test_appendOnly_rowContentUnchangedAfterUnrelatedOps() public {
        // Snapshot row 0 content.
        GovernorNexus.TypeConfig memory before = governor.getTypeConfig(0);

        // Register a new type and toggle/point at it — none of which may touch row 0 content.
        StandardRuleset rs = _newRuleset();
        _executeSelfCall(abi.encodeCall(GovernorNexus.registerType, (rs, uint48(9), uint32(29), uint256(9))), "reg");
        _executeSelfCall(abi.encodeCall(GovernorNexus.setDefaultType, (uint8(1))), "default to 1");
        _executeSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (uint8(0), false)), "deactivate 0");

        GovernorNexus.TypeConfig memory after_ = governor.getTypeConfig(0);
        assertEq(address(after_.ruleset), address(before.ruleset));
        assertEq(after_.votingDelay, before.votingDelay);
        assertEq(after_.votingPeriod, before.votingPeriod);
        assertEq(after_.proposalThreshold, before.proposalThreshold);
        // Only `active` may have changed (it did, via setTypeActive on the now-non-default row).
        assertFalse(after_.active);
    }

    // ─────────────────────────── setTypeActive ───────────────────────────

    function test_setTypeActive_togglesAndEmits() public {
        // Register type 1 so we can deactivate it (row 0 is the default and cannot be).
        StandardRuleset rs = _newRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs, VOTING_DELAY, VOTING_PERIOD, uint256(0))), "reg"
        );

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (uint8(1), false)), "deactivate 1");
        vm.expectEmit(true, false, false, true, address(governor));
        emit TypeActiveSet(1, false);
        governor.execute(t, v, c, h);
        assertFalse(governor.getTypeConfig(1).active);

        (t, v, c, h) = _prepareSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (uint8(1), true)), "reactivate 1");
        vm.expectEmit(true, false, false, true, address(governor));
        emit TypeActiveSet(1, true);
        governor.execute(t, v, c, h);
        assertTrue(governor.getTypeConfig(1).active);
    }

    function test_setTypeActive_revertsOnNonexistentType() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (uint8(5), false)), "nonexistent");
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.NonexistentType.selector, uint8(5)));
        governor.execute(t, v, c, h);
    }

    function test_setTypeActive_revertsWhenDeactivatingDefault() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (uint8(0), false)), "deactivate default");
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.CannotDeactivateDefaultType.selector, uint8(0)));
        governor.execute(t, v, c, h);
    }

    function test_setTypeActive_revertsForUnauthorizedCaller() public {
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, eoa));
        governor.setTypeActive(0, false);
    }

    // ─────────────────────────── setDefaultType ───────────────────────────

    function test_setDefaultType_movesPointerAndEmits() public {
        StandardRuleset rs = _newRuleset();
        _executeSelfCall(abi.encodeCall(GovernorNexus.registerType, (rs, uint48(3), uint32(31), uint256(5))), "reg");

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.setDefaultType, (uint8(1))), "default to 1");
        vm.expectEmit(true, false, false, false, address(governor));
        emit DefaultTypeSet(1);
        governor.execute(t, v, c, h);

        assertEq(governor.defaultTypeId(), 1);
        // Default-type views now read row 1.
        assertEq(governor.votingDelay(), 3);
        assertEq(governor.votingPeriod(), 31);
        assertEq(governor.proposalThreshold(), 5);
    }

    function test_setDefaultType_revertsOnNonexistentType() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.setDefaultType, (uint8(9))), "nonexistent default");
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.NonexistentType.selector, uint8(9)));
        governor.execute(t, v, c, h);
    }

    function test_setDefaultType_revertsWhenTargetInactive() public {
        StandardRuleset rs = _newRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs, VOTING_DELAY, VOTING_PERIOD, uint256(0))), "reg"
        );
        _executeSelfCall(abi.encodeCall(GovernorNexus.setTypeActive, (uint8(1), false)), "deactivate 1");

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.setDefaultType, (uint8(1))), "default to inactive");
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.TypeInactive.selector, uint8(1)));
        governor.execute(t, v, c, h);
    }

    function test_setDefaultType_revertsForUnauthorizedCaller() public {
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, eoa));
        governor.setDefaultType(0);
    }

    // ─────────────────────────── Views ───────────────────────────

    function test_getTypeConfig_revertsOnNonexistentType() public {
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.NonexistentType.selector, uint8(1)));
        governor.getTypeConfig(1);
    }

    function test_proposalType_revertsOnNonexistentProposal() public {
        uint256 ghostId = 0xdead;
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, ghostId));
        governor.proposalType(ghostId);
    }

    function test_proposalRuleset_revertsOnNonexistentProposal() public {
        uint256 ghostId = 0xbeef;
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, ghostId));
        governor.proposalRuleset(ghostId);
    }

    // ─────────────────────────── IProposalValidator gating ───────────────────────────

    function test_registerType_pinsGatedTrue_forValidatorRuleset() public {
        MockProposalValidator validator = new MockProposalValidator(address(governor), IVotes(address(token)));
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (IRuleset(address(validator)), VOTING_DELAY, VOTING_PERIOD, 0)),
            "register gated type"
        );
        uint8 id = governor.typeCount() - 1;
        assertTrue(governor.getTypeConfig(id).gated);
        assertFalse(governor.getTypeConfig(0).gated); // StandardRuleset line untouched
    }

    function test_proposeWithType_callsValidator_withDescriptionHash() public {
        MockProposalValidator validator = new MockProposalValidator(address(governor), IVotes(address(token)));
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (IRuleset(address(validator)), VOTING_DELAY, VOTING_PERIOD, 0)),
            "register gated type"
        );
        uint8 id = governor.typeCount() - 1;

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _dummyAction();
        vm.prank(alice);
        governor.proposeWithType(t, v, c, "gated proposal", id);

        assertEq(validator.calls(), 1);
        assertEq(validator.lastProposer(), alice);
        assertEq(validator.lastDescriptionHash(), keccak256(bytes("gated proposal")));
    }

    function test_proposeWithType_validatorRevert_blocksCreation() public {
        MockProposalValidator validator = new MockProposalValidator(address(governor), IVotes(address(token)));
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (IRuleset(address(validator)), VOTING_DELAY, VOTING_PERIOD, 0)),
            "register gated type"
        );
        uint8 id = governor.typeCount() - 1;
        validator.setShouldRevert(true);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _dummyAction();
        vm.prank(alice);
        vm.expectRevert(MockProposalValidator.ValidatorRejected.selector);
        governor.proposeWithType(t, v, c, "rejected", id);
    }

    function test_propose_ungatedType_neverCallsHook() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _dummyAction();
        vm.prank(alice);
        governor.propose(t, v, c, "plain"); // type 0, gated=false — must not revert / not call anything
    }

    function _dummyAction() internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory c) {
        t = new address[](1);
        t[0] = address(0xBEEF);
        v = new uint256[](1);
        c = new bytes[](1);
        c[0] = "";
    }
}
