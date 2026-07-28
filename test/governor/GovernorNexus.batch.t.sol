// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {console2} from "forge-std/console2.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {Box} from "../mocks/Box.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";
import {RulesetCounting} from "../../src/RulesetCounting.sol";
import {StandardRuleset} from "../../src/rulesets/StandardRuleset.sol";

/// @dev Batch voting suite for `castVoteWithReasonAndParamsBatch`. Extends the shared base:
///      alice (2_000_000e18) proposes; carol (30e18) is the batch voter, so most weight
///      assertions read 30e18 — except test_castVoteWithReasonAndParamsBatch_weightsFollowEachProposalsSnapshot,
///      which tops carol up mid-suite to prove per-item snapshot reads diverge. All-or-nothing
///      semantics, one nonce spend per batch, duplicates are intra-tx re-votes.
contract GovernorNexusBatchTest is GovernorNexusTestBase {
    address internal carol = makeAddr("carol");
    Box internal box;

    function setUp() public override {
        super.setUp();
        box = new Box(address(timelock));
        _fund(carol, 30e18);
        vm.roll(block.number + 1);
    }

    /// @dev Batch scenarios keep up to 5 of alice's proposals live at once (gas benchmark),
    ///      so the fixture cap must sit above that.
    function _maxActiveProposals() internal pure override returns (uint8) {
        return 10;
    }

    // ─────────────────────────── Helpers ───────────────────────────

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

    /// @dev Propose a box call as `typeId` and roll into the active window.
    function _proposeActive(uint256 newValue, string memory description, uint8 typeId)
        internal
        returns (uint256 proposalId)
    {
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _boxCall(newValue, description);
        vm.prank(alice);
        proposalId = governor.proposeWithType(t, v, c, description, typeId);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _supports(uint8 a, uint8 b) internal pure returns (uint8[] memory arr) {
        arr = new uint8[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _reasons(string memory a, string memory b) internal pure returns (string[] memory arr) {
        arr = new string[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _params(bytes memory a, bytes memory b) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // ─────────────────────────── 1. Happy path ───────────────────────────

    function test_castVoteWithReasonAndParamsBatch_votesOnMultipleProposals() public {
        uint256 p1 = _proposeActive(1, "batch 1", 0);
        uint256 p2 = _proposeActive(2, "batch 2", 0);

        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(carol, p1, 1, 30e18, "yes");
        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(carol, p2, 0, 30e18, "");

        vm.prank(carol);
        uint256[] memory weights = governor.castVoteWithReasonAndParamsBatch(
            _ids(p1, p2), _supports(1, 0), _reasons("yes", ""), _params("", "")
        );

        assertEq(weights.length, 2, "one weight per item");
        assertEq(weights[0], 30e18, "p1 weight");
        assertEq(weights[1], 30e18, "p2 weight");
        assertTrue(governor.hasVoted(p1, carol));
        assertTrue(governor.hasVoted(p2, carol));
        assertEq(standardRuleset.tally(p1, 1), 30e18, "For tally on p1");
        assertEq(standardRuleset.tally(p2, 0), 30e18, "Against tally on p2");
    }

    /// @dev The function returns an array because proposals have distinct snapshots →
    ///      potentially distinct weights. Prove it: carol's balance changes between the two proposals'
    ///      snapshots, so a single batch call must report two different weights, each read
    ///      at its own proposal's snapshot block.
    function test_castVoteWithReasonAndParamsBatch_weightsFollowEachProposalsSnapshot() public {
        uint256 p1 = _proposeActive(1, "early snap", 0); // rolls past p1's snapshot @ 30e18

        _fund(carol, 20e18); // total 50e18, re-delegated
        vm.roll(block.number + 1);

        uint256 p2 = _proposeActive(2, "late snap", 0); // rolls past p2's snapshot @ 50e18

        vm.prank(carol);
        uint256[] memory weights =
            governor.castVoteWithReasonAndParamsBatch(_ids(p1, p2), _supports(1, 1), _reasons("", ""), _params("", ""));

        assertEq(weights[0], 30e18, "p1 weight: pre-top-up snapshot");
        assertEq(weights[1], 50e18, "p2 weight: post-top-up snapshot");
        assertEq(standardRuleset.tally(p1, 1), 30e18, "p1 tally matches its own snapshot");
        assertEq(standardRuleset.tally(p2, 1), 50e18, "p2 tally matches its own snapshot");
    }

    // ─────────────────────────── 2. Guards ───────────────────────────

    function test_castVoteWithReasonAndParamsBatch_emptyBatchReverts() public {
        vm.expectRevert(GovernorNexus.EmptyBatch.selector);
        vm.prank(carol);
        governor.castVoteWithReasonAndParamsBatch(new uint256[](0), new uint8[](0), new string[](0), new bytes[](0));
    }

    function test_castVoteWithReasonAndParamsBatch_lengthMismatchReverts() public {
        // supports shorter
        vm.expectRevert(GovernorNexus.BatchLengthMismatch.selector);
        vm.prank(carol);
        governor.castVoteWithReasonAndParamsBatch(new uint256[](2), new uint8[](1), new string[](2), new bytes[](2));
        // reasons shorter
        vm.expectRevert(GovernorNexus.BatchLengthMismatch.selector);
        vm.prank(carol);
        governor.castVoteWithReasonAndParamsBatch(new uint256[](2), new uint8[](2), new string[](1), new bytes[](2));
        // params shorter
        vm.expectRevert(GovernorNexus.BatchLengthMismatch.selector);
        vm.prank(carol);
        governor.castVoteWithReasonAndParamsBatch(new uint256[](2), new uint8[](2), new string[](2), new bytes[](1));
    }

    // ─────────────────────────── 3. Nonce spend ───────────────────────────

    /// @dev A batch is a direct cast: it must invalidate the voter's outstanding signed
    ///      ballots, exactly like the single-vote nonce-spending overrides. Without this,
    ///      the batch path reintroduces the stale-ballot override: a relayer could land a
    ///      previously signed ballot on top of the voter's later direct vote.
    function test_castVoteWithReasonAndParamsBatch_invalidatesOutstandingSignedBallot() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        _fund(signer, 30e18);
        vm.roll(block.number + 1);

        uint256 p1 = _proposeActive(1, "batched direct vote", 0);
        uint256 p2 = _proposeActive(2, "held ballot", 0);

        // Signer hands a relayer a For ballot on p2, then changes their mind and
        // batch-votes (on p1 only — the nonce is account-global).
        bytes memory pendingFor = _signBallot(p2, 1, signer, signerKey, governor.nonces(signer));

        uint256[] memory ids = new uint256[](1);
        ids[0] = p1;
        uint8[] memory supportValues = new uint8[](1);
        string[] memory reasons = new string[](1);
        bytes[] memory params = new bytes[](1);
        vm.prank(signer);
        governor.castVoteWithReasonAndParamsBatch(ids, supportValues, reasons, params);

        // The outstanding ballot died with the batch.
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        governor.castVoteBySig(p2, 1, signer, pendingFor);
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────── 4. Duplicates & re-votes ───────────────────────

    /// @dev Under mutable votes a duplicate id inside one batch is a valid same-tx
    ///      re-vote, last-wins. Both entries emit VoteCast and both report a weight;
    ///      conservation holds (the first vote's weight is debited before the second
    ///      credits).
    function test_castVoteWithReasonAndParamsBatch_duplicateIdIsIntraTxRevote_lastWins() public {
        uint256 p1 = _proposeActive(1, "dup", 0);

        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(carol, p1, 1, 30e18, "first");
        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(carol, p1, 0, 30e18, "changed my mind");

        vm.prank(carol);
        uint256[] memory weights = governor.castVoteWithReasonAndParamsBatch(
            _ids(p1, p1), _supports(1, 0), _reasons("first", "changed my mind"), _params("", "")
        );

        assertEq(weights[0], 30e18);
        assertEq(weights[1], 30e18);
        assertEq(standardRuleset.tally(p1, 1), 0, "first vote debited (replace semantics)");
        assertEq(standardRuleset.tally(p1, 0), 30e18, "last wins");
        assertTrue(governor.hasVoted(p1, carol));
    }

    /// @dev A batch containing a proposal the voter already voted on singly is a re-vote
    ///      through the batch path — replace semantics hold end-to-end.
    function test_castVoteWithReasonAndParamsBatch_revotesOverEarlierSingleVote() public {
        uint256 p1 = _proposeActive(1, "revote via batch", 0);
        uint256 p2 = _proposeActive(2, "fresh", 0);

        vm.prank(carol);
        governor.castVote(p1, 1); // single For, 30e18

        vm.prank(carol);
        governor.castVoteWithReasonAndParamsBatch(_ids(p1, p2), _supports(0, 1), _reasons("", ""), _params("", ""));

        assertEq(standardRuleset.tally(p1, 1), 0, "single For debited by the batched re-vote");
        assertEq(standardRuleset.tally(p1, 0), 30e18, "batched Against stands");
        assertEq(standardRuleset.tally(p2, 1), 30e18, "fresh vote lands");
    }

    // ─────────────────────── 5. All-or-nothing ───────────────────────

    /// @dev One dead id (canceled between signing and inclusion) reverts the other item
    ///      too — no partial state. Recovery is resending without the dead id (idempotent
    ///      under mutable votes).
    function test_castVoteWithReasonAndParamsBatch_canceledItemRevertsWholeBatch() public {
        uint256 p1 = _proposeActive(1, "survives", 0);

        // p2 stays Pending so the proposer can still cancel it (stock OZ rule).
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _boxCall(2, "canceled");
        vm.prank(alice);
        uint256 p2 = governor.propose(t, v, c, "canceled");
        vm.roll(block.number + 1); // cancel is barred in the propose block; p2 still Pending
        vm.prank(alice);
        governor.cancel(t, v, c, h);
        vm.roll(governor.proposalSnapshot(p2) + 1); // p1 and p2 share timing; p1 active

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                p2,
                IGovernor.ProposalState.Canceled,
                bytes32(uint256(1) << uint8(IGovernor.ProposalState.Active))
            )
        );
        governor.castVoteWithReasonAndParamsBatch(_ids(p1, p2), _supports(1, 1), _reasons("", ""), _params("", ""));

        assertEq(standardRuleset.tally(p1, 1), 0, "no partial state: p1 vote rolled back");
        assertFalse(governor.hasVoted(p1, carol));
    }

    /// @dev Support validity is per-ruleset (_isValidSupport). A support value invalid for
    ///      one item's ruleset reverts the whole batch, including items whose support was
    ///      fine for THEIR ruleset.
    function test_castVoteWithReasonAndParamsBatch_mixedRulesets_invalidSupportRevertsAll() public {
        StandardRuleset rs1 = _newRuleset();
        _executeSelfCall(
            abi.encodeCall(GovernorNexus.registerType, (rs1, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD)),
            "register type 1"
        );

        uint256 p0 = _proposeActive(1, "type 0", 0);
        uint256 p1 = _proposeActive(2, "type 1", 1);

        vm.prank(carol);
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector);
        governor.castVoteWithReasonAndParamsBatch(_ids(p0, p1), _supports(1, 3), _reasons("", ""), _params("", ""));

        assertEq(standardRuleset.tally(p0, 1), 0, "valid item rolled back with the batch");
        assertEq(rs1.tally(p1, 1), 0);
    }

    // ─────────────────────── 6. Params passthrough ───────────────────────

    /// @dev Empty params[i] → stock VoteCast; non-empty → VoteCastWithParams (OZ's own
    ///      dispatch in _castVote — no code of ours). StandardRuleset ignores params, so
    ///      counting is identical either way.
    function test_castVoteWithReasonAndParamsBatch_paramsDispatchPerItem() public {
        uint256 p1 = _proposeActive(1, "plain", 0);
        uint256 p2 = _proposeActive(2, "with params", 0);

        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(carol, p1, 1, 30e18, "");
        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCastWithParams(carol, p2, 1, 30e18, "", hex"beef");

        vm.prank(carol);
        governor.castVoteWithReasonAndParamsBatch(
            _ids(p1, p2), _supports(1, 1), _reasons("", ""), _params("", hex"beef")
        );

        assertEq(standardRuleset.tally(p1, 1), 30e18);
        assertEq(standardRuleset.tally(p2, 1), 30e18, "params ignored by StandardRuleset counting");
    }

    // ─────────────────────── 7. Equivalence fuzz + gas ───────────────────────

    /// @dev State equivalence: a batch lands exactly the tallies a sequence of single
    ///      casts lands (same voter, same order). Includes duplicate ids (re-votes) and
    ///      the full support range via bounding.
    function testFuzz_castVoteWithReasonAndParamsBatch_equivalentToSingleCastSequence(
        uint8 s0,
        uint8 s1,
        uint8 s2,
        bool duplicate
    ) public {
        s0 = uint8(bound(s0, 0, 2));
        s1 = uint8(bound(s1, 0, 2));
        s2 = uint8(bound(s2, 0, 2));

        uint256 p1 = _proposeActive(1, "fuzz A", 0);
        uint256 p2 = _proposeActive(2, "fuzz B", 0);
        uint256 p3 = _proposeActive(3, "fuzz C", 0);

        uint256[] memory ids = new uint256[](3);
        ids[0] = p1;
        ids[1] = p2;
        ids[2] = duplicate ? p1 : p3; // false: three genuinely distinct proposals
        uint8[] memory supportValues = new uint8[](3);
        supportValues[0] = s0;
        supportValues[1] = s1;
        supportValues[2] = s2;
        string[] memory reasons = new string[](3);
        bytes[] memory params = new bytes[](3);

        uint256 snap = vm.snapshotState();

        vm.prank(carol);
        governor.castVoteWithReasonAndParamsBatch(ids, supportValues, reasons, params);
        uint256[9] memory batchTallies = _tallies(p1, p2, p3);

        vm.revertToState(snap);

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(carol);
            governor.castVote(ids[i], supportValues[i]);
        }
        uint256[9] memory singleTallies = _tallies(p1, p2, p3);

        for (uint256 i = 0; i < 9; ++i) {
            assertEq(batchTallies[i], singleTallies[i], "batch != sequence of singles");
        }
    }

    function _tallies(uint256 p1, uint256 p2, uint256 p3) internal view returns (uint256[9] memory t) {
        for (uint8 s = 0; s <= 2; ++s) {
            t[s] = standardRuleset.tally(p1, s);
            t[3 + s] = standardRuleset.tally(p2, s);
            t[6 + s] = standardRuleset.tally(p3, s);
        }
    }

    /// @dev In-EVM gas comparison. The batch saves (N-1) nonce bumps (one spend per batch
    ///      vs one per single cast) in-EVM, but the measured in-EVM delta can be slightly
    ///      negative (array ABI-decoding overhead can exceed those saved nonce bumps) — the
    ///      assertion below is intrinsic-adjusted, crediting the (N-1) avoided per-tx 21k
    ///      intrinsic costs that a single-EVM-call harness cannot otherwise see. Real-world
    ///      savings (avoided top-level calldata too) are larger than reported here.
    function test_castVoteWithReasonAndParamsBatch_gasComparedToSingles() public {
        uint256[] memory ids = new uint256[](5);
        uint8[] memory supportValues = new uint8[](5);
        string[] memory reasons = new string[](5);
        bytes[] memory params = new bytes[](5);
        for (uint256 i = 0; i < 5; ++i) {
            ids[i] = _proposeActive(i + 1, string(abi.encodePacked("gas ", bytes1(uint8(0x30 + i)))), 0);
            supportValues[i] = 1;
        }

        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        uint256 g0 = gasleft();
        governor.castVoteWithReasonAndParamsBatch(ids, supportValues, reasons, params);
        uint256 batchGas = g0 - gasleft();
        vm.revertToState(snap);

        uint256 singlesGas;
        for (uint256 i = 0; i < 5; ++i) {
            vm.prank(carol);
            g0 = gasleft();
            governor.castVote(ids[i], 1);
            singlesGas += g0 - gasleft();
        }

        console2.log("batch(5) gas:", batchGas);
        console2.log("5 singles gas:", singlesGas);
        // In-EVM, a batch can cost slightly MORE than N singles (array ABI-decoding overhead
        // exceeds the (N-1) saved nonce bumps). The real saving is off-EVM: (N-1) avoided
        // per-tx intrinsic costs (21k each) + top-level calldata. Assert the real-world win
        // with the intrinsic adjustment; the logs above report the exact numbers.
        assertLt(batchGas, singlesGas + 4 * 21_000, "batch must beat 5 singles once avoided intrinsic gas is counted");
    }
}
