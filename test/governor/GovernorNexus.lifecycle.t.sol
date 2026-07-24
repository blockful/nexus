// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {IRuleset} from "../../src/interfaces/IRuleset.sol";
import {RulesetCounting} from "../../src/RulesetCounting.sol";
import {StandardRuleset} from "../../src/rulesets/StandardRuleset.sol";
import {Box} from "../mocks/Box.sol";
import {MockENSToken} from "../mocks/MockENSToken.sol";

/// @dev Full-lifecycle suite for GovernorNexus with real ruleset dispatch. Unlike the
///      registry/propose suites (which use a trivial harness fixture), this deploys plain
///      GovernorNexus and drives propose → vote → queue → execute end to end so that the
///      counting hooks — dispatched to the pinned `StandardRuleset` — are actually exercised.
///
///      Vote weights are round numbers on a 100e18 total supply so quorum math reads
///      directly: type 0 is a 20% ruleset (quorum = 20e18), type 1 a 60% ruleset
///      (quorum = 60e18). Every voter delegates to self, so `getPastTotalSupply` == 100e18.
contract GovernorNexusLifecycleTest is Test {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 50;
    uint256 internal constant PROPOSAL_THRESHOLD = 1e18;
    uint48 internal constant EXTENSION_WINDOW = 20;
    uint48 internal constant EXTENSION_DURATION = 40;

    uint256 internal constant Q0_NUMERATOR = 20; // default type: quorum = 20e18
    uint256 internal constant Q1_NUMERATOR = 60; // second type: quorum = 60e18

    MockENSToken internal token;
    TimelockController internal timelock;
    GovernorNexus internal governor;
    StandardRuleset internal standardRuleset;
    Box internal box;

    // Balances chosen so quorum/success scenarios have integer thresholds.
    address internal alice = makeAddr("alice"); // 50e18 — proposer + For majority
    address internal bob = makeAddr("bob"); // 10e18 — For, below quorum alone
    address internal carol = makeAddr("carol"); // 15e18 — Abstain
    address internal dave = makeAddr("dave"); // 5e18 — Against
    address internal eve = makeAddr("eve"); // 20e18 — inert supply
    address internal eoa = makeAddr("eoa"); // unauthorized caller

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);

        token = new MockENSToken();
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), new address[](0), address(this));

        // Wiring: StandardRuleset.countVote is onlyGovernor and
        // quorumReached reads governor.proposalSnapshot, so the ruleset must be constructed
        // with the governor's address. The governor's constructor in turn needs the ruleset,
        // so we precompute the governor's CREATE address (next nonce + 1) and hand it to the
        // ruleset, then assert the prediction held.
        address predictedGovernor = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        standardRuleset = new StandardRuleset(predictedGovernor, IVotes(address(token)), Q0_NUMERATOR);
        governor = new GovernorNexus(
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
        require(address(governor) == predictedGovernor, "governor address prediction failed");

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        box = new Box(address(timelock));

        _fund(alice, 50e18);
        _fund(bob, 10e18);
        _fund(carol, 15e18);
        _fund(dave, 5e18);
        _fund(eve, 20e18); // total supply == 100e18
        vm.roll(block.number + 1);
    }

    // ─────────────────────────── Helpers ───────────────────────────

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.delegate(account);
    }

    function _boxCall(uint256 newValue, string memory description)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(box);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Box.setValue, (newValue));
        descriptionHash = keccak256(bytes(description));
    }

    /// @dev Propose a box call and roll to the active window so votes can be cast.
    function _proposeActive(uint256 newValue, string memory description, uint8 typeId)
        internal
        returns (uint256 proposalId, address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h)
    {
        (t, v, c, h) = _boxCall(newValue, description);
        vm.prank(alice);
        proposalId = governor.proposeWithType(t, v, c, description, typeId);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
    }

    function _vote(uint256 proposalId, address voter, uint8 support) internal {
        vm.prank(voter);
        governor.castVote(proposalId, support);
    }

    function _state(uint256 proposalId) internal view returns (IGovernor.ProposalState) {
        return governor.state(proposalId);
    }

    /// @dev Drive a governance self-call fully (propose → vote → queue → execute) via alice,
    ///      whose 50e18 clears the 20e18 default-type quorum. Used to reach `onlyGovernance`.
    function _governanceExecute(bytes memory data, string memory description) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        _vote(proposalId, alice, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    /// @dev Register a second type (60% ruleset) and return its ruleset instance.
    function _registerType1() internal returns (StandardRuleset rs1) {
        rs1 = new StandardRuleset(address(governor), IVotes(address(token)), Q1_NUMERATOR);
        _governanceExecute(
            abi.encodeCall(GovernorNexus.registerType, (rs1, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD)),
            "register type 1"
        );
    }

    // ─────────────────────── 1. Full happy path ───────────────────────

    function test_fullLifecycle_proposeVoteQueueExecute() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _boxCall(42, "set 42");

        vm.prank(alice);
        uint256 proposalId = governor.propose(t, v, c, "set 42");
        assertEq(uint8(_state(proposalId)), uint8(IGovernor.ProposalState.Pending));
        assertEq(governor.proposalSnapshot(proposalId), block.number + VOTING_DELAY);

        // hasVoted is false on the governor surface before the vote lands.
        assertFalse(governor.hasVoted(proposalId, alice));

        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        assertEq(uint8(_state(proposalId)), uint8(IGovernor.ProposalState.Active));

        uint256 weightCounted = _voteReturning(proposalId, alice, 1);
        // Weight counted equals alice's past votes at the frozen snapshot.
        assertEq(weightCounted, token.getPastVotes(alice, governor.proposalSnapshot(proposalId)));
        assertEq(weightCounted, 50e18);

        // hasVoted flips through the ruleset dispatch, visible on the governor surface.
        assertTrue(governor.hasVoted(proposalId, alice));
        assertTrue(standardRuleset.hasVoted(proposalId, alice));

        vm.roll(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(_state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        governor.queue(t, v, c, h);
        assertEq(uint8(_state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(t, v, c, h);
        assertEq(box.value(), 42);
        assertEq(uint8(_state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function _voteReturning(uint256 proposalId, address voter, uint8 support) internal returns (uint256) {
        vm.prank(voter);
        return governor.castVote(proposalId, support);
    }

    // ─────────────────────── 2. Counting states through the ruleset ───────────────────────

    /// @dev against > for defeats the proposal even though quorum is reached (For+Abstain),
    ///      isolating the success rule (for > against) from the quorum rule.
    function test_defeated_againstExceedsFor_evenWithQuorumReached() public {
        (uint256 id,,,,) = _proposeActive(1, "against wins", 0);
        _vote(id, bob, 1); // For 10e18
        _vote(id, carol, 2); // Abstain 15e18  → For+Abstain = 25e18 ≥ 20e18 quorum
        _vote(id, alice, 0); // Against 50e18  → against > for

        assertTrue(standardRuleset.quorumReached(id)); // quorum IS met (abstain counts)
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Defeated)); // but against > for
    }

    function test_defeated_whenQuorumNotReached() public {
        (uint256 id,,,,) = _proposeActive(1, "no quorum", 0);
        _vote(id, bob, 1); // For 10e18 only — below the 20e18 quorum

        assertFalse(standardRuleset.quorumReached(id));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    /// @dev Abstain counts toward quorum but NOT toward success: For alone (10e18) is below
    ///      quorum, For+Abstain (25e18) clears it, and For > Against, so the proposal passes.
    function test_succeeded_abstainCountsTowardQuorumNotSuccess() public {
        (uint256 id,,,,) = _proposeActive(1, "abstain carries quorum", 0);
        _vote(id, bob, 1); // For 10e18
        _vote(id, carol, 2); // Abstain 15e18
        _vote(id, dave, 0); // Against 5e18

        uint256 snapshot = governor.proposalSnapshot(id);
        uint256 quorumValue = standardRuleset.quorum(snapshot);
        assertEq(quorumValue, 20e18);
        // The distinction: For alone would NOT reach quorum; only For+Abstain does.
        assertLt(10e18, quorumValue); // For (10e18) < quorum
        assertGe(10e18 + 15e18, quorumValue); // For + Abstain (25e18) ≥ quorum

        assertTrue(standardRuleset.quorumReached(id));
        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    // ─────────────────────── 3. Revote replaces ───────────────────────

    /// @dev End-to-end proof that the outcome follows the *standing* votes: alice (50e18) carries
    ///      the proposal, then re-votes Against — at the deadline the proposal is Defeated, the
    ///      For bucket holding only bob's weight.
    function test_revote_outcomeFollowsTheLatestVote() public {
        (uint256 id,,,,) = _proposeActive(1, "revote decides", 0);
        _vote(id, alice, 1); // For 50e18
        _vote(id, bob, 1); // For 10e18  → For 60e18, quorum (20e18) reached, succeeding
        assertTrue(standardRuleset.voteSucceeded(id));

        _vote(id, alice, 0); // alice re-votes Against 50e18 → For 10e18, Against 50e18

        (uint256 against, uint256 for_,) = standardRuleset.proposalVotes(id);
        assertEq(for_, 10e18, "alice's weight left the For bucket");
        assertEq(against, 50e18, "and landed in Against: counted once, not twice");
        assertTrue(governor.hasVoted(id, alice), "hasVoted means 'has a standing vote'");

        vm.roll(governor.proposalDeadline(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    /// @dev No new event — the core re-emits stock `VoteCast` on every cast, so an indexer's
    ///      rule is "latest VoteCast per (proposal, voter), in log order, is canonical".
    function test_revote_emitsVoteCastAgain() public {
        (uint256 id,,,,) = _proposeActive(1, "revote emits", 0);
        _vote(id, alice, 1);

        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(alice, id, 0, 50e18, "");
        vm.prank(alice);
        governor.castVote(id, 0);
    }

    /// @dev The ruleset never reads the clock — the core's Active-state gate is what closes
    ///      the re-vote window, exactly as it closes the first-vote window.
    function test_revote_afterDeadline_revertsInTheCore() public {
        (uint256 id,,,,) = _proposeActive(1, "revote too late", 0);
        _vote(id, alice, 1);

        vm.roll(governor.proposalDeadline(id) + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                id,
                IGovernor.ProposalState.Succeeded, // alice's 50e18 For cleared the 20e18 quorum
                bytes32(1 << uint8(IGovernor.ProposalState.Active))
            )
        );
        governor.castVote(id, 0);
    }

    /// @dev An already-submitted `castVoteBySig` ballot cannot be replayed: OZ v5 consumes the
    ///      voter's EIP-712 nonce during signature validation, so the second submission of the same
    ///      signature reverts. (This half was always foreclosed by OZ — the re-vote-specific half
    ///      is the next test.)
    function test_usedSignatureCannotBeReplayed() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        _fund(signer, 30e18);
        vm.roll(block.number + 1);

        (uint256 id,,,,) = _proposeActive(1, "sig replay", 0);

        bytes memory ballotFor = _signBallot(id, 1, signer, signerKey, governor.nonces(signer));
        governor.castVoteBySig(id, 1, signer, ballotFor);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        governor.castVoteBySig(id, 1, signer, ballotFor); // same signature, nonce already spent
    }

    /// @dev The stale-pre-signed-ballot override. A voter signs a gasless
    ///      ballot and hands it to a relayer, but then changes their mind and votes directly. Under
    ///      mutable votes the last-applied cast wins, so without a defense the relayer could submit
    ///      the outstanding signature AFTERWARD to override the voter's direct vote. GovernorNexus
    ///      closes it by spending the voter's nonce on every direct cast: a direct vote invalidates
    ///      any outstanding signed ballot, so the relayer's stale ballot reverts.
    function test_directVote_invalidatesOutstandingSignedBallot() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        _fund(signer, 30e18);
        vm.roll(block.number + 1);

        (uint256 id,,,,) = _proposeActive(1, "stale sig override", 0);

        // Voter signs a For ballot for the relayer but does NOT submit it.
        bytes memory pendingFor = _signBallot(id, 1, signer, signerKey, governor.nonces(signer));

        // Voter changes their mind and votes Against directly.
        vm.prank(signer);
        governor.castVote(id, 0);

        // The outstanding signature can no longer override the direct vote.
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        governor.castVoteBySig(id, 1, signer, pendingFor);

        (uint256 against, uint256 for_,) = standardRuleset.proposalVotes(id);
        assertEq(for_, 0, "the pending For ballot cannot override the direct vote");
        assertEq(against, 30e18, "the direct Against vote stands");
    }

    /// @dev Accepted cost of the account-global nonce: a direct vote on ONE
    ///      proposal also invalidates the voter's outstanding signed ballots on OTHER open
    ///      proposals, because OZ's vote nonce is per-account, not per-proposal. Deliberate
    ///      trade-off — per-proposal scoping would change the relayer's signing scheme.
    function test_directVote_invalidatesOutstandingSignaturesAcrossProposals() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        _fund(signer, 30e18);
        vm.roll(block.number + 1);

        (uint256 idA,,,,) = _proposeActive(1, "proposal A", 0);
        (uint256 idB,,,,) = _proposeActive(2, "proposal B", 0);

        // Voter signs a gasless ballot for proposal B and holds it.
        bytes memory pendingB = _signBallot(idB, 1, signer, signerKey, governor.nonces(signer));

        // Voter votes directly on proposal A — spends the account-global nonce.
        vm.prank(signer);
        governor.castVote(idA, 1);

        // The ballot for B, signed against the now-spent nonce, is invalid too.
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        governor.castVoteBySig(idB, 1, signer, pendingB);
    }

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
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────── 4. Invalid support value ───────────────────────

    function test_invalidSupport_reverts() public {
        (uint256 id,,,,) = _proposeActive(1, "bad support", 0);

        vm.prank(alice);
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector);
        governor.castVote(id, 3);
    }

    // ─────────────────────── 5. Two types, isolated tallies ───────────────────────

    /// @dev Same voter, same cast weight (alice, 50e18), on one proposal per type: the 20%
    ///      ruleset passes it, the 60% ruleset defeats it, and each ruleset only knows its
    ///      own proposal's tally.
    function test_twoTypes_isolatedTalliesAndDifferingQuorumOutcomes() public {
        StandardRuleset rs1 = _registerType1();

        (uint256 id0,,,,) = _proposeActive(1, "type-0 proposal", 0);
        (uint256 id1,,,,) = _proposeActive(2, "type-1 proposal", 1);

        _vote(id0, alice, 1); // 50e18 For, counted by standardRuleset (20% → quorum 20e18)
        _vote(id1, alice, 1); // 50e18 For, counted by rs1 (60% → quorum 60e18)

        // Tallies land in the right ruleset only.
        assertTrue(standardRuleset.hasVoted(id0, alice));
        assertFalse(standardRuleset.hasVoted(id1, alice));
        assertTrue(rs1.hasVoted(id1, alice));
        assertFalse(rs1.hasVoted(id0, alice));

        // Same cast weight, differing quorum outcomes.
        assertTrue(standardRuleset.quorumReached(id0)); // 50e18 ≥ 20e18
        assertFalse(rs1.quorumReached(id1)); // 50e18 < 60e18

        // id1 was proposed one active-window later, so it has the later deadline; roll past it.
        vm.roll(governor.proposalDeadline(id1) + 1);
        assertEq(uint8(_state(id0)), uint8(IGovernor.ProposalState.Succeeded));
        assertEq(uint8(_state(id1)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ─────────────────────── 6. Per-proposal introspection ───────────────────────

    function test_perProposalIntrospection_countingModeAndQuorum() public {
        StandardRuleset rs1 = _registerType1();
        (uint256 id1,,,,) = _proposeActive(1, "typed introspection", 1);

        // Per-proposal mode reachable through the proposal's own ruleset.
        assertEq(governor.proposalRuleset(id1).COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertEq(address(governor.proposalRuleset(id1)), address(rs1));

        // Global default-type views reflect the default (type 0) ruleset.
        assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        uint256 tp = governor.clock() - 1;
        assertEq(governor.quorum(tp), standardRuleset.quorum(tp));
    }

    // ─────────────────────── 7. Third party cannot stuff the ruleset ───────────────────────

    /// @dev Direct countVote from an EOA against the REAL wired governor reverts Unauthorized:
    ///      only the governor (msg.sender == standardRuleset.governor()) may tally.
    function test_thirdPartyCannotStuffRuleset_unauthorized() public {
        (uint256 id,,,,) = _proposeActive(1, "no stuffing", 0);
        assertEq(standardRuleset.governor(), address(governor));

        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, eoa));
        standardRuleset.countVote(id, eoa, 1, 1_000e18, "");
    }
}
