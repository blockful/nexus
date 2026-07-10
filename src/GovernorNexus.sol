// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IRuleset} from "./IRuleset.sol";

/// @title GovernorNexus
/// @notice Modular ENS governor core. Replaces OZ's baked-in settings/counting/quorum
///         extensions with a governed table of proposal types, each pinning a pluggable
///         `IRuleset` plus the propose-time parameters (delay, period, threshold).
/// @dev Stock OZ v5.6.1 `Governor` + `GovernorVotes` + `GovernorTimelockControl`; the
///      dropped extensions (`GovernorSettings`, `GovernorCountingSimple`,
///      `GovernorVotesQuorumFraction`) are supplied here — settings from the default type
///      row, counting via ruleset dispatch (Task 4). The type table is append-only and
///      content-immutable (spec D5): only `active` toggles and the default pointer move.
contract GovernorNexus is Governor, GovernorVotes, GovernorTimelockControl {
    /// @notice A registered proposal type. `ruleset`, `votingDelay`, `votingPeriod` and
    ///         `proposalThreshold` are set once at registration and never mutated;
    ///         `active` is the only mutable field and gates NEW proposals only.
    struct TypeConfig {
        IRuleset ruleset;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        bool active;
    }

    mapping(uint8 => TypeConfig) private _types;

    /// @notice Number of registered types; also the id the next `registerType` will assign.
    uint8 public typeCount;

    /// @notice Type id whose row supplies the default `votingDelay`/`votingPeriod`/
    ///         `proposalThreshold` and backs untyped proposals.
    uint8 public defaultTypeId;

    /// @dev Proposal-to-type pin, written at propose time (Task 3).
    mapping(uint256 proposalId => uint8) private _proposalType;

    /// @notice A new type was appended to the table.
    event TypeRegistered(
        uint8 indexed typeId,
        IRuleset indexed ruleset,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold
    );
    /// @notice A type's `active` flag was set.
    event TypeActiveSet(uint8 indexed typeId, bool active);
    /// @notice The default type pointer moved.
    event DefaultTypeSet(uint8 indexed typeId);

    /// @notice `ruleset` is the zero address.
    error RulesetZeroAddress();
    /// @notice `ruleset` does not advertise `IRuleset` via ERC165.
    error RulesetInterfaceUnsupported(address ruleset);
    /// @notice `votingPeriod` is zero, which would open a proposal with no voting window.
    error InvalidVotingPeriod();
    /// @notice `typeId` has never been registered (`typeId >= typeCount`).
    error NonexistentType(uint8 typeId);
    /// @notice `typeId` is the current default and cannot be deactivated.
    error CannotDeactivateDefaultType(uint8 typeId);
    /// @notice `typeId` cannot become the default while inactive.
    error TypeInactive(uint8 typeId);
    /// @dev Counting is dispatched to the ruleset in Task 4; the core does not tally.
    error CountingNotImplemented();

    /// @param token Voting token (block-number or timestamp clock, per the token).
    /// @param timelock Executor holding queued proposals; also the sole governance caller.
    /// @param standardRuleset Ruleset for the bootstrap type (row 0), the default.
    /// @param votingDelay_ Bootstrap type voting delay.
    /// @param votingPeriod_ Bootstrap type voting period; must be non-zero.
    /// @param proposalThreshold_ Bootstrap type proposal threshold.
    /// @dev Registers row 0 under the same guardrails as `registerType` and sets it as the
    ///      default, atomically. No deployer-privileged post-deploy setup exists.
    constructor(
        IVotes token,
        TimelockController timelock,
        IRuleset standardRuleset,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_
    ) Governor("GovernorNexus") GovernorVotes(token) GovernorTimelockControl(timelock) {
        _registerType(standardRuleset, votingDelay_, votingPeriod_, proposalThreshold_);
        defaultTypeId = 0;
    }

    // ─────────────────────────── Type registry ───────────────────────────

    /// @notice Append a new proposal type at `typeCount`, registered active.
    /// @param ruleset Non-zero address advertising `IRuleset` via ERC165.
    /// @param votingDelay_ Blocks/seconds between propose and snapshot.
    /// @param votingPeriod_ Voting window length; must be non-zero.
    /// @param proposalThreshold_ Minimum proposer voting power.
    /// @return id The id assigned to the new type.
    function registerType(IRuleset ruleset, uint48 votingDelay_, uint32 votingPeriod_, uint256 proposalThreshold_)
        external
        onlyGovernance
        returns (uint8 id)
    {
        return _registerType(ruleset, votingDelay_, votingPeriod_, proposalThreshold_);
    }

    /// @notice Toggle a type's `active` flag.
    /// @param typeId Existing type (`typeId < typeCount`); cannot be the current default when
    ///        deactivating.
    /// @param active New flag value.
    function setTypeActive(uint8 typeId, bool active) external onlyGovernance {
        if (typeId >= typeCount) revert NonexistentType(typeId);
        if (!active && typeId == defaultTypeId) revert CannotDeactivateDefaultType(typeId);
        _types[typeId].active = active;
        emit TypeActiveSet(typeId, active);
    }

    /// @notice Move the default type pointer.
    /// @param typeId Existing (`typeId < typeCount`) and active type.
    function setDefaultType(uint8 typeId) external onlyGovernance {
        if (typeId >= typeCount) revert NonexistentType(typeId);
        if (!_types[typeId].active) revert TypeInactive(typeId);
        defaultTypeId = typeId;
        emit DefaultTypeSet(typeId);
    }

    /// @dev Single registration path shared by the constructor and `registerType`, so
    ///      guardrails and the `TypeRegistered` event cannot drift. Ids are never reused;
    ///      the `uint8 typeCount++` overflow caps the table at 256 rows.
    function _registerType(IRuleset ruleset, uint48 votingDelay_, uint32 votingPeriod_, uint256 proposalThreshold_)
        private
        returns (uint8 id)
    {
        if (address(ruleset) == address(0)) revert RulesetZeroAddress();
        if (!ERC165Checker.supportsInterface(address(ruleset), type(IRuleset).interfaceId)) {
            revert RulesetInterfaceUnsupported(address(ruleset));
        }
        if (votingPeriod_ == 0) revert InvalidVotingPeriod();

        id = typeCount++;
        _types[id] = TypeConfig({
            ruleset: ruleset,
            votingDelay: votingDelay_,
            votingPeriod: votingPeriod_,
            proposalThreshold: proposalThreshold_,
            active: true
        });
        emit TypeRegistered(id, ruleset, votingDelay_, votingPeriod_, proposalThreshold_);
    }

    // ─────────────────────────── Introspection ───────────────────────────

    /// @notice Full configuration of `typeId`.
    /// @dev Reverts `NonexistentType` for an unregistered id.
    function getTypeConfig(uint8 typeId) external view returns (TypeConfig memory) {
        if (typeId >= typeCount) revert NonexistentType(typeId);
        return _types[typeId];
    }

    /// @notice Type pinned to `proposalId` at propose time.
    /// @dev Reverts `GovernorNonexistentProposal` when the proposal was never created, so a
    ///      never-created proposal cannot silently read as type 0.
    function proposalType(uint256 proposalId) public view returns (uint8) {
        if (proposalSnapshot(proposalId) == 0) revert GovernorNonexistentProposal(proposalId);
        return _proposalType[proposalId];
    }

    /// @notice Ruleset governing `proposalId` (via its pinned type).
    /// @dev Inherits the existence check of `proposalType`.
    function proposalRuleset(uint256 proposalId) external view returns (IRuleset) {
        return _types[proposalType(proposalId)].ruleset;
    }

    // ─────────────────────── Default-type settings views ───────────────────────
    // Final spec form: the governor's propose-time parameters read the default type row.

    /// @inheritdoc Governor
    function votingDelay() public view virtual override returns (uint256) {
        return _types[defaultTypeId].votingDelay;
    }

    /// @inheritdoc Governor
    function votingPeriod() public view virtual override returns (uint256) {
        return _types[defaultTypeId].votingPeriod;
    }

    /// @inheritdoc Governor
    function proposalThreshold() public view virtual override returns (uint256) {
        return _types[defaultTypeId].proposalThreshold;
    }

    // ─────────────────────────── Counting hooks (Task 4) ───────────────────────────
    // Placeholders until ruleset dispatch lands; kept abstract-satisfying and reverting.

    /// @inheritdoc IGovernor
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public view virtual override returns (string memory) {
        revert CountingNotImplemented();
    }

    /// @inheritdoc IGovernor
    function hasVoted(uint256, address) public view virtual override returns (bool) {
        revert CountingNotImplemented();
    }

    /// @inheritdoc Governor
    function quorum(uint256) public view virtual override returns (uint256) {
        revert CountingNotImplemented();
    }

    function _quorumReached(uint256) internal view virtual override returns (bool) {
        revert CountingNotImplemented();
    }

    function _voteSucceeded(uint256) internal view virtual override returns (bool) {
        revert CountingNotImplemented();
    }

    function _countVote(uint256, address, uint8, uint256, bytes memory) internal virtual override returns (uint256) {
        revert CountingNotImplemented();
    }

    // ─────────────────── Governor / GovernorTimelockControl overrides ───────────────────
    // Pure disambiguation between inherited modules; no behavior added.

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
