// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IRuleset} from "./IRuleset.sol";
import {RulesetCounting} from "./RulesetCounting.sol";

/// @dev Minimal governor surface StandardRuleset consumes — only `proposalSnapshot`, so a
///      registry or test can satisfy this with a trivial stand-in instead of a full governor.
interface IRulesetGovernor {
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);
}

/// @title StandardRuleset
/// @notice The ENS governor's counting rules (OZ `GovernorCountingSimple` +
///         `GovernorVotesQuorumFraction`) as a standalone, governor-agnostic ruleset — with
///         **mutable votes**: re-voting while the poll is open replaces the standing vote
///         (Nexus 2, D13), the one deliberate divergence from the live ENS governor, which
///         reverts instead.
/// @dev Counting mechanics (buckets, receipts, replace-on-re-vote) come from `RulesetCounting`;
///      this contract owns only the rules layered on top. Note the base's non-monotonicity
///      warning: `quorumReached` and `voteSucceeded` can flip in **both** directions while
///      voting is open, so neither may be used to arm one-shot state (D16 / finding F2).
///
///      Immutable by design (D7: "What the DAO audited is what runs forever") — no setters,
///      including for the quorum numerator. `countVote` is state-changing and therefore
///      restricted to `governor`, so third parties cannot stuff vote tallies.
contract StandardRuleset is RulesetCounting {
    /// @dev Bravo-style bucket ordering: 0=Against, 1=For, 2=Abstain — the three options this
    ///      ruleset accepts (`_isValidSupport`).
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /// @dev Fixed at 100 so a numerator of 1 encodes 1%, matching OZ's default
    ///      `GovernorVotesQuorumFraction` denominator. Not exposed — the brief calls for no
    ///      surface beyond `IRuleset`, and this value is not overridable.
    uint256 private constant QUORUM_DENOMINATOR = 100;

    /// @notice Voting token whose past total supply anchors `quorum`.
    IVotes public immutable token;
    /// @notice Quorum numerator over the fixed 100 denominator (e.g. `1` = 1%).
    uint256 public immutable quorumNumerator;

    /// @notice `numerator` exceeds the denominator (100), which would yield a quorum > 100%.
    error InvalidQuorumFraction(uint256 numerator, uint256 denominator);

    /// @param governor_ The GovernorNexus this ruleset is deployed for; immutable and never
    ///        revisited, so it must be the address the governor will actually deploy to (see
    ///        the deploy script's CREATE-address precompute for the chicken-and-egg fix).
    /// @param token_ Voting token backing `quorum`'s past-total-supply lookup.
    /// @param quorumNumerator_ Numerator over the fixed 100 denominator; reverts
    ///        `InvalidQuorumFraction` above 100.
    constructor(address governor_, IVotes token_, uint256 quorumNumerator_) RulesetCounting(governor_) {
        if (quorumNumerator_ > QUORUM_DENOMINATOR) {
            revert InvalidQuorumFraction(quorumNumerator_, QUORUM_DENOMINATOR);
        }
        token = token_;
        quorumNumerator = quorumNumerator_;
    }

    /// @inheritdoc IRuleset
    /// @dev A `proposalId` this ruleset never counted reads from empty-tally defaults, same
    ///      as `hasVoted`. That can make this return `true` for an uncounted id whenever
    ///      `quorum(0) == 0` (e.g. a zero quorum numerator, or a token with no supply at
    ///      timepoint 0) — callers must gate on proposal existence; the governor does this
    ///      via `state()`.
    ///
    ///      Non-monotonic under re-votes (D16): a voter moving weight out of For/Abstain can
    ///      take a proposal back *below* quorum after it had been reached.
    function quorumReached(uint256 proposalId) external view returns (bool) {
        uint256 forVotes = tally(proposalId, uint8(VoteType.For));
        uint256 abstainVotes = tally(proposalId, uint8(VoteType.Abstain));
        uint256 snapshot = IRulesetGovernor(governor).proposalSnapshot(proposalId);
        return forVotes + abstainVotes >= quorum(snapshot);
    }

    /// @inheritdoc IRuleset
    /// @dev Non-monotonic under re-votes (D16) — see `quorumReached`.
    function voteSucceeded(uint256 proposalId) external view returns (bool) {
        return tally(proposalId, uint8(VoteType.For)) > tally(proposalId, uint8(VoteType.Against));
    }

    /// @notice Per-bucket tally for `proposalId`, mirroring OZ `GovernorCountingSimple`'s
    ///         `proposalVotes` (same name, same return order) so tooling pointed at the governor
    ///         via `governor.proposalRuleset(id)` and then this getter just works.
    /// @dev The Bravo-shaped view of the base's generic buckets. An id this ruleset never counted
    ///      returns all-zero, never reverts. Non-monotonic under re-votes (D16).
    function proposalVotes(uint256 proposalId)
        external
        view
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        return (
            tally(proposalId, uint8(VoteType.Against)),
            tally(proposalId, uint8(VoteType.For)),
            tally(proposalId, uint8(VoteType.Abstain))
        );
    }

    /// @dev The three Bravo options — parity with the live ENS governor's counting surface.
    function _isValidSupport(uint8 support) internal pure override returns (bool) {
        return support <= uint8(VoteType.Abstain);
    }

    /// @inheritdoc IRuleset
    function quorum(uint256 timepoint) public view returns (uint256) {
        return token.getPastTotalSupply(timepoint) * quorumNumerator / QUORUM_DENOMINATOR;
    }

    /// @inheritdoc IRuleset
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
