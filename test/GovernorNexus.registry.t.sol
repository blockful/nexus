// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {MockENSToken} from "./mocks/MockENSToken.sol";

/// @dev Test-only harness: supplies working `GovernorCountingSimple` counting so the full
///      governance loop (propose → vote → queue → execute) can run. Production
///      `GovernorNexus` keeps its Task 4 revert stubs; this exists ONLY to reach the
///      `onlyGovernance` setters through real execution. The registry surface under test is
///      100% `GovernorNexus`.
contract GovernorNexusHarness is GovernorNexus, GovernorCountingSimple {
    constructor(
        IVotes token,
        TimelockController timelock,
        IRuleset standardRuleset,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_
    ) GovernorNexus(token, timelock, standardRuleset, votingDelay_, votingPeriod_, proposalThreshold_) {}

    function quorum(uint256) public pure override(Governor, GovernorNexus) returns (uint256) {
        return 1; // trivial: any cast vote clears it
    }

    function proposalThreshold() public view override(Governor, GovernorNexus) returns (uint256) {
        return super.proposalThreshold();
    }

    function COUNTING_MODE() public pure override(GovernorNexus, GovernorCountingSimple) returns (string memory) {
        return GovernorCountingSimple.COUNTING_MODE();
    }

    function hasVoted(uint256 proposalId, address account)
        public
        view
        override(GovernorNexus, GovernorCountingSimple)
        returns (bool)
    {
        return GovernorCountingSimple.hasVoted(proposalId, account);
    }

    function _quorumReached(uint256 proposalId)
        internal
        view
        override(GovernorNexus, GovernorCountingSimple)
        returns (bool)
    {
        return GovernorCountingSimple._quorumReached(proposalId);
    }

    function _voteSucceeded(uint256 proposalId)
        internal
        view
        override(GovernorNexus, GovernorCountingSimple)
        returns (bool)
    {
        return GovernorCountingSimple._voteSucceeded(proposalId);
    }

    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params)
        internal
        override(GovernorNexus, GovernorCountingSimple)
        returns (uint256)
    {
        return GovernorCountingSimple._countVote(proposalId, account, support, weight, params);
    }

    // Diamond re-resolution: GovernorNexus's timelock disambiguation vs the Governor copy
    // reached through GovernorCountingSimple. `super` routes back to GovernorNexus.

    function state(uint256 proposalId) public view override(Governor, GovernorNexus) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorNexus) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorNexus) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorNexus) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorNexus) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorNexus) returns (address) {
        return super._executor();
    }
}

/// @dev Supports ERC165 but NOT IRuleset — exercises the "165 but wrong interface" guardrail.
contract Mock165 is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Plain contract with no ERC165 at all.
contract NotARuleset {}

contract GovernorNexusRegistryTest is Test {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 50;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;

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

    MockENSToken internal token;
    TimelockController internal timelock;
    GovernorNexusHarness internal governor;
    StandardRuleset internal standardRuleset;

    address internal alice = makeAddr("alice"); // proposer + majority voter
    address internal eoa = makeAddr("eoa"); // unauthorized caller

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);

        token = new MockENSToken();
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), new address[](0), address(this));

        // Governor arg is irrelevant to the registry (never calls countVote here).
        standardRuleset = new StandardRuleset(address(0xBEEF), IVotes(address(token)), 1);

        governor = new GovernorNexusHarness(
            IVotes(address(token)), timelock, standardRuleset, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        _fund(alice, 2_000_000e18);
        vm.roll(block.number + 1);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.delegate(account);
    }

    /// @dev Deploys a fresh StandardRuleset (a valid IRuleset) for registration tests.
    function _newRuleset() internal returns (StandardRuleset) {
        return new StandardRuleset(address(governor), IVotes(address(token)), 1);
    }

    // ───────────────── Governance loop (the only path to the setters) ─────────────────

    /// @dev Propose (self-call) → vote → queue → warp past timelock; leaves the proposal
    ///      ready to `execute`. Caller executes so it can wrap `execute` with expectEmit /
    ///      expectRevert as needed.
    function _prepareSelfCall(bytes memory data, string memory description)
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = data;
        descriptionHash = keccak256(bytes(description));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
    }

    /// @dev Full loop including a successful execute.
    function _executeSelfCall(bytes memory data, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _prepareSelfCall(data, description);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

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
        new GovernorNexusHarness(
            IVotes(address(token)), timelock, standardRuleset, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD
        );
    }

    function test_constructor_revertsOnZeroRuleset() public {
        vm.expectRevert(GovernorNexus.RulesetZeroAddress.selector);
        new GovernorNexusHarness(
            IVotes(address(token)), timelock, IRuleset(address(0)), VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD
        );
    }

    function test_constructor_revertsOnZeroVotingPeriod() public {
        vm.expectRevert(GovernorNexus.InvalidVotingPeriod.selector);
        new GovernorNexusHarness(IVotes(address(token)), timelock, standardRuleset, VOTING_DELAY, 0, PROPOSAL_THRESHOLD);
    }

    function test_constructor_revertsOnNonRulesetInterface() public {
        Mock165 notRuleset = new Mock165();
        vm.expectRevert(abi.encodeWithSelector(GovernorNexus.RulesetInterfaceUnsupported.selector, address(notRuleset)));
        new GovernorNexusHarness(
            IVotes(address(token)),
            timelock,
            IRuleset(address(notRuleset)),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD
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
            abi.encodeCall(GovernorNexus.registerType, (rs2, uint48(2), uint32(9), uint256(1))), "register type 2"
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
        _executeSelfCall(abi.encodeCall(GovernorNexus.registerType, (rs, uint48(9), uint32(9), uint256(9))), "reg");
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
        _executeSelfCall(abi.encodeCall(GovernorNexus.registerType, (rs, uint48(3), uint32(11), uint256(5))), "reg");

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _prepareSelfCall(abi.encodeCall(GovernorNexus.setDefaultType, (uint8(1))), "default to 1");
        vm.expectEmit(true, false, false, false, address(governor));
        emit DefaultTypeSet(1);
        governor.execute(t, v, c, h);

        assertEq(governor.defaultTypeId(), 1);
        // Default-type views now read row 1.
        assertEq(governor.votingDelay(), 3);
        assertEq(governor.votingPeriod(), 11);
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
}
