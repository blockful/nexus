// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {RulesetCounting} from "../src/RulesetCounting.sol";

/// @dev Concrete stand-in for the abstract base: the mutable-vote counting mechanics live
///      entirely in `RulesetCounting`, so a ruleset whose *rules* are stubs is enough to
///      exercise them in isolation. Real rulesets (StandardRuleset) layer quorum/success on top.
contract CountingHarness is RulesetCounting {
    constructor(address governor_) RulesetCounting(governor_) {}

    /// @dev The three Bravo options, as StandardRuleset defines them.
    function _isValidSupport(uint8 support) internal pure override returns (bool) {
        return support <= 2;
    }

    /// @dev All three buckets at once, so tests can assert conservation in one read.
    function tallies(uint256 proposalId) external view returns (uint256, uint256, uint256) {
        return (tally(proposalId, 0), tally(proposalId, 1), tally(proposalId, 2));
    }

    // Rule stubs — not under test here; the rules live in the concrete rulesets.

    function quorumReached(uint256) external pure returns (bool) {
        return false;
    }

    function voteSucceeded(uint256) external pure returns (bool) {
        return false;
    }

    function quorum(uint256) external pure returns (uint256) {
        return 0;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

/// @dev A ruleset with a FOURTH option, standing in for the Bond ruleset (No+Slash).
///      The base must count it without a storage-layout change — otherwise "the counting layer
///      every ruleset shares" is only true for the three-bucket rulesets.
contract FourOptionHarness is RulesetCounting {
    uint8 internal constant NO_AND_SLASH = 3;

    constructor(address governor_) RulesetCounting(governor_) {}

    function _isValidSupport(uint8 support) internal pure override returns (bool) {
        return support <= NO_AND_SLASH;
    }

    function quorumReached(uint256) external pure returns (bool) {
        return false;
    }

    function voteSucceeded(uint256) external pure returns (bool) {
        return false;
    }

    function quorum(uint256) external pure returns (uint256) {
        return 0;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo,slash&quorum=for,abstain";
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

/// @dev Unit suite for the shared mutable-vote counting base.
///      The governor is a plain address pranked as the caller — the base's only external
///      dependency is `onlyGovernor`, so no governor implementation is needed here.
contract RulesetCountingTest is Test {
    uint8 internal constant AGAINST = 0;
    uint8 internal constant FOR = 1;
    uint8 internal constant ABSTAIN = 2;

    uint256 internal constant PROPOSAL_ID = 1;
    uint256 internal constant OTHER_PROPOSAL_ID = 2;

    /// @dev The receipt packs weight into `uint240`; this is the first value that does not fit.
    uint256 internal constant WEIGHT_LIMIT = 1 << 240;

    CountingHarness internal counting;

    address internal governor = makeAddr("governor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        counting = new CountingHarness(governor);
    }

    function _countVote(uint256 proposalId, address voter, uint8 support, uint256 weight) internal returns (uint256) {
        vm.prank(governor);
        return counting.countVote(proposalId, voter, support, weight, "");
    }

    function _countVote(address voter, uint8 support, uint256 weight) internal returns (uint256) {
        return _countVote(PROPOSAL_ID, voter, support, weight);
    }

    function _bucketOf(uint256 proposalId, uint8 support) internal view returns (uint256) {
        (uint256 against, uint256 for_, uint256 abstain) = counting.tallies(proposalId);
        if (support == AGAINST) return against;
        if (support == FOR) return for_;
        return abstain;
    }

    // ─────────────────────────── First vote (baseline) ───────────────────────────

    function test_countVote_firstVote_creditsBucketAndRecordsReceipt() public {
        uint256 counted = _countVote(alice, FOR, 600e18);

        assertEq(counted, 600e18);
        assertEq(_bucketOf(PROPOSAL_ID, FOR), 600e18);
        assertTrue(counting.hasVoted(PROPOSAL_ID, alice));

        (bool hasVoted, uint8 support, uint256 weight) = counting.voteReceipt(PROPOSAL_ID, alice);
        assertTrue(hasVoted);
        assertEq(support, FOR);
        assertEq(weight, 600e18);
    }

    function test_countVote_revertsOnInvalidSupport() public {
        vm.prank(governor);
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector);
        counting.countVote(PROPOSAL_ID, alice, 3, 600e18, "");
    }

    function test_countVote_revertsWhenCallerIsNotGovernor() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, stranger));
        counting.countVote(PROPOSAL_ID, alice, FOR, 600e18, "");
    }

    // ─────────────────────────── Re-vote: the 9 transitions ───────────────────────────

    /// @dev Every (from, to) support pair: the old bucket must be debited by the recorded
    ///      weight and the new bucket credited, leaving exactly one standing vote. The three
    ///      same-support pairs are the degenerate case — tallies unchanged, still one vote.
    function test_countVote_revote_movesWeightAcrossEverySupportPair() public {
        for (uint8 from = 0; from < 3; ++from) {
            for (uint8 to = 0; to < 3; ++to) {
                uint256 proposalId = 100 + uint256(from) * 3 + uint256(to);

                _countVote(proposalId, alice, from, 600e18);
                _countVote(proposalId, alice, to, 600e18);

                (uint256 against, uint256 for_, uint256 abstain) = counting.tallies(proposalId);
                uint256 total = against + for_ + abstain;

                assertEq(_bucketOf(proposalId, to), 600e18, "new bucket must hold the standing weight");
                assertEq(total, 600e18, "no double count: exactly one standing vote");
                assertTrue(counting.hasVoted(proposalId, alice), "hasVoted stays true after a re-vote");

                (, uint8 support,) = counting.voteReceipt(proposalId, alice);
                assertEq(support, to, "receipt must record the latest support");
            }
        }
    }

    function test_countVote_revote_returnsTheNewStandingWeight() public {
        _countVote(alice, FOR, 600e18);
        uint256 counted = _countVote(alice, AGAINST, 600e18);

        assertEq(counted, 600e18, "countVote reports the standing vote, not a delta");
    }

    /// @dev The debit side reads the *recorded* weight, the credit side the *passed* weight.
    ///      Under snapshot voting both are equal, but the accounting must not assume it.
    function test_countVote_revote_withDifferentWeight_debitsRecordedCreditsPassed() public {
        _countVote(alice, FOR, 600e18);
        _countVote(alice, AGAINST, 250e18);

        assertEq(_bucketOf(PROPOSAL_ID, FOR), 0, "old bucket debited by the recorded weight");
        assertEq(_bucketOf(PROPOSAL_ID, AGAINST), 250e18, "new bucket credited with the passed weight");

        (,, uint256 weight) = counting.voteReceipt(PROPOSAL_ID, alice);
        assertEq(weight, 250e18, "receipt tracks the new weight");
    }

    function test_countVote_repeatedRevotes_leaveExactlyOneStandingVote() public {
        for (uint256 i = 0; i < 10; ++i) {
            _countVote(alice, uint8(i % 3), 600e18);
        }

        (uint256 against, uint256 for_, uint256 abstain) = counting.tallies(PROPOSAL_ID);
        assertEq(against + for_ + abstain, 600e18);
        assertEq(_bucketOf(PROPOSAL_ID, uint8(9 % 3)), 600e18);
    }

    function test_countVote_revote_doesNotTouchOtherVoters() public {
        _countVote(alice, FOR, 600e18);
        _countVote(bob, FOR, 350e18);

        _countVote(alice, AGAINST, 600e18);

        assertEq(_bucketOf(PROPOSAL_ID, FOR), 350e18, "bob's vote survives alice's re-vote");
        assertEq(_bucketOf(PROPOSAL_ID, AGAINST), 600e18);
    }

    function test_countVote_revote_doesNotTouchOtherProposals() public {
        _countVote(PROPOSAL_ID, alice, FOR, 600e18);
        _countVote(OTHER_PROPOSAL_ID, alice, FOR, 600e18);

        _countVote(PROPOSAL_ID, alice, AGAINST, 600e18);

        assertEq(_bucketOf(OTHER_PROPOSAL_ID, FOR), 600e18, "per-proposal tallies are independent");
        assertEq(_bucketOf(OTHER_PROPOSAL_ID, AGAINST), 0);
    }

    function test_countVote_revote_canEmptyABucketBackToZero() public {
        _countVote(alice, FOR, 600e18);
        _countVote(alice, ABSTAIN, 600e18);

        assertEq(_bucketOf(PROPOSAL_ID, FOR), 0, "sole voter re-voting away zeroes the bucket");
    }

    function test_countVote_revote_fromZeroWeightVote() public {
        _countVote(alice, FOR, 0);
        _countVote(alice, AGAINST, 600e18);

        assertEq(_bucketOf(PROPOSAL_ID, FOR), 0);
        assertEq(_bucketOf(PROPOSAL_ID, AGAINST), 600e18);
    }

    // ─────────────────────────── Receipt width guard ───────────────────────────

    function test_countVote_acceptsMaxUint240Weight() public {
        uint256 counted = _countVote(alice, FOR, WEIGHT_LIMIT - 1);

        assertEq(counted, WEIGHT_LIMIT - 1);
        assertEq(_bucketOf(PROPOSAL_ID, FOR), WEIGHT_LIMIT - 1);

        (,, uint256 weight) = counting.voteReceipt(PROPOSAL_ID, alice);
        assertEq(weight, WEIGHT_LIMIT - 1, "receipt must round-trip the boundary weight");
    }

    /// @dev The receipt is narrower than the tally (uint240 vs uint256). Silent truncation
    ///      would break conservation — the guard makes it a loud revert instead.
    function test_countVote_revertsOnWeightExceedingReceiptWidth() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.WeightOverflow.selector, WEIGHT_LIMIT));
        counting.countVote(PROPOSAL_ID, alice, FOR, WEIGHT_LIMIT, "");
    }

    // ─────────────────────────── Per-support tally (frozen vector surface) ───────────────────────────

    /// @dev `tally(id, support)` is the accessor the frozen differential-vector ABI requires
    ///      (`IStandardRulesetVector`). It reads the same buckets as `proposalVotes`,
    ///      one at a time, which is what the tally-conservation vectors iterate over.
    function test_tally_readsTheSameBucketsAsProposalVotes() public {
        _countVote(alice, AGAINST, 600e18);
        _countVote(bob, FOR, 350e18);

        assertEq(counting.tally(PROPOSAL_ID, AGAINST), 600e18);
        assertEq(counting.tally(PROPOSAL_ID, FOR), 350e18);
        assertEq(counting.tally(PROPOSAL_ID, ABSTAIN), 0);

        (uint256 against, uint256 for_, uint256 abstain) = counting.tallies(PROPOSAL_ID);
        assertEq(counting.tally(PROPOSAL_ID, AGAINST), against);
        assertEq(counting.tally(PROPOSAL_ID, FOR), for_);
        assertEq(counting.tally(PROPOSAL_ID, ABSTAIN), abstain);
    }

    function test_tally_revertsOnInvalidSupport() public {
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector);
        counting.tally(PROPOSAL_ID, 3);
    }

    // ─────────────────────────── Unknown-id contract ───────────────────────────

    function test_views_unknownProposalId_neverRevert() public view {
        uint256 unknown = 999;

        assertFalse(counting.hasVoted(unknown, alice));

        (uint256 against, uint256 for_, uint256 abstain) = counting.tallies(unknown);
        assertEq(against, 0);
        assertEq(for_, 0);
        assertEq(abstain, 0);

        (bool hasVoted, uint8 support, uint256 weight) = counting.voteReceipt(unknown, alice);
        assertFalse(hasVoted);
        assertEq(support, 0);
        assertEq(weight, 0);
    }

    function test_voteReceipt_unknownVoter_returnsEmpty() public {
        _countVote(alice, FOR, 600e18);

        (bool hasVoted, uint8 support, uint256 weight) = counting.voteReceipt(PROPOSAL_ID, bob);
        assertFalse(hasVoted);
        assertEq(support, 0);
        assertEq(weight, 0);
    }

    // ─────────────────────────── Extra support options (Bond) ───────────────────────────

    /// @dev The base must carry a ruleset that defines more than the three Bravo options: Bond
    ///      adds No+Slash as support=3. A re-vote *into* the extra bucket
    ///      must conserve the tally exactly as the three-option case does.
    function test_extraSupportOption_countsAndConservesOnRevote() public {
        FourOptionHarness bond = new FourOptionHarness(governor);
        uint8 noAndSlash = 3;

        vm.prank(governor);
        bond.countVote(PROPOSAL_ID, alice, FOR, 600e18, "");
        vm.prank(governor);
        bond.countVote(PROPOSAL_ID, alice, noAndSlash, 600e18, ""); // re-vote into the 4th bucket

        assertEq(bond.tally(PROPOSAL_ID, FOR), 0, "the For bucket was debited");
        assertEq(bond.tally(PROPOSAL_ID, noAndSlash), 600e18, "the extra bucket holds the standing vote");

        (, uint8 support,) = bond.voteReceipt(PROPOSAL_ID, alice);
        assertEq(support, noAndSlash);
    }

    /// @dev Each ruleset still owns which options it accepts: the three-option harness must
    ///      reject the support value the Bond-like one accepts.
    function test_extraSupportOption_isPerRulesetNotGlobal() public {
        vm.prank(governor);
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector);
        counting.countVote(PROPOSAL_ID, alice, 3, 600e18, "");
    }

    // ─────────────────────────── Tally conservation (fuzz) ───────────────────────────

    /// @dev The headline conservation property: after an arbitrary re-vote sequence, each
    ///      bucket equals the sum of the weights of the voters whose *latest* vote points at it,
    ///      and the buckets together equal the total standing weight — never more (double count),
    ///      never less (lost debit).
    function testFuzz_tallyConservation_underArbitraryRevoteSequences(
        uint8[16] calldata supportPicks,
        uint8[16] calldata voterPicks,
        uint96[16] calldata weights
    ) public {
        address[3] memory voters = [alice, bob, stranger];

        // Independent oracle: reconstruct the expected tallies from the INPUT sequence, not from
        // the contract's own receipts — so a bug that mis-stored support *consistently* with a
        // mis-credited bucket cannot make the two agree. Each voter's standing = their latest cast.
        uint8[3] memory latestSupport;
        uint256[3] memory latestWeight;
        bool[3] memory voted;
        for (uint256 i = 0; i < 16; ++i) {
            uint256 v = voterPicks[i] % 3;
            uint8 support = supportPicks[i] % 3;
            _countVote(voters[v], support, weights[i]);
            latestSupport[v] = support;
            latestWeight[v] = weights[i];
            voted[v] = true;
        }

        uint256[3] memory expected;
        for (uint256 v = 0; v < 3; ++v) {
            if (voted[v]) expected[latestSupport[v]] += latestWeight[v];
        }

        (uint256 against, uint256 for_, uint256 abstain) = counting.tallies(PROPOSAL_ID);
        assertEq(against, expected[AGAINST], "against bucket == sum of standing against weights");
        assertEq(for_, expected[FOR], "for bucket == sum of standing for weights");
        assertEq(abstain, expected[ABSTAIN], "abstain bucket == sum of standing abstain weights");
    }

    /// @dev A re-vote that reverts (invalid support / weight overflow) must leave the standing vote
    ///      untouched. Both guards run before any state write, so the EVM rolls back — this pins
    ///      that no partial debit/credit escapes ahead of the revert.
    function test_countVote_rejectedRevote_leavesStandingVoteIntact() public {
        _countVote(alice, FOR, 600e18);

        vm.prank(governor);
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector);
        counting.countVote(PROPOSAL_ID, alice, 3, 600e18, "");

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.WeightOverflow.selector, WEIGHT_LIMIT));
        counting.countVote(PROPOSAL_ID, alice, AGAINST, WEIGHT_LIMIT, "");

        assertEq(_bucketOf(PROPOSAL_ID, FOR), 600e18, "the standing For vote survives both rejected re-votes");
        (bool voted, uint8 support, uint256 weight) = counting.voteReceipt(PROPOSAL_ID, alice);
        assertTrue(voted);
        assertEq(support, FOR);
        assertEq(weight, 600e18);
    }

    /// @dev The threshold-oscillation attack shape: a tally that crosses a threshold, is re-voted back below
    ///      it, and crosses again must be exactly reconstructible at every step — the tally layer
    ///      stays coherent even though the *crossing* is not a monotonic event.
    function test_tally_oscillatesAcrossAThresholdWithoutDrift() public {
        _countVote(alice, FOR, 600e18);
        assertEq(_bucketOf(PROPOSAL_ID, FOR), 600e18, "crossed");

        _countVote(alice, AGAINST, 600e18);
        assertEq(_bucketOf(PROPOSAL_ID, FOR), 0, "back below");

        _countVote(alice, FOR, 600e18);
        assertEq(_bucketOf(PROPOSAL_ID, FOR), 600e18, "crossed again, no drift");

        (uint256 against, uint256 for_, uint256 abstain) = counting.tallies(PROPOSAL_ID);
        assertEq(against + for_ + abstain, 600e18, "conservation holds across the oscillation");
    }
}
