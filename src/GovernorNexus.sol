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

    /// @dev Proposal-to-type pin, written exactly once at propose time.
    mapping(uint256 proposalId => uint8) private _proposalType;

    /// @dev Ids of the proposer's tracked proposals, lazily pruned of entries that left
    ///      Pending|Active on the proposer's next propose. Invariant-bounded: an id is
    ///      pushed only after {_pruneAndCheckActiveLimit} passes, so length can never
    ///      exceed `_maxActiveProposals` — propose gas is O(cap), independent of global
    ///      state, and no entry exists for an address that never proposed.
    mapping(address proposer => uint256[] proposalIds) private _activeProposals;

    /// @dev Per-proposer cap on concurrently live (Pending|Active) proposals.
    uint8 private _maxActiveProposals;

    /// @notice Hard ceiling `setMaxActiveProposals` can never exceed. Bounds the
    ///         propose-time prune to at most 10 `state()` reads; a per-key cap above 10 is
    ///         no longer meaningfully a spam limit and warrants an upgrade instead.
    uint8 public constant MAX_ACTIVE_PROPOSALS_CEILING = 10;

    /// @dev Transaction-scoped propose-time type context (EIP-1153 transient storage, spec
    ///      D10). Holds `typeId + 1` only while `_proposeWithType` runs `super._propose`, so
    ///      `votingDelay()`/`votingPeriod()` serve the typed line values to the stock
    ///      `_propose` body without a persistent-storage handoff; 0 means "unset", keeping
    ///      type 0 distinguishable from "no context". `uint16` so `typeId + 1` cannot wrap.
    uint16 private transient _typeContext;

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
    /// @notice The per-proposer live-proposal cap was set.
    event MaxActiveProposalsSet(uint8 maxActiveProposals);
    /// @notice A proposal was created and pinned to `typeId` (companion to the stock
    ///         `ProposalCreated`, emitted in the same call).
    event ProposalTypedCreated(uint256 indexed proposalId, uint8 indexed typeId, IRuleset indexed ruleset);

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
    /// @notice `proposer` already has `maxActiveProposals` live (Pending|Active) proposals.
    error ProposerActiveLimitReached(address proposer, uint8 maxActiveProposals);
    /// @notice The cap is zero (bricks every propose) or above the ceiling.
    error InvalidMaxActiveProposals(uint8 maxActiveProposals);

    /// @param name_ Governor name; feeds `name()` and the EIP-712 domain separator that
    ///        vote-by-sig is bound to. The deploy chooses the domain (`"ENS Governor"` for
    ///        the ENS deployment, so vote-by-sig signatures match the live governor's
    ///        domain), leaving the contract itself reusable across deployments (spec D11).
    /// @param token Voting token (block-number or timestamp clock, per the token).
    /// @param timelock Executor holding queued proposals; also the sole governance caller.
    /// @param standardRuleset Ruleset for the bootstrap type (row 0), the default.
    /// @param votingDelay_ Bootstrap type voting delay.
    /// @param votingPeriod_ Bootstrap type voting period; must be non-zero.
    /// @param proposalThreshold_ Bootstrap type proposal threshold.
    /// @param maxActiveProposals_ Per-proposer live-proposal cap (RFC deploy value: 2);
    ///        `1..MAX_ACTIVE_PROPOSALS_CEILING`, enforced by the same guard as the setter.
    /// @dev Registers row 0 under the same guardrails as `registerType` and sets it as the
    ///      default, atomically. No deployer-privileged post-deploy setup exists.
    constructor(
        string memory name_,
        IVotes token,
        TimelockController timelock,
        IRuleset standardRuleset,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint8 maxActiveProposals_
    ) Governor(name_) GovernorVotes(token) GovernorTimelockControl(timelock) {
        _registerType(standardRuleset, votingDelay_, votingPeriod_, proposalThreshold_);
        defaultTypeId = 0;
        _setMaxActiveProposals(maxActiveProposals_);
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

    /// @notice Set the per-proposer live-proposal cap.
    /// @param maxActiveProposals_ New cap; `1..MAX_ACTIVE_PROPOSALS_CEILING`.
    function setMaxActiveProposals(uint8 maxActiveProposals_) external onlyGovernance {
        _setMaxActiveProposals(maxActiveProposals_);
    }

    /// @dev Shared by the constructor and {setMaxActiveProposals} so the guard cannot drift.
    ///      Zero is rejected because `length >= 0` holds for every proposer — every propose
    ///      (including the governance proposal needed to raise the cap back) would revert
    ///      forever.
    function _setMaxActiveProposals(uint8 maxActiveProposals_) private {
        if (maxActiveProposals_ == 0 || maxActiveProposals_ > MAX_ACTIVE_PROPOSALS_CEILING) {
            revert InvalidMaxActiveProposals(maxActiveProposals_);
        }
        _maxActiveProposals = maxActiveProposals_;
        emit MaxActiveProposalsSet(maxActiveProposals_);
    }

    /// @dev Single registration path shared by the constructor and `registerType`, so
    ///      guardrails and the `TypeRegistered` event cannot drift. Ids are never reused;
    ///      `typeCount++` on a `uint8` panics once `typeCount == 255`, so the last
    ///      registrable id is 254 — the table caps at 255 rows (ids 0-254).
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

    // ─────────────────────────── Propose paths ───────────────────────────

    /// @notice Create a proposal governed by type `typeId`, pinning it for its lifetime.
    /// @dev Mirrors the stock `propose()` pre-checks with per-type parameters: the
    ///      `#proposer=` suffix defense, type existence + `active`, and the type line's
    ///      `proposalThreshold` against the proposer's votes at `clock() - 1`. Everything
    ///      else (length/duplicate validation, storage, `ProposalCreated`) runs in the
    ///      stock `_propose` via {_proposeWithType}.
    /// @param targets Call targets, one per action.
    /// @param values ETH values, one per action.
    /// @param calldatas Encoded calls, one per action.
    /// @param description Human-readable description; hashed into the proposal id.
    /// @param typeId Registered, active proposal type to pin.
    /// @return proposalId Stock type-agnostic proposal id (typeId is NOT hashed — spec D2).
    function proposeWithType(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint8 typeId
    ) public virtual returns (uint256) {
        address proposer = _msgSender();

        // check description restriction (stock `propose` shape, enforced on both doors)
        if (!_isValidDescriptionForProposer(proposer, description)) {
            revert GovernorRestrictedProposer(proposer);
        }

        // type must exist and accept new proposals
        if (typeId >= typeCount) revert NonexistentType(typeId);
        if (!_types[typeId].active) revert TypeInactive(typeId);

        // check proposal threshold (stock shape, against the type line)
        uint256 votesThreshold = _types[typeId].proposalThreshold;
        if (votesThreshold > 0) {
            uint256 proposerVotes = getVotes(proposer, clock() - 1);
            if (proposerVotes < votesThreshold) {
                revert GovernorInsufficientProposerVotes(proposer, proposerVotes, votesThreshold);
            }
        }

        return _proposeWithType(targets, values, calldatas, description, proposer, typeId);
    }

    /// @notice Stock door: equivalent to `proposeWithType(..., defaultTypeId)`.
    /// @dev Thin wrapper — all checks live in {proposeWithType}, so both doors route
    ///      through {_proposeWithType} and every created proposal carries a pin.
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256) {
        return proposeWithType(targets, values, calldatas, description, defaultTypeId);
    }

    /// @dev Creates the proposal through the stock `_propose` (sole `ProposalCore` writer —
    ///      it is `private` storage in OZ v5.6.1) under a transient type context, then pins.
    ///
    ///      Safety of the transient handoff (spec D10): the only external calls reachable
    ///      under the context are staticcalls inside stock `_propose`'s (Governor.sol:305-341)
    ///      duplicate-proposal branch (`state(proposalId)`, which can staticcall the ruleset
    ///      past-deadline or the timelock when queued) — and that branch reverts
    ///      unconditionally, so no committed state is ever produced while the context is
    ///      set. There is no reentrancy window in which `votingDelay()`/`votingPeriod()`
    ///      could mislead an external reader, and at rest they remain honest default-type
    ///      views. The clear after the `super` call is belt-and-braces on top of the
    ///      EIP-1153 end-of-transaction reset.
    function _proposeWithType(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer,
        uint8 typeId
    ) internal virtual returns (uint256 proposalId) {
        // Check-then-record inside the single ProposalCore-writing chokepoint, so no
        // creation door — present or future — can miss either half.
        _pruneAndCheckActiveLimit(proposer);

        _typeContext = uint16(typeId) + 1;
        proposalId = super._propose(targets, values, calldatas, description, proposer);
        _typeContext = 0;

        _proposalType[proposalId] = typeId;
        _activeProposals[proposer].push(proposalId);
        emit ProposalTypedCreated(proposalId, typeId, _types[typeId].ruleset);
    }

    // ─────────────────────────── Spam limit ───────────────────────────

    /// @dev Drops every tracked id that left the live set, then enforces the cap. The live
    ///      set is a positive whitelist — `Pending` or `Active`, nothing else: `Queued`
    ///      already survived the vote and `Canceled`/`Defeated`/`Executed` free their slot
    ///      immediately, so this is a concurrency cap, not a rate limit. New lifecycle
    ///      states fail closed (they do not occupy a slot) — revisit this whitelist if the
    ///      proposal lifecycle ever grows new states.
    function _pruneAndCheckActiveLimit(address proposer) private {
        uint256[] storage ids = _activeProposals[proposer];
        uint256 length = ids.length;
        uint256 i = 0;
        while (i < length) {
            if (_isLive(ids[i])) {
                ++i;
            } else {
                ids[i] = ids[length - 1];
                ids.pop();
                --length;
            }
        }
        if (length >= _maxActiveProposals) {
            revert ProposerActiveLimitReached(proposer, _maxActiveProposals);
        }
    }

    /// @dev Liveness probe that can never reach a ruleset. Past the deadline the
    ///      proposal cannot be Pending|Active, so it is settled on `proposalDeadline` alone —
    ///      `state()` is consulted only within the deadline, where its OZ v5.6.1 ordering
    ///      resolves purely from core storage (Executed/Canceled flags, snapshot, deadline)
    ///      and dispatches to `_quorumReached`/`_voteSucceeded` only in the branch this probe
    ///      never takes. A ruleset with poisoned views therefore cannot brick its proposer's
    ///      next propose (pinned by the adversarial suite's containment property).
    function _isLive(uint256 proposalId) private view returns (bool) {
        if (proposalDeadline(proposalId) < clock()) return false;
        ProposalState s = state(proposalId);
        return s == ProposalState.Pending || s == ProposalState.Active;
    }

    /// @notice Current per-proposer live-proposal cap.
    function maxActiveProposals() public view returns (uint8) {
        return _maxActiveProposals;
    }

    /// @notice Number of `proposer`'s proposals currently Pending|Active. Filters the
    ///         tracked set by liveness, so ids awaiting their lazy prune are never counted.
    function activeProposalCount(address proposer) external view returns (uint256 count) {
        uint256[] storage ids = _activeProposals[proposer];
        uint256 length = ids.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_isLive(ids[i])) ++count;
        }
    }

    // ─────────────────────── Default-type settings views ───────────────────────
    // Final spec form: the governor's propose-time parameters read the default type row —
    // except under the transient propose-time context, when they serve the typed line
    // (see `_proposeWithType`; never observable externally).

    /// @inheritdoc Governor
    function votingDelay() public view virtual override returns (uint256) {
        uint256 ctx = _typeContext;
        // `ctx` is `typeId + 1` with `typeId` a uint8 (see `_proposeWithType`), so `ctx - 1`
        // always fits uint8; the truncating-cast lint does not apply.
        // forge-lint: disable-next-line(unsafe-typecast)
        return _types[ctx != 0 ? uint8(ctx - 1) : defaultTypeId].votingDelay;
    }

    /// @inheritdoc Governor
    function votingPeriod() public view virtual override returns (uint256) {
        uint256 ctx = _typeContext;
        // `ctx` is `typeId + 1` with `typeId` a uint8 (see `_proposeWithType`), so `ctx - 1`
        // always fits uint8; the truncating-cast lint does not apply.
        // forge-lint: disable-next-line(unsafe-typecast)
        return _types[ctx != 0 ? uint8(ctx - 1) : defaultTypeId].votingPeriod;
    }

    /// @inheritdoc Governor
    /// @dev Always the default type row — unlike `votingDelay`/`votingPeriod`, this is never
    ///      served from the transient propose-time context, since `_propose` never reads
    ///      `proposalThreshold()` (the threshold check runs upstream, in
    ///      {proposeWithType}, against the pinned type's own line).
    function proposalThreshold() public view virtual override returns (uint256) {
        return _types[defaultTypeId].proposalThreshold;
    }

    // ─────────────────────────── Counting dispatch (Task 4) ───────────────────────────
    // The core never tallies: every counting hook forwards to the ruleset pinned to the
    // proposal's type. `COUNTING_MODE`/`quorum` take no proposal id, so they are documented
    // default-type views over `defaultTypeId`'s ruleset (per-proposal answers are reachable
    // via `proposalRuleset(id)`).

    /// @dev The ruleset governing `proposalId`, resolved through its propose-time type pin.
    ///      Safe without an existence check on the hot path: the pin is written once at
    ///      creation and the type row's ruleset is content-immutable, and stock `Governor`
    ///      state checks reject votes/queries on nonexistent proposals before counting is
    ///      reached. A read-only `hasVoted` on a never-created id is the sole exception (see
    ///      its natspec).
    function _rulesetOf(uint256 proposalId) private view returns (IRuleset) {
        return _types[_proposalType[proposalId]].ruleset;
    }

    /// @inheritdoc IGovernor
    /// @dev Default-type view: the counting scheme of `defaultTypeId`'s ruleset. A specific
    ///      proposal's mode is `proposalRuleset(id).COUNTING_MODE()`.
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public view virtual override returns (string memory) {
        return _types[defaultTypeId].ruleset.COUNTING_MODE();
    }

    /// @inheritdoc IGovernor
    /// @dev Delegates to the proposal's ruleset. For a never-created `proposalId` this reads
    ///      the type-0 ruleset's (empty) tally and returns false rather than reverting — no
    ///      existence guard is added, since the answer is harmless and the hot path stays
    ///      cheap; use `proposalType`/`proposalRuleset` when an existence check is required.
    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _rulesetOf(proposalId).hasVoted(proposalId, account);
    }

    /// @inheritdoc Governor
    /// @dev Default-type view: quorum threshold from `defaultTypeId`'s ruleset at `timepoint`.
    function quorum(uint256 timepoint) public view virtual override returns (uint256) {
        return _types[defaultTypeId].ruleset.quorum(timepoint);
    }

    /// @dev Whether the proposal's ruleset considers quorum met.
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        return _rulesetOf(proposalId).quorumReached(proposalId);
    }

    /// @dev Whether the proposal's ruleset considers the vote successful.
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        return _rulesetOf(proposalId).voteSucceeded(proposalId);
    }

    /// @dev Routes a cast vote to the proposal's ruleset, which owns tallying and rule
    ///      enforcement (one-vote-per-voter, valid support). `totalWeight` is the core's
    ///      token-checkpoint weight at the frozen snapshot; the ruleset buckets it and can
    ///      never invent it. The returned counted weight bubbles back to `_castVote`.
    function _countVote(uint256 proposalId, address account, uint8 support, uint256 totalWeight, bytes memory params)
        internal
        virtual
        override
        returns (uint256)
    {
        return _rulesetOf(proposalId).countVote(proposalId, account, support, totalWeight, params);
    }

    // ─────────────────── Governor / GovernorTimelockControl overrides ───────────────────
    // Pure disambiguation between inherited modules; no behavior added.

    /// @inheritdoc IGovernor
    function state(uint256 proposalId)
        public
        view
        virtual
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /// @inheritdoc IGovernor
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
