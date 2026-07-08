// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IRuleset} from "./interfaces/IRuleset.sol";

/// @title GovernorNexus
/// @notice Modular router governor for ENS governance (blockful's Governor Nexus RFC).
///         The core owns the proposal lifecycle, vote casting, and Timelock admin;
///         per-type rulesets define quorum, approval thresholds, vote options, voting
///         period, and proposer eligibility.
///
///         Security mechanisms over stock OZ Governor:
///         - per-proposer active proposal limit (anti-spam);
///         - continuous proposer threshold enforcement: proposals whose proposer drops
///           below the threshold become cancelable by any address;
///         - proposer self-cancellation while Pending or Active;
///         - mutable votes (re-vote replaces the previous vote) — implemented by rulesets;
///         - batch (multicall) voting;
///         - late vote extension: a failing→passing flip inside the final window extends
///           the deadline once.
contract GovernorNexus is Governor, GovernorSettings, GovernorVotes, GovernorTimelockControl {
    /// @notice Proposal type used by the standard `propose()` entry point.
    uint8 public constant STANDARD_PROPOSAL_TYPE = 0;

    struct NexusConfig {
        uint48 votingDelay; // clock units (ENS token clock = block numbers)
        uint32 votingPeriod; // default / fallback voting period
        uint256 proposalThreshold;
        uint8 maxActiveProposals; // per-proposer limit on Pending|Active proposals
        uint48 lateVoteWindow; // final window in which a failing→passing flip extends voting
        uint48 lateVoteExtension; // extension duration, applied once per proposal
    }

    address private immutable _rulesetInitializer;
    bool private _rulesetsInitialized;

    mapping(uint8 typeId => IRuleset) private _rulesets;
    // Ruleset snapshotted per proposal at creation: replacing a type's ruleset
    // never affects live proposals.
    mapping(uint256 proposalId => IRuleset) private _proposalRuleset;
    mapping(uint256 proposalId => uint16 typePlusOne) private _proposalType;
    mapping(address proposer => uint256[] proposalIds) private _activeProposals;

    uint8 private _maxActiveProposals;
    uint48 private _lateVoteWindow;
    uint48 private _lateVoteExtension;
    mapping(uint256 proposalId => uint48) private _extendedDeadline;
    mapping(uint256 proposalId => bool) private _lateExtensionUsed;

    // Set only for the duration of proposeWithType so votingPeriod() resolves to the
    // ruleset's period inside OZ's _propose (stored duration + event stay correct).
    IRuleset private transient _proposeRulesetContext;

    event RulesetSet(uint8 indexed proposalType, address indexed ruleset);
    event ProposalCreatedWithType(uint256 indexed proposalId, uint8 indexed proposalType, address indexed ruleset);
    event ProposalExtended(uint256 indexed proposalId, uint64 extendedDeadline);
    event MaxActiveProposalsSet(uint8 maxActiveProposals);
    event LateVoteExtensionSet(uint48 lateVoteWindow, uint48 lateVoteExtension);

    error UnknownProposalType(uint8 proposalType);
    error ProposerActiveLimitReached(address proposer, uint256 limit);
    error BatchLengthMismatch();
    error RulesetsAlreadyInitialized();
    error NotRulesetInitializer(address caller);
    error NonexistentProposal(uint256 proposalId);

    constructor(IVotes token_, TimelockController timelock_, NexusConfig memory config_)
        Governor("ENS Governor Nexus")
        GovernorSettings(config_.votingDelay, config_.votingPeriod, config_.proposalThreshold)
        GovernorVotes(token_)
        GovernorTimelockControl(timelock_)
    {
        _rulesetInitializer = _msgSender();
        _setMaxActiveProposals(config_.maxActiveProposals);
        _setLateVoteExtension(config_.lateVoteWindow, config_.lateVoteExtension);
    }

    // ─────────────────────────────── Ruleset registry ───────────────────────────────

    /// @notice One-shot ruleset bootstrap by the deployer (rulesets need the governor
    ///         address, so they deploy after it). All later changes go through governance.
    function initializeRulesets(uint8[] calldata typeIds, IRuleset[] calldata rulesets_) external {
        if (_msgSender() != _rulesetInitializer) revert NotRulesetInitializer(_msgSender());
        if (_rulesetsInitialized) revert RulesetsAlreadyInitialized();
        if (typeIds.length != rulesets_.length) revert BatchLengthMismatch();
        _rulesetsInitialized = true;
        for (uint256 i = 0; i < typeIds.length; ++i) {
            _rulesets[typeIds[i]] = rulesets_[i];
            emit RulesetSet(typeIds[i], address(rulesets_[i]));
        }
    }

    /// @notice Registers, replaces, or disables (address(0)) the ruleset for a proposal
    ///         type. Live proposals keep the ruleset snapshotted at their creation.
    function setRuleset(uint8 proposalType_, IRuleset ruleset_) external onlyGovernance {
        _rulesets[proposalType_] = ruleset_;
        emit RulesetSet(proposalType_, address(ruleset_));
    }

    function ruleset(uint8 proposalType_) public view returns (IRuleset) {
        return _rulesets[proposalType_];
    }

    /// @notice The proposal type declared at creation (immutable thereafter).
    function proposalType(uint256 proposalId) public view returns (uint8) {
        uint16 stored = _proposalType[proposalId];
        if (stored == 0) revert NonexistentProposal(proposalId);
        // safe: stored is always uint8 type + 1, so stored - 1 fits uint8
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(stored - 1);
    }

    /// @notice The ruleset bound to a proposal at creation.
    function proposalRuleset(uint256 proposalId) public view returns (IRuleset) {
        return _proposalRuleset[proposalId];
    }

    // ─────────────────────────────── Propose ───────────────────────────────

    /// @inheritdoc Governor
    /// @dev Routes to the Standard proposal type, preserving the stock IGovernor flow.
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256) {
        return proposeWithType(targets, values, calldatas, description, STANDARD_PROPOSAL_TYPE);
    }

    /// @notice Creates a proposal under an explicit proposal type. The type is declared
    ///         at creation and cannot change. Rulesets that don't require the proposer
    ///         threshold (e.g. bond-backed proposals) enforce their own eligibility in
    ///         `onPropose`.
    function proposeWithType(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint8 proposalType_
    ) public virtual returns (uint256) {
        address proposer = _msgSender();

        if (!_isValidDescriptionForProposer(proposer, description)) {
            revert GovernorRestrictedProposer(proposer);
        }

        IRuleset ruleset_ = _rulesets[proposalType_];
        if (address(ruleset_) == address(0)) revert UnknownProposalType(proposalType_);

        if (ruleset_.requiresProposerThreshold()) {
            uint256 votesThreshold = proposalThreshold();
            if (votesThreshold > 0) {
                uint256 proposerVotes = getVotes(proposer, clock() - 1);
                if (proposerVotes < votesThreshold) {
                    revert GovernorInsufficientProposerVotes(proposer, proposerVotes, votesThreshold);
                }
            }
        }

        _pruneAndCheckActiveLimit(proposer);

        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);

        _proposalType[proposalId] = uint16(proposalType_) + 1;
        _proposalRuleset[proposalId] = ruleset_;

        ruleset_.onPropose(proposalId, proposer, targets, values, calldatas, descriptionHash);

        _proposeRulesetContext = ruleset_;
        _propose(targets, values, calldatas, description, proposer);
        _proposeRulesetContext = IRuleset(address(0));

        _activeProposals[proposer].push(proposalId);
        emit ProposalCreatedWithType(proposalId, proposalType_, address(ruleset_));

        return proposalId;
    }

    /// @dev Drops tracked proposals that left Pending|Active, then enforces the limit.
    function _pruneAndCheckActiveLimit(address proposer) internal {
        uint256[] storage ids = _activeProposals[proposer];
        uint256 i = 0;
        while (i < ids.length) {
            ProposalState s = state(ids[i]);
            if (s == ProposalState.Pending || s == ProposalState.Active) {
                ++i;
            } else {
                ids[i] = ids[ids.length - 1];
                ids.pop();
            }
        }
        if (ids.length >= _maxActiveProposals) {
            revert ProposerActiveLimitReached(proposer, _maxActiveProposals);
        }
    }

    /// @notice Number of the proposer's tracked proposals still Pending|Active.
    function activeProposalCount(address proposer) public view returns (uint256 count) {
        uint256[] storage ids = _activeProposals[proposer];
        for (uint256 i = 0; i < ids.length; ++i) {
            ProposalState s = state(ids[i]);
            if (s == ProposalState.Pending || s == ProposalState.Active) ++count;
        }
    }

    function maxActiveProposals() public view returns (uint8) {
        return _maxActiveProposals;
    }

    function setMaxActiveProposals(uint8 maxActiveProposals_) external onlyGovernance {
        _setMaxActiveProposals(maxActiveProposals_);
    }

    function _setMaxActiveProposals(uint8 maxActiveProposals_) internal {
        _maxActiveProposals = maxActiveProposals_;
        emit MaxActiveProposalsSet(maxActiveProposals_);
    }

    // ─────────────────────────────── Cancel ───────────────────────────────

    /// @dev Cancellation policy (RFC §2.1, §2.2):
    ///      - the proposer may cancel while the proposal is Pending or Active;
    ///      - ANY address may cancel a Pending|Active proposal whose ruleset requires the
    ///        proposer threshold and whose proposer's current voting power is below it.
    function _validateCancel(uint256 proposalId, address caller) internal view virtual override returns (bool) {
        ProposalState s = state(proposalId);
        if (s != ProposalState.Pending && s != ProposalState.Active) return false;

        address proposer = proposalProposer(proposalId);
        if (caller == proposer) return true;

        IRuleset ruleset_ = _proposalRuleset[proposalId];
        if (address(ruleset_) != address(0) && ruleset_.requiresProposerThreshold()) {
            uint256 votesThreshold = proposalThreshold();
            if (votesThreshold > 0 && getVotes(proposer, clock() - 1) < votesThreshold) {
                return true;
            }
        }
        return false;
    }

    // ─────────────────────────────── Voting ───────────────────────────────

    /// @notice Casts votes on several proposals in one transaction (RFC §2.3).
    function castVoteBatch(uint256[] calldata proposalIds, uint8[] calldata supportValues, string[] calldata reasons)
        public
        virtual
        returns (uint256[] memory weights)
    {
        if (proposalIds.length != supportValues.length || proposalIds.length != reasons.length) {
            revert BatchLengthMismatch();
        }
        address voter = _msgSender();
        weights = new uint256[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; ++i) {
            weights[i] = _castVote(proposalIds[i], voter, supportValues[i], reasons[i]);
        }
    }

    /// @dev Dispatches counting to the proposal's ruleset (mutable votes live there) and
    ///      applies the late vote extension (RFC §2.6): if the proposal flips from failing
    ///      to passing inside the final `lateVoteWindow`, the deadline extends once by
    ///      `lateVoteExtension` from the current clock.
    function _countVote(uint256 proposalId, address account, uint8 support, uint256 totalWeight, bytes memory params)
        internal
        virtual
        override
        returns (uint256)
    {
        IRuleset ruleset_ = _proposalRuleset[proposalId];

        bool checkLateFlip = _lateVoteWindow != 0 && !_lateExtensionUsed[proposalId]
            && clock() + _lateVoteWindow >= proposalDeadline(proposalId);
        bool wasPassing =
            checkLateFlip && ruleset_.quorumReached(proposalId) && ruleset_.voteSucceeded(proposalId);

        uint256 votedWeight = ruleset_.countVote(proposalId, account, support, totalWeight, params);

        if (
            checkLateFlip && !wasPassing && ruleset_.quorumReached(proposalId)
                && ruleset_.voteSucceeded(proposalId)
        ) {
            _lateExtensionUsed[proposalId] = true;
            uint48 newDeadline = clock() + _lateVoteExtension;
            _extendedDeadline[proposalId] = newDeadline;
            emit ProposalExtended(proposalId, newDeadline);
        }

        return votedWeight;
    }

    /// @inheritdoc Governor
    function proposalDeadline(uint256 proposalId) public view virtual override returns (uint256) {
        uint256 base = super.proposalDeadline(proposalId);
        uint256 extended = _extendedDeadline[proposalId];
        return extended > base ? extended : base;
    }

    function lateVoteWindow() public view returns (uint48) {
        return _lateVoteWindow;
    }

    function lateVoteExtension() public view returns (uint48) {
        return _lateVoteExtension;
    }

    function setLateVoteExtension(uint48 lateVoteWindow_, uint48 lateVoteExtension_) external onlyGovernance {
        _setLateVoteExtension(lateVoteWindow_, lateVoteExtension_);
    }

    function _setLateVoteExtension(uint48 lateVoteWindow_, uint48 lateVoteExtension_) internal {
        _lateVoteWindow = lateVoteWindow_;
        _lateVoteExtension = lateVoteExtension_;
        emit LateVoteExtensionSet(lateVoteWindow_, lateVoteExtension_);
    }

    // ─────────────────────────── Ruleset dispatch (views) ───────────────────────────

    /// @notice Generic counting-mode descriptor; counting semantics are ruleset-defined.
    ///         See `proposalCountingMode(proposalId)` for a specific proposal.
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo&quorum=for,abstain&params=ruleset";
    }

    /// @notice Counting mode of the ruleset bound to a specific proposal.
    function proposalCountingMode(uint256 proposalId) public view returns (string memory) {
        return _proposalRuleset[proposalId].COUNTING_MODE();
    }

    /// @notice Whether `account` has a currently-counted vote on `proposalId`.
    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _proposalRuleset[proposalId].hasVoted(proposalId, account);
    }

    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        return _proposalRuleset[proposalId].quorumReached(proposalId);
    }

    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        return _proposalRuleset[proposalId].voteSucceeded(proposalId);
    }

    /// @inheritdoc Governor
    /// @dev Informational: returns the Standard ruleset's quorum. The authoritative
    ///      per-proposal check is the bound ruleset's `quorumReached`.
    function quorum(uint256) public view virtual override returns (uint256) {
        IRuleset standard = _rulesets[STANDARD_PROPOSAL_TYPE];
        return address(standard) == address(0) ? 0 : standard.quorum(0);
    }

    /// @notice Quorum for a specific proposal, as defined by its ruleset.
    function proposalQuorum(uint256 proposalId) public view returns (uint256) {
        return _proposalRuleset[proposalId].quorum(proposalId);
    }

    /// @inheritdoc GovernorSettings
    /// @dev Inside proposeWithType this resolves to the ruleset's voting period (when
    ///      nonzero) so OZ's stored duration and ProposalCreated event are correct.
    function votingPeriod() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        IRuleset ruleset_ = _proposeRulesetContext;
        if (address(ruleset_) != address(0)) {
            uint256 rulesetPeriod = ruleset_.votingPeriod();
            if (rulesetPeriod != 0) return rulesetPeriod;
        }
        return super.votingPeriod();
    }

    // ─────────────────────────── Required overrides ───────────────────────────

    function votingDelay() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function proposalThreshold() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId)
        public
        view
        virtual
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        virtual
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view virtual override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
