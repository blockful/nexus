// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IRuleset} from "../src/IRuleset.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {MockENSToken} from "./mocks/MockENSToken.sol";
import {MockGovernor} from "./mocks/MockGovernor.sol";

/// @dev Isolated unit suite: no governor implementation exists yet, so `MockGovernor`
///      supplies the one method StandardRuleset consumes (`proposalSnapshot`) and doubles
///      as the `onlyGovernor` caller — pranking as it exercises the real authorization path.
contract StandardRulesetTest is Test {
    uint256 internal constant QUORUM_NUMERATOR = 10; // 10%
    uint256 internal constant PROPOSAL_ID = 1;

    MockENSToken internal token;
    MockGovernor internal governor;
    StandardRuleset internal ruleset;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.roll(1000);

        token = new MockENSToken();
        governor = new MockGovernor();
        ruleset = new StandardRuleset(address(governor), IVotes(address(token)), QUORUM_NUMERATOR);

        // Total supply 1000e18 -> 10% quorum = 100e18.
        token.mint(alice, 600e18);
        token.mint(bob, 350e18);
        token.mint(carol, 50e18);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);
        vm.roll(block.number + 1);

        governor.setSnapshot(PROPOSAL_ID, block.number - 1);
    }

    function _countVote(address voter, uint8 support, uint256 weight) internal returns (uint256) {
        vm.prank(address(governor));
        return ruleset.countVote(PROPOSAL_ID, voter, support, weight, "");
    }

    // ─────────────────────────── ERC165 ───────────────────────────

    function test_supportsInterface_ruleset() public view {
        assertTrue(ruleset.supportsInterface(type(IRuleset).interfaceId));
    }

    function test_supportsInterface_erc165() public view {
        assertTrue(ruleset.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_rejectsUnknown() public view {
        assertFalse(ruleset.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ─────────────────────────── onlyGovernor ───────────────────────────

    function test_countVote_revertsWhenCallerIsNotGovernor() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(StandardRuleset.Unauthorized.selector, stranger));
        ruleset.countVote(PROPOSAL_ID, alice, 1, 600e18, "");
    }

    function test_countVote_succeedsFromGovernor() public {
        uint256 counted = _countVote(alice, 1, 600e18);
        assertEq(counted, 600e18);
    }

    // ─────────────────────────── Support bucketing ───────────────────────────

    function test_countVote_against_doesNotCountTowardSuccess() public {
        _countVote(alice, 0, 600e18);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID)); // against (600e18) not < for (0)
    }

    function test_countVote_for_countsTowardSuccess() public {
        _countVote(alice, 1, 600e18);
        assertTrue(ruleset.voteSucceeded(PROPOSAL_ID)); // for (600e18) > against (0)
    }

    function test_countVote_abstain_countsTowardQuorumNotSuccess() public {
        _countVote(alice, 2, 600e18);
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID)); // for (0) not > against (0)
        assertTrue(ruleset.quorumReached(PROPOSAL_ID)); // abstain counts toward quorum
    }

    function test_countVote_revertsOnSupportGreaterThanTwo() public {
        vm.prank(address(governor));
        vm.expectRevert(StandardRuleset.InvalidVoteType.selector);
        ruleset.countVote(PROPOSAL_ID, alice, 3, 600e18, "");
    }

    // ─────────────────────────── Revote ───────────────────────────

    function test_countVote_revertsOnDoubleVote() public {
        _countVote(alice, 1, 600e18);
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(StandardRuleset.AlreadyVoted.selector, alice));
        ruleset.countVote(PROPOSAL_ID, alice, 0, 600e18, "");
    }

    function test_hasVoted_reflectsState() public {
        assertFalse(ruleset.hasVoted(PROPOSAL_ID, alice));
        _countVote(alice, 1, 600e18);
        assertTrue(ruleset.hasVoted(PROPOSAL_ID, alice));
    }

    // ─────────────────────────── Zero weight ───────────────────────────

    function test_countVote_zeroWeight_recordsVoteWithoutChangingTallies() public {
        uint256 counted = _countVote(alice, 1, 0);
        assertEq(counted, 0);
        assertTrue(ruleset.hasVoted(PROPOSAL_ID, alice));
        assertFalse(ruleset.voteSucceeded(PROPOSAL_ID)); // for (0) not > against (0)
        assertFalse(ruleset.quorumReached(PROPOSAL_ID));
    }

    // ─────────────────────────── Quorum math ───────────────────────────

    function test_quorum_matchesPastSupplyTimesNumeratorOverHundred() public view {
        uint256 pastSupply = token.getPastTotalSupply(block.number - 1);
        assertEq(pastSupply, 1000e18);
        assertEq(ruleset.quorum(block.number - 1), pastSupply * QUORUM_NUMERATOR / 100);
    }

    function test_quorumReached_falseWhenNoVotes() public view {
        assertFalse(ruleset.quorumReached(PROPOSAL_ID));
    }

    function test_quorumReached_falseBelowQuorum() public {
        _countVote(carol, 1, 50e18); // 50e18 < 100e18 quorum
        assertFalse(ruleset.quorumReached(PROPOSAL_ID));
    }

    function test_quorumReached_trueAboveQuorum() public {
        _countVote(bob, 1, 350e18); // 350e18 >= 100e18 quorum
        assertTrue(ruleset.quorumReached(PROPOSAL_ID));
    }

    /// @dev `quorumReached` uses `>=`, not `>` — votes exactly equal to the quorum
    ///      threshold must pass. Weight is a `countVote` parameter, so a proposal-scoped
    ///      round number exercises the boundary without depending on token balances.
    function test_quorumReached_boundaryEquality() public {
        uint256 secondProposal = 2;
        governor.setSnapshot(secondProposal, block.number - 1);
        uint256 quorumVotes = ruleset.quorum(block.number - 1); // 100e18

        vm.prank(address(governor));
        ruleset.countVote(secondProposal, alice, 2, quorumVotes, ""); // abstain, exactly quorum
        assertTrue(ruleset.quorumReached(secondProposal));
    }

    // ─────────────────────────── COUNTING_MODE ───────────────────────────

    function test_countingMode() public view {
        assertEq(ruleset.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
    }
}
