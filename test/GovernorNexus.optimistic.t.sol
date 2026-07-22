// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {IProposalValidator} from "../src/IProposalValidator.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {OptimisticRuleset} from "../src/OptimisticRuleset.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";
import {Box} from "./mocks/Box.sol";

/// @dev Minimal well-formed ruleset base for the validator-gate mocks below: honest inert
///      counting surface, so each concrete mock differs from a plain ruleset by exactly its
///      one validator behavior.
abstract contract ValidatorMockBase is IRuleset {
    function countVote(uint256, address, uint8, uint256 weight, bytes calldata) external pure returns (uint256) {
        return weight;
    }

    function quorumReached(uint256) external pure returns (bool) {
        return false;
    }

    function voteSucceeded(uint256) external pure returns (bool) {
        return false;
    }

    function hasVoted(uint256, address) external pure returns (bool) {
        return false;
    }

    function quorum(uint256) external pure returns (uint256) {
        return 0;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo&quorum=for";
    }
}

/// @dev Attack: `validateProposal` always reverts — a poisoned gate. Containment expected:
///      only proposes of ITS OWN type brick; every other type is unaffected.
contract PoisonedValidatorRuleset is ValidatorMockBase, IProposalValidator {
    error ValidatorPoisoned();

    function validateProposal(address, address[] calldata, uint256[] calldata, bytes[] calldata) external pure {
        revert ValidatorPoisoned();
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IProposalValidator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Attack: `validateProposal` burns all forwarded gas. Same containment expectation.
contract GasBurnValidatorRuleset is ValidatorMockBase, IProposalValidator {
    function validateProposal(address, address[] calldata, uint256[] calldata, bytes[] calldata) external pure {
        for (uint256 i = 0;; ++i) {}
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IProposalValidator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev A ruleset whose ERC165 answer for `IProposalValidator` is MUTABLE — impossible for
///      the immutable rulesets the DAO actually registers, built here to pin that detection
///      happens once, at registration, and is never re-queried.
contract ToggleableValidatorRuleset is ValidatorMockBase, IProposalValidator {
    error ShouldNeverRun();

    bool public advertiseValidator;

    function setAdvertiseValidator(bool advertise) external {
        advertiseValidator = advertise;
    }

    /// @dev Would brick every propose if the gate ever became live for this type.
    function validateProposal(address, address[] calldata, uint256[] calldata, bytes[] calldata) external pure {
        revert ShouldNeverRun();
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (interfaceId == type(IProposalValidator).interfaceId) return advertiseValidator;
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Integration suite for the propose-time validation gate and the optimistic type:
///      `gated` detection/pinning at registration, validator revert propagation on the
///      gated propose path, byte-identical behavior for ungated types, the optimistic
///      end-to-end lifecycle (zero-vote success, veto defeat), the veto-withdrawal
///      interaction with the anti-snipe extension, and poisoned-validator containment.
contract GovernorNexusOptimisticTest is GovernorNexusTestBase {
    /// @dev OZ `GovernorPreventLateQuorum` event ABI, adopted verbatim by the extension.
    event ProposalExtended(uint256 indexed proposalId, uint64 extendedDeadline);

    uint256 internal constant VETO_THRESHOLD = 500_000e18;
    uint8 internal constant OPTIMISTIC_TYPE = 1;

    OptimisticRuleset internal optimistic;
    Box internal box;

    address internal bob = makeAddr("bob"); // vetoer, funded above the threshold

    function setUp() public virtual override {
        super.setUp();
        _fund(bob, 600_000e18);
        vm.roll(block.number + 1);

        box = new Box(address(timelock));
        optimistic = new OptimisticRuleset(address(governor), address(timelock), VETO_THRESHOLD);

        // Proposer threshold 0: under this ruleset the proposer gate is the allowlist, not
        // voting power (registration choice, mirroring the intended production line).
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (optimistic, VOTING_DELAY, VOTING_PERIOD, uint256(0))),
            "register optimistic type"
        );
        assertEq(governor.typeCount(), 2);
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _allowAlice() internal {
        vm.startPrank(address(timelock));
        optimistic.setProposerAllowed(alice, true);
        optimistic.setActionAllowed(address(box), Box.setValue.selector, true);
        vm.stopPrank();
    }

    function _boxProposal(uint256 newValue)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(box);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Box.setValue, (newValue));
    }

    /// @dev Propose `box.setValue(newValue)` through the optimistic type and roll into
    ///      Active. Returns the id and the ORIGINAL deadline.
    function _proposeOptimistic(uint256 newValue, string memory description)
        internal
        returns (uint256 id, uint256 originalDeadline)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(newValue);
        vm.prank(alice);
        id = governor.proposeWithType(targets, values, calldatas, description, OPTIMISTIC_TYPE);
        vm.roll(governor.proposalSnapshot(id) + 1);
        originalDeadline = governor.proposalDeadline(id);
    }

    function _vote(address voter, uint256 id, uint8 support) internal {
        vm.prank(voter);
        governor.castVote(id, support);
    }

    /// @dev Registers `ruleset` as the next type through the governance loop.
    function _registerRuleset(IRuleset ruleset, string memory description) internal returns (uint8 id) {
        id = governor.typeCount();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (ruleset, VOTING_DELAY, VOTING_PERIOD, uint256(0))), description
        );
    }

    // ─────────────────────────── gated detection at registration ───────────────────────────

    function test_registerType_pinsGatedTrueForValidatorRuleset() public view {
        assertTrue(governor.getTypeConfig(OPTIMISTIC_TYPE).gated);
    }

    function test_registerType_pinsGatedFalseForStandardRuleset() public view {
        assertFalse(governor.getTypeConfig(0).gated, "bootstrap standard type must not be gated");
    }

    function test_gatedIsPinnedAtRegistration_neverRequeried() public {
        ToggleableValidatorRuleset toggleable = new ToggleableValidatorRuleset();
        // Registered while NOT advertising the validator interface -> gated pinned false.
        uint8 typeId = _registerRuleset(toggleable, "register toggleable");
        assertFalse(governor.getTypeConfig(typeId).gated);

        // Flipping the advertisement afterwards must change nothing: the pinned line rules.
        toggleable.setAdvertiseValidator(true);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        vm.prank(alice);
        uint256 id = governor.proposeWithType(targets, values, calldatas, "post-flip propose", typeId);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
    }

    // ─────────────────────────── gated propose path ───────────────────────────

    function test_proposeWithType_revertsForNonAllowlistedProposer() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ProposerNotAllowed.selector, alice));
        governor.proposeWithType(targets, values, calldatas, "not allowlisted", OPTIMISTIC_TYPE);
    }

    function test_proposeWithType_revertsForOffListAction() public {
        vm.prank(address(timelock));
        optimistic.setProposerAllowed(alice, true);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticRuleset.ActionNotAllowed.selector, address(box), Box.setValue.selector)
        );
        governor.proposeWithType(targets, values, calldatas, "action off-list", OPTIMISTIC_TYPE);
    }

    function test_proposeWithType_revertsForNonZeroValue() public {
        _allowAlice();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        values[0] = 1 ether;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ValueNotAllowed.selector, 0));
        governor.proposeWithType(targets, values, calldatas, "value forbidden", OPTIMISTIC_TYPE);
    }

    function test_validatorRevertLeavesProposalUncreated() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        string memory description = "not allowlisted";
        uint256 wouldBeId = governor.hashProposal(targets, values, calldatas, keccak256(bytes(description)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ProposerNotAllowed.selector, alice));
        governor.proposeWithType(targets, values, calldatas, description, OPTIMISTIC_TYPE);

        assertEq(governor.proposalSnapshot(wouldBeId), 0, "rejected proposal must not exist");
    }

    function test_ungatedDefaultPathNeverTouchesValidator() public {
        // Same content, default (standard) type, no allowlist entries anywhere: must pass —
        // the gate belongs to the optimistic type alone.
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);
        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "standard path untouched");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
    }

    // ─────────────────────────── allowlists governed by the timelock ───────────────────────────

    function test_allowlistEntryLandsThroughFullGovernanceLoop() public {
        // The production path for "the DAO votes entries in": a standard proposal whose
        // action targets the ruleset's setter, executed by the timelock.
        address[] memory targets = new address[](1);
        targets[0] = address(optimistic);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(OptimisticRuleset.setProposerAllowed, (alice, true));
        string memory description = "allowlist alice as optimistic proposer";

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(id) + 1);
        _vote(alice, id, 1);
        vm.roll(governor.proposalDeadline(id) + 1);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertTrue(optimistic.allowedProposers(alice));
    }

    // ─────────────────────────── optimistic lifecycle e2e ───────────────────────────

    function test_e2e_zeroVoteProposalSucceedsAndExecutes() public {
        _allowAlice();
        (uint256 id,) = _proposeOptimistic(42, "zero-vote optimistic");

        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(
            uint8(governor.state(id)),
            uint8(IGovernor.ProposalState.Succeeded),
            "pass-by-default: zero votes cast, proposal succeeds"
        );

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(42);
        bytes32 descriptionHash = keccak256(bytes("zero-vote optimistic"));
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(box.value(), 42, "optimistic path must actually execute");
    }

    function test_e2e_vetoAtThresholdDefeats() public {
        _allowAlice();
        (uint256 id,) = _proposeOptimistic(7, "vetoed optimistic");

        _vote(bob, id, 0); // 600k Against >= 500k threshold

        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_e2e_forVotesDoNotSaveVetoedProposal() public {
        _allowAlice();
        (uint256 id,) = _proposeOptimistic(7, "for votes irrelevant");

        _vote(alice, id, 1); // 2M For
        _vote(bob, id, 0); // 600k Against — veto wins regardless

        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ─────────────────────── veto withdrawal × anti-snipe extension ───────────────────────

    function test_earlyVetoWithdrawal_noExtension() public {
        _allowAlice();
        (uint256 id, uint256 originalDeadline) = _proposeOptimistic(1, "early veto in and out");

        // Veto placed and withdrawn BEFORE the final window: no failing state is observed
        // in-window, so no extension arms.
        vm.roll(originalDeadline - EXTENSION_WINDOW - 5);
        _vote(bob, id, 0);
        _vote(bob, id, 1);

        vm.roll(originalDeadline + 1);
        assertEq(governor.proposalDeadline(id), originalDeadline, "no in-window failing witness, no extension");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_lateVetoWithdrawal_extendsAndSucceedsIfNotReVetoed() public {
        _allowAlice();
        (uint256 id, uint256 originalDeadline) = _proposeOptimistic(1, "late veto withdrawal");

        // Veto lands inside the final window (proposal observed failing), then the vetoer
        // withdraws — the D53 snipe shape the extension exists for.
        vm.roll(originalDeadline - 5);
        _vote(bob, id, 0);
        _vote(bob, id, 1);

        vm.roll(originalDeadline + 1);
        assertEq(
            governor.proposalDeadline(id),
            originalDeadline + EXTENSION_DURATION,
            "failing->passing flip inside the window must extend voting"
        );
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active), "extension keeps voting open");

        vm.roll(originalDeadline + EXTENSION_DURATION + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_lateVetoWithdrawal_reVetoDuringExtensionDefeats() public {
        _allowAlice();
        (uint256 id, uint256 originalDeadline) = _proposeOptimistic(1, "re-veto during extension");

        vm.roll(originalDeadline - 5);
        _vote(bob, id, 0);
        _vote(bob, id, 1);

        // First cast past the original deadline materializes the extension (event emitted),
        // and the re-assembled veto inside the extension defeats the proposal.
        vm.roll(originalDeadline + 1);
        vm.expectEmit(true, false, false, true, address(governor));
        // forge-lint: disable-next-line(unsafe-typecast)
        emit ProposalExtended(id, uint64(originalDeadline + EXTENSION_DURATION));
        _vote(bob, id, 0);

        vm.roll(originalDeadline + EXTENSION_DURATION + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ─────────────────────────── poisoned validator containment ───────────────────────────

    function test_poisonedValidator_bricksOnlyItsOwnType() public {
        PoisonedValidatorRuleset poisoned = new PoisonedValidatorRuleset();
        uint8 poisonedType = _registerRuleset(poisoned, "register poisoned validator");
        assertTrue(governor.getTypeConfig(poisonedType).gated);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);

        // Its own type: propose bricked (revert IS the gate's behavior, blast radius = itself).
        vm.prank(alice);
        vm.expectRevert(PoisonedValidatorRuleset.ValidatorPoisoned.selector);
        governor.proposeWithType(targets, values, calldatas, "poisoned type", poisonedType);

        // Default type and the healthy gated type: unaffected.
        vm.prank(alice);
        governor.propose(targets, values, calldatas, "default path alive");

        _allowAlice();
        (address[] memory t2, uint256[] memory v2, bytes[] memory c2) = _boxProposal(2);
        vm.prank(alice);
        governor.proposeWithType(t2, v2, c2, "healthy gated type alive", OPTIMISTIC_TYPE);
    }

    function test_gasBurnValidator_bricksOnlyItsOwnType() public {
        GasBurnValidatorRuleset gasBurner = new GasBurnValidatorRuleset();
        uint8 burnType = _registerRuleset(gasBurner, "register gas burner");

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _boxProposal(1);

        vm.prank(alice);
        vm.expectRevert();
        governor.proposeWithType{gas: 2_000_000}(targets, values, calldatas, "gas burn type", burnType);

        vm.prank(alice);
        governor.propose(targets, values, calldatas, "default path alive after burn");
    }
}
