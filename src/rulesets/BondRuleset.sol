// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IRuleset} from "../interfaces/IRuleset.sol";
import {IProposalValidator} from "../interfaces/IProposalValidator.sol";
import {RulesetCounting} from "../RulesetCounting.sol";
import {RulesetQuorumFraction} from "../RulesetQuorumFraction.sol";

/// @dev Minimal governor surface BondRuleset consumes (StandardRuleset's IRulesetGovernor
///      pattern, extended with the two reads the settle path needs).
interface IBondGovernor {
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);
    function state(uint256 proposalId) external view returns (IGovernor.ProposalState);
    function proposalCanceledAt(uint256 proposalId) external view returns (uint48);
}

/// @title BondRuleset
/// @notice Lock-to-propose ruleset: anyone proposes without the voting-power
///         threshold by locking `bondAmount` of ENS, forfeited to the DAO treasury iff the
///         vote deems the proposal spam, or the proposal is canceled
///         after voting opened / vetoed from the timelock.
/// @dev Immutable by design: no setters. Custody invariant: the ruleset's token
///      balance always covers every unsettled bond. Resolution is permissionless and
///      one-shot; refunds release once the vote can no longer slash — from `Succeeded`
///      onward — so the timelock-veto forfeit reaches only bonds still unsettled.
contract BondRuleset is RulesetCounting, RulesetQuorumFraction, IProposalValidator {
    using SafeERC20 for IERC20;

    /// @dev Bravo ordering plus the slash option: 0=Against, 1=For, 2=Abstain,
    ///      3=AgainstAndSlash.
    enum VoteType {
        Against,
        For,
        Abstain,
        AgainstAndSlash
    }

    /// @notice Why a bond was forfeited; `None` marks a refund (no forfeit).
    enum SlashReason {
        SlashVote,
        ActiveSelfCancel,
        TimelockVeto,
        None
    }

    /// @notice A locked proposal bond. The locked amount is not stored — `bondAmount` is
    ///         immutable and under-delivery reverts at lock, so every bond holds exactly
    ///         `bondAmount`. Packs into a single slot.
    struct Bond {
        address proposer;
        bool settled;
    }

    /// @notice ENS locked per proposal.
    uint256 public immutable bondAmount;
    /// @notice Forfeit destination — the DAO treasury (the timelock).
    address public immutable treasury;

    mapping(uint256 proposalId => Bond) private _bonds;

    event BondLocked(uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondRefunded(uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondSlashed(uint256 indexed proposalId, uint256 amount, SlashReason reason);

    error InvalidBondAmount(uint256 amount);
    error ZeroTreasury();
    error BondAlreadyLocked(uint256 proposalId);
    error InsufficientBondReceived();
    error NoBond(uint256 proposalId);
    error BondAlreadySettled(uint256 proposalId);
    error BondNotResolvable(uint256 proposalId, IGovernor.ProposalState state);

    constructor(address governor_, IVotes token_, uint256 quorumNumerator_, uint256 bondAmount_, address treasury_)
        RulesetCounting(governor_)
        RulesetQuorumFraction(token_, quorumNumerator_)
    {
        if (bondAmount_ == 0) revert InvalidBondAmount(bondAmount_);
        if (treasury_ == address(0)) revert ZeroTreasury();
        bondAmount = bondAmount_;
        treasury = treasury_;
    }

    /// @notice The bond locked for `proposalId` (zeroed if none). Every locked bond holds
    ///         exactly `bondAmount` — read that immutable for the amount.
    function bondOf(uint256 proposalId) external view returns (address proposer, bool settled) {
        Bond storage bond = _bonds[proposalId];
        return (bond.proposer, bond.settled);
    }

    /// @notice Per-bucket tallies: Bravo triple plus the slash bucket.
    function proposalVotes(uint256 proposalId)
        external
        view
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes, uint256 againstAndSlashVotes)
    {
        return (
            tally(proposalId, uint8(VoteType.Against)),
            tally(proposalId, uint8(VoteType.For)),
            tally(proposalId, uint8(VoteType.Abstain)),
            tally(proposalId, uint8(VoteType.AgainstAndSlash))
        );
    }

    /// @dev The three Bravo options plus AgainstAndSlash.
    function _isValidSupport(uint8 support) internal pure override returns (bool) {
        return support <= uint8(VoteType.AgainstAndSlash);
    }

    /// @inheritdoc IRuleset
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo,againstAndSlash&quorum=for,abstain";
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IProposalValidator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IRuleset
    /// @dev For + Abstain only — AgainstAndSlash is an Against variant and, like Against,
    ///      never counts toward quorum. Non-monotonic under re-votes.
    function quorumReached(uint256 proposalId) external view returns (bool) {
        uint256 forVotes = tally(proposalId, uint8(VoteType.For));
        uint256 abstainVotes = tally(proposalId, uint8(VoteType.Abstain));
        uint256 snapshot = IBondGovernor(governor).proposalSnapshot(proposalId);
        return forVotes + abstainVotes >= quorum(snapshot);
    }

    /// @inheritdoc IRuleset
    /// @dev Rejections are the sum of both Against buckets — plain Against plus AgainstAndSlash.
    ///      Non-monotonic under re-votes.
    function voteSucceeded(uint256 proposalId) external view returns (bool) {
        uint256 rejections =
            tally(proposalId, uint8(VoteType.Against)) + tally(proposalId, uint8(VoteType.AgainstAndSlash));
        return tally(proposalId, uint8(VoteType.For)) > rejections;
    }

    /// @inheritdoc IProposalValidator
    /// @dev Records the bond then pulls it (checks-effects-interactions); reverts if the token
    ///      delivers less than `bondAmount`, so a fee-on-transfer token can never under-collateralize.
    function validateProposal(
        uint256 proposalId,
        address proposer,
        address[] calldata,
        uint256[] calldata,
        bytes[] calldata
    ) external onlyGovernor {
        if (_bonds[proposalId].proposer != address(0)) revert BondAlreadyLocked(proposalId);

        // Effect before interaction (CEI).
        _bonds[proposalId] = Bond({proposer: proposer, settled: false});

        IERC20 erc20 = IERC20(address(token));
        uint256 balanceBefore = erc20.balanceOf(address(this));
        // slither-disable-next-line arbitrary-send-erc20
        erc20.safeTransferFrom(proposer, address(this), bondAmount);
        if (erc20.balanceOf(address(this)) - balanceBefore < bondAmount) revert InsufficientBondReceived();

        emit BondLocked(proposalId, proposer, bondAmount);
    }

    /// @notice Settles `proposalId`'s bond once its outcome is final. Permissionless and
    ///         one-shot: anyone may trigger settlement, nobody can trigger it twice.
    /// @dev Refunds release from `Succeeded` onward — the bond is an anti-spam instrument
    ///      and surviving the vote fulfills its purpose; the timelock-veto forfeit reaches
    ///      only bonds still unsettled when the veto lands. Effects (settled flag) precede
    ///      the single transfer (CEI).
    function resolveBond(uint256 proposalId) external {
        Bond storage bond = _bonds[proposalId];
        if (bond.proposer == address(0)) revert NoBond(proposalId);
        if (bond.settled) revert BondAlreadySettled(proposalId);

        _settle(proposalId, bond, _bondResolution(proposalId));
    }

    /// @dev Maps a resolvable proposal state to the bond's resolution. `None` refunds the
    ///      proposer; every other reason forfeits to the treasury — destination and event are
    ///      derived in `_settle`, so no contradictory (reason, destination) pair is
    ///      representable. Only `Pending`/`Active` revert: while the vote is live the
    ///      slash outcome is still undecided, so nothing may settle.
    function _bondResolution(uint256 proposalId) private view returns (SlashReason) {
        IGovernor.ProposalState state = IBondGovernor(governor).state(proposalId);
        if (state == IGovernor.ProposalState.Executed) return SlashReason.None;
        if (state == IGovernor.ProposalState.Succeeded || state == IGovernor.ProposalState.Queued) {
            return SlashReason.None;
        }
        if (state == IGovernor.ProposalState.Defeated) {
            return _slashVoted(proposalId) ? SlashReason.SlashVote : SlashReason.None;
        }
        if (state == IGovernor.ProposalState.Canceled) return _canceledBondResolution(proposalId);
        revert BondNotResolvable(proposalId, state);
    }

    /// @dev Cancel partition on the recorded cancel timepoint: a self-cancel while still Pending
    ///      (`0 < canceledAt <= snapshot`) refunds; a council veto (no governor-path timepoint,
    ///      `canceledAt == 0`) or a self-cancel after voting opened forfeits.
    function _canceledBondResolution(uint256 proposalId) private view returns (SlashReason) {
        uint48 canceledAt = IBondGovernor(governor).proposalCanceledAt(proposalId);
        if (canceledAt == 0) return SlashReason.TimelockVeto;
        if (canceledAt <= IBondGovernor(governor).proposalSnapshot(proposalId)) return SlashReason.None;
        return SlashReason.ActiveSelfCancel;
    }

    /// @dev Slash predicate — the rule the DAO ratified on Snapshot (EP 5.15), applied
    ///      verbatim on raw tallies: combined rejections strictly beat support AND
    ///      slash-weight strictly beats plain rejection. Either tie refunds. No per-address
    ///      scrubbing.
    function _slashVoted(uint256 proposalId) private view returns (bool) {
        uint256 forVotes = tally(proposalId, uint8(VoteType.For));
        uint256 againstVotes = tally(proposalId, uint8(VoteType.Against));
        uint256 slashVotes = tally(proposalId, uint8(VoteType.AgainstAndSlash));
        return againstVotes + slashVotes > forVotes && slashVotes > againstVotes;
    }

    /// @dev One-shot settle: flag first, single transfer after (CEI). Destination and event
    ///      derive from the reason alone — `None` refunds the proposer, anything else
    ///      forfeits to the treasury.
    function _settle(uint256 proposalId, Bond storage bond, SlashReason reason) private {
        bond.settled = true;
        bool slashed = reason != SlashReason.None;
        IERC20(address(token)).safeTransfer(slashed ? treasury : bond.proposer, bondAmount);
        if (slashed) emit BondSlashed(proposalId, bondAmount, reason);
        else emit BondRefunded(proposalId, bond.proposer, bondAmount);
    }
}
