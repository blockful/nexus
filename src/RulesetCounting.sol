// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRuleset} from "./IRuleset.sol";

/// @title RulesetCounting
/// @notice Shared vote-counting mechanics for every GovernorNexus ruleset: Bravo-style buckets,
///         per-voter receipts, and **mutable votes** — re-voting while the poll is open replaces
///         the voter's standing vote instead of reverting (Nexus 2, D12).
/// @dev Rules (quorum, success, counting mode) belong to the inheriting ruleset; this base owns
///      only the arithmetic and the `onlyGovernor` trust boundary.
///
///      **Non-monotonicity — read this before building on the tallies (D16).** Because a re-vote
///      debits the voter's previous bucket, tallies can *fall* as well as rise while voting is
///      open. Any quantity derived from them (quorum reached, vote succeeded) may therefore flip
///      in both directions until the deadline. No consumer may arm one-shot state on a
///      tally-crossing event — an attacker can cross a threshold early, re-vote back below it,
///      and so burn a once-only trigger before the crossing that actually matters (finding F2).
///      Mechanisms needing finality must evaluate the outcome at (or near) the deadline, bar
///      re-votes inside their own window, or gate early finality entirely.
///
///      Voting-window enforcement stays in the core (D17): the governor only calls `countVote`
///      while the proposal is Active, and supplies the weight from the frozen snapshot — this
///      base never reads the clock and never sources weight of its own.
abstract contract RulesetCounting is IRuleset {
    /// @dev Bravo-style bucket ordering: 0=Against, 1=For, 2=Abstain.
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /// @notice A voter's standing vote on a proposal.
    /// @dev `weight` is the amount currently credited to `support`'s bucket — the debit side of a
    ///      re-vote reads it back, so it must be exact. Packed to `uint240` to fit the receipt in
    ///      one slot alongside `hasVoted` + `support`; `countVote` guards the bound rather than
    ///      truncating (see `WeightOverflow`).
    struct VoteReceipt {
        bool hasVoted;
        uint8 support;
        uint240 weight;
    }

    /// @dev Per-proposal tally. `for_` has the trailing underscore because `for` is reserved.
    struct ProposalVote {
        uint256 against;
        uint256 for_;
        uint256 abstain;
        mapping(address => VoteReceipt) receipts;
    }

    /// @notice The single GovernorNexus this ruleset counts for; `countVote` is restricted to it.
    address public immutable governor;

    mapping(uint256 => ProposalVote) private _proposalVotes;

    /// @notice `support` is not one of Against(0)/For(1)/Abstain(2).
    error InvalidVoteType();
    /// @notice `caller` is not the governor this ruleset was deployed for.
    error Unauthorized(address caller);
    /// @notice `weight` does not fit the receipt's `uint240` field, so it could not be recorded
    ///         exactly — and a weight that cannot be recorded cannot be debited on a re-vote.
    /// @dev Unreachable for any real voting token (ENS total supply ≈ 1e26 ≪ 2^240 ≈ 1.8e72);
    ///      the guard exists so a hypothetical wider-supply token fails loudly instead of
    ///      silently truncating the receipt and breaking tally conservation.
    error WeightOverflow(uint256 weight);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized(msg.sender);
        _;
    }

    /// @param governor_ The GovernorNexus this ruleset is deployed for.
    constructor(address governor_) {
        governor = governor_;
    }

    /// @notice Counts `voter`'s vote on `proposalId`, **replacing their previous vote** if any.
    /// @dev The replace is atomic within this call: the recorded weight is debited from the
    ///      recorded bucket before the passed weight is credited to the new one, so no observer
    ///      can ever see the voter's weight double-counted or missing. Re-voting the same support
    ///      is the degenerate case (debit and credit cancel out) and is allowed — no special path.
    /// @return The weight now standing for `voter` on this proposal (what the core reports in
    ///         `VoteCast`; the latest such event per (proposal, voter) is canonical — D15).
    function countVote(
        uint256 proposalId,
        address voter,
        uint8 support,
        uint256 weight,
        bytes calldata /* params */
    )
        external
        onlyGovernor
        returns (uint256)
    {
        if (support > uint8(VoteType.Abstain)) revert InvalidVoteType();
        if (weight > type(uint240).max) revert WeightOverflow(weight);

        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        VoteReceipt storage receipt = proposalVote.receipts[voter];

        if (receipt.hasVoted) _debit(proposalVote, receipt.support, receipt.weight);
        _credit(proposalVote, support, weight);

        receipt.hasVoted = true;
        receipt.support = support;
        // forge-lint: disable-next-line(unsafe-typecast) — bounds-checked above (WeightOverflow).
        receipt.weight = uint240(weight);

        return weight;
    }

    /// @notice Whether `voter` has a standing vote on `proposalId`.
    /// @dev Stays `true` across re-votes — it answers "does this voter have a vote", not "how
    ///      many times did they cast". Never reverts on an id this ruleset never counted
    ///      (empty-receipt default, `false`), per the interface contract pinned in Nexus 1.
    function hasVoted(uint256 proposalId, address voter) public view returns (bool) {
        return _proposalVotes[proposalId].receipts[voter].hasVoted;
    }

    /// @notice `voter`'s standing vote on `proposalId`: whether one exists, its support bucket,
    ///         and the weight currently credited to that bucket.
    /// @dev Lets tooling read current standing state without replaying `VoteCast` logs. Same
    ///      no-revert contract as `hasVoted`: an unknown (proposal, voter) reads as all-zero.
    function voteReceipt(uint256 proposalId, address voter)
        public
        view
        returns (bool voted, uint8 support, uint256 weight)
    {
        VoteReceipt storage receipt = _proposalVotes[proposalId].receipts[voter];
        return (receipt.hasVoted, receipt.support, receipt.weight);
    }

    /// @notice Per-bucket tally for `proposalId`, mirroring OZ `GovernorCountingSimple`'s
    ///         `proposalVotes` (same name, same return order).
    /// @dev Non-monotonic under re-votes (see the contract-level note). An id this ruleset never
    ///      counted returns all-zero, never reverts.
    function proposalVotes(uint256 proposalId)
        public
        view
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return (proposalVote.against, proposalVote.for_, proposalVote.abstain);
    }

    /// @dev Removes a standing vote's weight from its bucket — the first half of a re-vote.
    ///      Cannot underflow: it removes exactly the weight this voter's receipt says is credited
    ///      to that bucket, and checked arithmetic would revert if that invariant ever broke.
    function _debit(ProposalVote storage proposalVote, uint8 support, uint256 weight) private {
        if (support == uint8(VoteType.Against)) {
            proposalVote.against -= weight;
        } else if (support == uint8(VoteType.For)) {
            proposalVote.for_ -= weight;
        } else {
            proposalVote.abstain -= weight;
        }
    }

    function _credit(ProposalVote storage proposalVote, uint8 support, uint256 weight) private {
        if (support == uint8(VoteType.Against)) {
            proposalVote.against += weight;
        } else if (support == uint8(VoteType.For)) {
            proposalVote.for_ += weight;
        } else {
            proposalVote.abstain += weight;
        }
    }
}
