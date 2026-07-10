// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IRuleset} from "./IRuleset.sol";

/// @dev Minimal governor surface StandardRuleset consumes — only `proposalSnapshot`, so a
///      registry or test can satisfy this with a trivial stand-in instead of a full governor.
interface IRulesetGovernor {
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);
}

/// @title StandardRuleset
/// @notice Replicates the live ENS governor's counting semantics (OZ `GovernorCountingSimple`
///         + `GovernorVotesQuorumFraction`) as a standalone, governor-agnostic ruleset.
/// @dev Immutable by design (D7: "What the DAO audited is what runs forever") — no setters,
///      including for the quorum numerator. `countVote` is state-changing and therefore
///      restricted to `governor`, so third parties cannot stuff vote tallies.
contract StandardRuleset is IRuleset {
    /// @dev Bravo-style bucket ordering: 0=Against, 1=For, 2=Abstain.
    enum VoteType {
        Against,
        For,
        Abstain
    }

    struct ProposalVote {
        uint256 against;
        uint256 for_;
        uint256 abstain;
        mapping(address => bool) hasVoted;
    }

    /// @dev Fixed at 100 so a numerator of 1 encodes 1%, matching OZ's default
    ///      `GovernorVotesQuorumFraction` denominator. Not exposed — the brief calls for no
    ///      surface beyond `IRuleset`, and this value is not overridable.
    uint256 private constant QUORUM_DENOMINATOR = 100;

    address public immutable governor;
    IVotes public immutable token;
    uint256 public immutable quorumNumerator;

    mapping(uint256 => ProposalVote) private _proposalVotes;

    /// @notice `voter` already cast a vote on this proposal under this ruleset.
    error AlreadyVoted(address voter);
    /// @notice `support` is not one of Against(0)/For(1)/Abstain(2).
    error InvalidVoteType();
    /// @notice `caller` is not the governor this ruleset was deployed for.
    error Unauthorized(address caller);
    /// @notice `numerator` exceeds the denominator (100), which would yield a quorum > 100%.
    error InvalidQuorumFraction(uint256 numerator, uint256 denominator);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized(msg.sender);
        _;
    }

    constructor(address governor_, IVotes token_, uint256 quorumNumerator_) {
        if (quorumNumerator_ > QUORUM_DENOMINATOR) {
            revert InvalidQuorumFraction(quorumNumerator_, QUORUM_DENOMINATOR);
        }
        governor = governor_;
        token = token_;
        quorumNumerator = quorumNumerator_;
    }

    /// @inheritdoc IRuleset
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
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        if (proposalVote.hasVoted[voter]) revert AlreadyVoted(voter);
        proposalVote.hasVoted[voter] = true;

        if (support == uint8(VoteType.Against)) {
            proposalVote.against += weight;
        } else if (support == uint8(VoteType.For)) {
            proposalVote.for_ += weight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposalVote.abstain += weight;
        } else {
            revert InvalidVoteType();
        }

        return weight;
    }

    /// @inheritdoc IRuleset
    function quorumReached(uint256 proposalId) external view returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        uint256 snapshot = IRulesetGovernor(governor).proposalSnapshot(proposalId);
        return proposalVote.for_ + proposalVote.abstain >= quorum(snapshot);
    }

    /// @inheritdoc IRuleset
    function voteSucceeded(uint256 proposalId) external view returns (bool) {
        ProposalVote storage proposalVote = _proposalVotes[proposalId];
        return proposalVote.for_ > proposalVote.against;
    }

    /// @inheritdoc IRuleset
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _proposalVotes[proposalId].hasVoted[voter];
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
