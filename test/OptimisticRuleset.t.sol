// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IProposalValidator} from "../src/IProposalValidator.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {OptimisticRuleset} from "../src/OptimisticRuleset.sol";
import {RulesetCounting} from "../src/RulesetCounting.sol";

/// @dev Isolated unit suite. The ruleset reads nothing from its governor (no quorum, no
///      snapshot, no token), so a plain address suffices as the `onlyGovernor` caller —
///      pranking as it exercises the real authorization path. `admin` stands in for the
///      timelock the production deploy passes.
contract OptimisticRulesetTest is Test {
    uint256 internal constant VETO_THRESHOLD = 500_000e18;
    uint256 internal constant PROPOSAL_ID = 1;

    OptimisticRuleset internal ruleset;

    address internal governor = makeAddr("governor");
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    address internal target = makeAddr("target");
    bytes4 internal constant SELECTOR = bytes4(keccak256("store(uint256)"));

    function setUp() public {
        ruleset = new OptimisticRuleset(governor, admin, VETO_THRESHOLD);
    }

    function _countVote(address voter, uint8 support, uint256 weight) internal returns (uint256) {
        vm.prank(governor);
        return ruleset.countVote(PROPOSAL_ID, voter, support, weight, "");
    }

    function _allowProposer(address proposer) internal {
        vm.prank(admin);
        ruleset.setProposerAllowed(proposer, true);
    }

    function _allowAction(address target_, bytes4 selector) internal {
        vm.prank(admin);
        ruleset.setActionAllowed(target_, selector, true);
    }

    /// @dev A single-action proposal that clears every validation rule once `alice` and
    ///      `(target, SELECTOR)` are allowlisted.
    function _validArrays()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = target;
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SELECTOR, 42);
    }

    function _validate(address proposer, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
        internal
    {
        vm.prank(governor);
        ruleset.validateProposal(proposer, targets, values, calldatas);
    }

    // ─────────────────────────── Constructor ───────────────────────────

    function test_constructor_exposesImmutables() public view {
        assertEq(ruleset.governor(), governor);
        assertEq(ruleset.admin(), admin);
        assertEq(ruleset.vetoThreshold(), VETO_THRESHOLD);
    }

    function test_constructor_revertsOnZeroVetoThreshold() public {
        vm.expectRevert(OptimisticRuleset.VetoThresholdZero.selector);
        new OptimisticRuleset(governor, admin, 0);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(OptimisticRuleset.AdminZeroAddress.selector);
        new OptimisticRuleset(governor, address(0), VETO_THRESHOLD);
    }

    // ─────────────────────────── ERC165 ───────────────────────────

    function test_supportsInterface_ruleset() public view {
        assertTrue(ruleset.supportsInterface(type(IRuleset).interfaceId));
    }

    function test_supportsInterface_proposalValidator() public view {
        assertTrue(ruleset.supportsInterface(type(IProposalValidator).interfaceId));
    }

    function test_supportsInterface_erc165() public view {
        assertTrue(ruleset.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_rejectsUnknown() public view {
        assertFalse(ruleset.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ─────────────────────────── Outcome: quorum ───────────────────────────

    function test_quorumReached_trueWithNoVotes() public view {
        assertTrue(ruleset.quorumReached(PROPOSAL_ID));
    }

    function test_quorumReached_trueForUnknownId() public view {
        assertTrue(ruleset.quorumReached(0xdead), "no-revert contract: unknown ids answer from defaults");
    }

    function test_quorum_alwaysZero() public view {
        assertEq(ruleset.quorum(0), 0);
        assertEq(ruleset.quorum(block.number), 0);
    }

    // ─────────────────────────── Outcome: veto rule ───────────────────────────

    function test_voteSucceeded_trueWithNoVotes() public view {
        assertTrue(ruleset.voteSucceeded(PROPOSAL_ID), "pass-by-default: zero votes is a passing state");
    }

    function test_voteSucceeded_trueForUnknownId() public view {
        assertTrue(ruleset.voteSucceeded(0xbeef));
    }

    function test_voteSucceeded_trueJustBelowThreshold() public {
        _countVote(alice, 0, VETO_THRESHOLD - 1);
        assertTrue(ruleset.voteSucceeded(PROPOSAL_ID));
    }

    function test_voteSucceeded_falseAtExactThreshold() public {
        _countVote(alice, 0, VETO_THRESHOLD);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID), "Against == threshold must defeat (>= semantics)");
    }

    function test_voteSucceeded_falseAboveThreshold() public {
        _countVote(alice, 0, VETO_THRESHOLD + 1);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID));
    }

    function test_voteSucceeded_ignoresForAndAbstain() public {
        // For/Abstain weight is tallied but never outcome-bearing, in either direction.
        _countVote(alice, 1, 100 * VETO_THRESHOLD);
        _countVote(bob, 2, 100 * VETO_THRESHOLD);
        assertTrue(ruleset.voteSucceeded(PROPOSAL_ID));

        _countVote(stranger, 0, VETO_THRESHOLD);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID), "massive For support cannot save a vetoed proposal");
    }

    function test_vetoAccumulatesAcrossVoters() public {
        _countVote(alice, 0, VETO_THRESHOLD / 2);
        assertTrue(ruleset.voteSucceeded(PROPOSAL_ID));
        _countVote(bob, 0, VETO_THRESHOLD - VETO_THRESHOLD / 2);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID));
    }

    // ─────────────────────────── Withdrawable veto (re-votes) ───────────────────────────

    function test_voteSucceeded_vetoWithdrawalFlipsBackToPassing() public {
        _countVote(alice, 0, VETO_THRESHOLD);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID));

        _countVote(alice, 1, VETO_THRESHOLD); // withdraw the veto by re-voting For
        assertTrue(ruleset.voteSucceeded(PROPOSAL_ID), "veto is withdrawable: re-vote drains the Against bucket");
    }

    function test_voteSucceeded_revoteIntoVetoFlipsToFailing() public {
        _countVote(alice, 1, VETO_THRESHOLD);
        assertTrue(ruleset.voteSucceeded(PROPOSAL_ID));

        _countVote(alice, 0, VETO_THRESHOLD);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID), "non-monotonic in both directions");
    }

    // ─────────────────────────── Counting surface ───────────────────────────

    function test_countVote_acceptsAllThreeBravoOptions() public {
        _countVote(alice, 0, 1e18);
        _countVote(bob, 1, 2e18);
        _countVote(stranger, 2, 3e18);

        (uint256 against, uint256 forVotes, uint256 abstain) = ruleset.proposalVotes(PROPOSAL_ID);
        assertEq(against, 1e18);
        assertEq(forVotes, 2e18);
        assertEq(abstain, 3e18);
    }

    function test_countVote_revertsOnSupportAboveAbstain() public {
        vm.prank(governor);
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector);
        ruleset.countVote(PROPOSAL_ID, alice, 3, 1e18, "");
    }

    function test_countVote_revertsWhenCallerIsNotGovernor() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, stranger));
        ruleset.countVote(PROPOSAL_ID, alice, 0, 1e18, "");
    }

    function test_hasVoted_reflectsState() public {
        assertFalse(ruleset.hasVoted(PROPOSAL_ID, alice));
        _countVote(alice, 0, 1e18);
        assertTrue(ruleset.hasVoted(PROPOSAL_ID, alice));
    }

    function test_proposalVotes_zeroForUnknownId() public view {
        (uint256 against, uint256 forVotes, uint256 abstain) = ruleset.proposalVotes(0xdead);
        assertEq(against, 0);
        assertEq(forVotes, 0);
        assertEq(abstain, 0);
    }

    function test_countingMode() public view {
        assertEq(ruleset.COUNTING_MODE(), "support=bravo&quorum=against,for,abstain");
    }

    // ─────────────────────────── validateProposal: authorization ───────────────────────────

    function test_validateProposal_revertsWhenCallerIsNotGovernor() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, stranger));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    // ─────────────────────────── validateProposal: length check ───────────────────────────

    function test_validateProposal_revertsOnShorterValues() public {
        _allowProposer(alice);
        (address[] memory targets,, bytes[] memory calldatas) = _validArrays();
        uint256[] memory shortValues = new uint256[](0);

        vm.prank(governor);
        vm.expectRevert(OptimisticRuleset.LengthMismatch.selector);
        ruleset.validateProposal(alice, targets, shortValues, calldatas);
    }

    function test_validateProposal_revertsOnShorterCalldatas() public {
        _allowProposer(alice);
        (address[] memory targets, uint256[] memory values,) = _validArrays();
        bytes[] memory shortCalldatas = new bytes[](0);

        vm.prank(governor);
        vm.expectRevert(OptimisticRuleset.LengthMismatch.selector);
        ruleset.validateProposal(alice, targets, values, shortCalldatas);
    }

    function test_validateProposal_revertsOnShorterTargets() public {
        _allowProposer(alice);
        (, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        address[] memory shortTargets = new address[](0);

        vm.prank(governor);
        vm.expectRevert(OptimisticRuleset.LengthMismatch.selector);
        ruleset.validateProposal(alice, shortTargets, values, calldatas);
    }

    function test_validateProposal_lengthCheckRunsBeforeProposerCheck() public {
        // Non-allowlisted proposer AND mismatched lengths: the length diagnosis must win —
        // the validator relies on nothing having been indexed before this check.
        (address[] memory targets,, bytes[] memory calldatas) = _validArrays();
        uint256[] memory shortValues = new uint256[](0);

        vm.prank(governor);
        vm.expectRevert(OptimisticRuleset.LengthMismatch.selector);
        ruleset.validateProposal(stranger, targets, shortValues, calldatas);
    }

    /// @dev Any asymmetric length triple reverts `LengthMismatch` — never an out-of-bounds
    ///      panic, pinning that no array is indexed before the three-way check.
    function testFuzz_validateProposal_anyLengthMismatchRevertsCleanly(
        uint256 targetsLength,
        uint256 valuesLength,
        uint256 calldatasLength
    ) public {
        targetsLength = bound(targetsLength, 0, 6);
        valuesLength = bound(valuesLength, 0, 6);
        calldatasLength = bound(calldatasLength, 0, 6);
        vm.assume(!(targetsLength == valuesLength && valuesLength == calldatasLength));

        vm.prank(governor);
        vm.expectRevert(OptimisticRuleset.LengthMismatch.selector);
        ruleset.validateProposal(
            alice, new address[](targetsLength), new uint256[](valuesLength), new bytes[](calldatasLength)
        );
    }

    // ─────────────────────────── validateProposal: proposer allowlist ───────────────────────────

    function test_validateProposal_revertsOnNonAllowlistedProposer() public {
        _allowAction(target, SELECTOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ProposerNotAllowed.selector, alice));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    function test_validateProposal_revertsAfterProposerDisallowed() public {
        _allowProposer(alice);
        _allowAction(target, SELECTOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        _validate(alice, targets, values, calldatas); // passes while allowlisted

        vm.prank(admin);
        ruleset.setProposerAllowed(alice, false);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ProposerNotAllowed.selector, alice));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    // ─────────────────────────── validateProposal: per-action rules ───────────────────────────

    function test_validateProposal_revertsOnNonZeroValue() public {
        _allowProposer(alice);
        _allowAction(target, SELECTOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        values[0] = 1 wei;

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ValueNotAllowed.selector, 0));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    function test_validateProposal_revertsOnEmptyCalldata() public {
        _allowProposer(alice);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        calldatas[0] = "";

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.SelectorMissing.selector, 0));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    function test_validateProposal_revertsOnCalldataShorterThanSelector() public {
        _allowProposer(alice);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        calldatas[0] = hex"aabbcc"; // 3 bytes: no selector to check

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.SelectorMissing.selector, 0));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    function test_validateProposal_revertsOnNonAllowlistedAction() public {
        _allowProposer(alice);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ActionNotAllowed.selector, target, SELECTOR));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    function test_validateProposal_revertsOnAllowlistedSelectorAtDifferentTarget() public {
        // The allowlist key is the (target, selector) PAIR — the same selector at another
        // address is a different action.
        _allowProposer(alice);
        _allowAction(target, SELECTOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        address otherTarget = makeAddr("otherTarget");
        targets[0] = otherTarget;

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ActionNotAllowed.selector, otherTarget, SELECTOR));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    function test_validateProposal_reportsFailingIndexInMultiActionProposal() public {
        _allowProposer(alice);
        _allowAction(target, SELECTOR);

        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;
        uint256[] memory values = new uint256[](2);
        values[1] = 1 ether; // only the second action violates
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(SELECTOR, 1);
        calldatas[1] = abi.encodeWithSelector(SELECTOR, 2);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.ValueNotAllowed.selector, 1));
        ruleset.validateProposal(alice, targets, values, calldatas);
    }

    // ─────────────────────────── validateProposal: happy paths ───────────────────────────

    function test_validateProposal_passesWithAllRulesSatisfied() public {
        _allowProposer(alice);
        _allowAction(target, SELECTOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _validArrays();
        _validate(alice, targets, values, calldatas);
    }

    function test_validateProposal_emptyProposalPassesVacuously() public {
        // No actions, nothing to index — OZ's `_propose` rejects empty proposals downstream,
        // and nothing here depends on that ordering.
        _allowProposer(alice);
        _validate(alice, new address[](0), new uint256[](0), new bytes[](0));
    }

    function test_validateProposal_multiActionAllAllowlistedPasses() public {
        _allowProposer(alice);
        _allowAction(target, SELECTOR);
        bytes4 otherSelector = bytes4(keccak256("retrieve()"));
        _allowAction(target, otherSelector);

        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(SELECTOR, 7);
        calldatas[1] = abi.encodeWithSelector(otherSelector);

        _validate(alice, targets, values, calldatas);
    }

    // ─────────────────────────── Setters: authorization ───────────────────────────

    function test_setProposerAllowed_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, stranger));
        ruleset.setProposerAllowed(alice, true);
    }

    function test_setProposerAllowed_revertsForGovernor() public {
        // The governor is NOT the admin: governance executions come from the timelock.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, governor));
        ruleset.setProposerAllowed(alice, true);
    }

    function test_setActionAllowed_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, stranger));
        ruleset.setActionAllowed(target, SELECTOR, true);
    }

    // ─────────────────────────── Setters: writes + events ───────────────────────────

    function test_setProposerAllowed_writesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(ruleset));
        emit OptimisticRuleset.ProposerAllowedSet(alice, true);
        vm.prank(admin);
        ruleset.setProposerAllowed(alice, true);
        assertTrue(ruleset.allowedProposers(alice));

        vm.expectEmit(true, false, false, true, address(ruleset));
        emit OptimisticRuleset.ProposerAllowedSet(alice, false);
        vm.prank(admin);
        ruleset.setProposerAllowed(alice, false);
        assertFalse(ruleset.allowedProposers(alice));
    }

    function test_setActionAllowed_writesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(ruleset));
        emit OptimisticRuleset.ActionAllowedSet(target, SELECTOR, true);
        vm.prank(admin);
        ruleset.setActionAllowed(target, SELECTOR, true);
        assertTrue(ruleset.allowedActions(target, SELECTOR));

        vm.expectEmit(true, true, false, true, address(ruleset));
        emit OptimisticRuleset.ActionAllowedSet(target, SELECTOR, false);
        vm.prank(admin);
        ruleset.setActionAllowed(target, SELECTOR, false);
        assertFalse(ruleset.allowedActions(target, SELECTOR));
    }

    // ─────────────────────────── Setters: self-target refusal ───────────────────────────

    function test_setActionAllowed_refusesGovernorAsTarget() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.SelfTargetForbidden.selector, governor));
        ruleset.setActionAllowed(governor, SELECTOR, true);
    }

    function test_setActionAllowed_refusesAdminAsTarget() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.SelfTargetForbidden.selector, admin));
        ruleset.setActionAllowed(admin, SELECTOR, true);
    }

    function test_setActionAllowed_refusesSelfAsTarget() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.SelfTargetForbidden.selector, address(ruleset)));
        ruleset.setActionAllowed(address(ruleset), SELECTOR, true);
    }

    function test_setActionAllowed_refusalIsUnconditionalOnAllowedFlag() public {
        // Even a disable write is refused: a self-target entry can never exist, so there is
        // nothing to disable and the refusal keeps the invariant unconditional.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OptimisticRuleset.SelfTargetForbidden.selector, governor));
        ruleset.setActionAllowed(governor, SELECTOR, false);
    }
}
