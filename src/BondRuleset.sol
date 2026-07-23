// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IRuleset} from "./IRuleset.sol";
import {IProposalValidator} from "./IProposalValidator.sol";
import {RulesetCounting} from "./RulesetCounting.sol";

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
///      one-shot; refunds release only in terminal states (`Executed`/`Defeated`/`Canceled`)
///      so the security council's veto window is never front-run.
contract BondRuleset is RulesetCounting, IProposalValidator {
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

    /// @notice A locked proposal bond.
    struct Bond {
        address proposer;
        uint96 amount;
        bool settled;
    }

    uint256 private constant QUORUM_DENOMINATOR = 100;

    /// @notice Voting token: quorum anchor and the bond's currency.
    IVotes public immutable token;
    /// @notice Quorum numerator over the fixed 100 denominator.
    uint256 public immutable quorumNumerator;
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
    error InvalidQuorumFraction(uint256 numerator, uint256 denominator);
    error BondAlreadyLocked(uint256 proposalId);
    error ZeroBondReceived();
    error NoBond(uint256 proposalId);
    error BondAlreadySettled(uint256 proposalId);
    error BondNotResolvable(uint256 proposalId, IGovernor.ProposalState state);

    constructor(address governor_, IVotes token_, uint256 quorumNumerator_, uint256 bondAmount_, address treasury_)
        RulesetCounting(governor_)
    {
        if (quorumNumerator_ > QUORUM_DENOMINATOR) {
            revert InvalidQuorumFraction(quorumNumerator_, QUORUM_DENOMINATOR);
        }
        if (bondAmount_ == 0 || bondAmount_ > type(uint96).max) revert InvalidBondAmount(bondAmount_);
        if (treasury_ == address(0)) revert ZeroTreasury();
        token = token_;
        quorumNumerator = quorumNumerator_;
        bondAmount = bondAmount_;
        treasury = treasury_;
    }

    /// @notice The bond locked for `proposalId` (zeroed struct if none).
    function bondOf(uint256 proposalId) external view returns (address proposer, uint96 amount, bool settled) {
        Bond storage bond = _bonds[proposalId];
        return (bond.proposer, bond.amount, bond.settled);
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
    function quorum(uint256 timepoint) public view returns (uint256) {
        return token.getPastTotalSupply(timepoint) * quorumNumerator / QUORUM_DENOMINATOR;
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
    /// @dev Pulls the bond and records it under the canonical proposalId.
    function validateProposal(
        address proposer,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external onlyGovernor {
        uint256 proposalId = uint256(keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
        if (_bonds[proposalId].proposer != address(0)) revert BondAlreadyLocked(proposalId);
        IERC20 erc20 = IERC20(address(token));
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(proposer, address(this), bondAmount);
        uint256 received = erc20.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroBondReceived();

        // received ≤ bondAmount ≤ uint96.max (constructor bound) — cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        _bonds[proposalId] = Bond({proposer: proposer, amount: uint96(received), settled: false});
        emit BondLocked(proposalId, proposer, received);
    }

    /// @notice Settles `proposalId`'s bond once its outcome is final. Permissionless and
    ///         one-shot: anyone may trigger settlement, nobody can trigger it twice.
    /// @dev Refund releases only in terminal states — `Succeeded`/`Queued` revert so the
    ///      security council's timelock-veto window can never be front-run by an early
    ///      refund. Effects (settled flag) precede the single transfer (CEI).
    function resolveBond(uint256 proposalId) external {
        Bond storage bond = _bonds[proposalId];
        if (bond.proposer == address(0)) revert NoBond(proposalId);
        if (bond.settled) revert BondAlreadySettled(proposalId);

        (address to, SlashReason reason, bool slashed) = _bondResolution(proposalId, bond.proposer);
        _settle(proposalId, bond, to, reason, slashed);
    }

    /// @dev Maps a terminal proposal state to the bond's destination, reason, and slash flag.
    ///      Non-terminal states revert, so a refund can never front-run the council's veto window.
    function _bondResolution(uint256 proposalId, address proposer)
        private
        view
        returns (address to, SlashReason reason, bool slashed)
    {
        IGovernor.ProposalState state = IBondGovernor(governor).state(proposalId);
        if (state == IGovernor.ProposalState.Executed) return (proposer, SlashReason.None, false);
        if (state == IGovernor.ProposalState.Defeated) {
            if (_slashVoted(proposalId, proposer)) return (treasury, SlashReason.SlashVote, true);
            return (proposer, SlashReason.None, false);
        }
        if (state == IGovernor.ProposalState.Canceled) return _canceledBondResolution(proposalId, proposer);
        revert BondNotResolvable(proposalId, state);
    }

    /// @dev Cancel partition on the recorded cancel timepoint: a self-cancel while still Pending
    ///      (`0 < canceledAt <= snapshot`) refunds; a council veto (no governor-path timepoint,
    ///      `canceledAt == 0`) or a self-cancel after voting opened forfeits.
    function _canceledBondResolution(uint256 proposalId, address proposer)
        private
        view
        returns (address to, SlashReason reason, bool slashed)
    {
        uint48 canceledAt = IBondGovernor(governor).proposalCanceledAt(proposalId);
        if (canceledAt == 0) return (treasury, SlashReason.TimelockVeto, true);
        if (canceledAt <= IBondGovernor(governor).proposalSnapshot(proposalId)) {
            return (proposer, SlashReason.None, false);
        }
        return (treasury, SlashReason.ActiveSelfCancel, true);
    }

    /// @dev Slash predicate: rejections beat approvals AND, with the proposer's own standing
    ///      vote removed from both opposition buckets, slash-weight beats plain-No.
    function _slashVoted(uint256 proposalId, address proposer) private view returns (bool) {
        uint256 forVotes = tally(proposalId, uint8(VoteType.For));
        uint256 againstVotes = tally(proposalId, uint8(VoteType.Against));
        uint256 slashVotes = tally(proposalId, uint8(VoteType.AgainstAndSlash));
        if (againstVotes + slashVotes <= forVotes) return false;

        (bool voted, uint8 support, uint256 weight) = voteReceipt(proposalId, proposer);
        if (voted) {
            if (support == uint8(VoteType.Against)) againstVotes -= weight;
            else if (support == uint8(VoteType.AgainstAndSlash)) slashVotes -= weight;
        }
        return slashVotes > againstVotes;
    }

    /// @dev One-shot settle: flag first, single transfer after (CEI).
    function _settle(uint256 proposalId, Bond storage bond, address to, SlashReason reason, bool slashed) private {
        bond.settled = true;
        uint256 amount = bond.amount;
        IERC20(address(token)).safeTransfer(to, amount);
        if (slashed) emit BondSlashed(proposalId, amount, reason);
        else emit BondRefunded(proposalId, bond.proposer, amount);
    }
}
