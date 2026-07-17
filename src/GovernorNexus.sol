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

    /// @notice Final-window length of the late-flip trigger, in clock units.
    uint48 public immutable extensionWindow;
    /// @notice Length added past the ORIGINAL deadline when the extension fires, in clock
    ///         units.
    uint48 public immutable extensionDuration;

    /// @dev Late-flip extension state. Both bits are protection-monotone — they only ever
    ///      move toward granting the extension, so there is nothing a re-vote sequence can
    ///      burn. One slot, written at most twice per proposal.
    struct LateFlipExtension {
        bool sawFailingInWindow;
        bool extended;
    }

    mapping(uint256 proposalId => LateFlipExtension) private _lateFlip;

    /// @notice A proposal's voting period was extended by a late failing→passing flip.
    /// @dev Same ABI as OZ `GovernorPreventLateQuorum`'s event, so stock tooling decodes it.
    event ProposalExtended(uint256 indexed proposalId, uint64 extendedDeadline);

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
    /// @notice `votingPeriod` does not exceed `extensionWindow`, which would make the
    ///         "final window" span the entire vote.
    error VotingPeriodTooShort(uint32 votingPeriod, uint48 extensionWindow);
    /// @notice A late-flip extension parameter is zero.
    error InvalidExtensionConfig();

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
        uint48 extensionWindow_,
        uint48 extensionDuration_
    ) Governor(name_) GovernorVotes(token) GovernorTimelockControl(timelock) {
        if (extensionWindow_ == 0 || extensionDuration_ == 0) revert InvalidExtensionConfig();
        // Immutables first: _registerType validates votingPeriod against extensionWindow.
        extensionWindow = extensionWindow_;
        extensionDuration = extensionDuration_;
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
        // A period not exceeding the trigger window would make "the final window" the whole
        // vote, hollowing out the late-flip semantics.
        if (votingPeriod_ <= extensionWindow) revert VotingPeriodTooShort(votingPeriod_, extensionWindow);

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
        _typeContext = uint16(typeId) + 1;
        proposalId = super._propose(targets, values, calldatas, description, proposer);
        _typeContext = 0;

        _proposalType[proposalId] = typeId;
        emit ProposalTypedCreated(proposalId, typeId, _types[typeId].ruleset);
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

    // ─────────────────────────── Late-flip extension ───────────────────────────
    // A failing→passing flip inside the final `extensionWindow` extends voting once, by
    // `extensionDuration` past the ORIGINAL deadline — never past flip time, so placing the
    // flip later buys no extra calendar time. Trigger ("window low-water mark"): extend iff
    // the proposal was observed failing at any point inside the window AND would pass at the
    // original deadline. No state is armed on a tally-crossing event — under mutable votes
    // tallies oscillate, and a consumable one-shot slot could be burned on purpose (cross
    // early, re-vote down, snipe late with the protection spent). Both stored bits move only
    // toward GRANTING the extension, so no re-vote sequence can consume it; the only way to
    // avoid the extension is holding the proposal visibly passing for the entire final
    // window, which is itself the response time this mechanism exists to guarantee.
    // Observation is complete because tallies only change inside `_castVote`: a
    // failing state created by a vote is seen post-count (`_tallyUpdated`), one inherited from
    // before the window is seen by the first in-window cast's pre-count check, and a window
    // with no votes cannot contain a flip at all.

    /// @dev "Would the proposal pass if voting closed now" — the exact conjunction `state()`'s
    ///      post-deadline branch evaluates, dispatched to the pinned ruleset. Reading
    ///      through the ruleset makes the mechanism type-agnostic: every registered type gets
    ///      the extension under its own semantics with zero type-specific code here.
    function _wouldPass(uint256 proposalId) private view returns (bool) {
        return _quorumReached(proposalId) && _voteSucceeded(proposalId);
    }

    /// @dev The single observation point, run pre-count (from `_castVote`, seeing the tally a
    ///      vote is about to change) and post-count (from `_tallyUpdated`, seeing what it
    ///      changed). In the window: record a failing observation. After the original
    ///      deadline: materialize the (already-determined) extension on the first cast —
    ///      freezing the decision BEFORE this vote mutates the tally, which is sound because
    ///      the tally cannot have changed between the deadline and now (any earlier post-
    ///      deadline cast would have materialized first). Never reverts (OZ `_tallyUpdated`
    ///      hard rule); a cast that reaches this while the proposal is not Active is undone
    ///      wholesale when `super._castVote` reverts, so `extended` only ever commits as true.
    ///      The in-window bound is computed additively so a nonexistent id (deadline 0)
    ///      cannot underflow — it falls through untouched to stock existence reverts.
    function _observeLateFlip(uint256 proposalId) private {
        uint256 originalDeadline = super.proposalDeadline(proposalId);
        uint256 current = clock();
        LateFlipExtension storage lateFlip = _lateFlip[proposalId];

        if (current <= originalDeadline) {
            if (
                current + extensionWindow >= originalDeadline && !lateFlip.sawFailingInWindow && !_wouldPass(proposalId)
            ) {
                lateFlip.sawFailingInWindow = true;
            }
        } else if (!lateFlip.extended && lateFlip.sawFailingInWindow && _wouldPass(proposalId)) {
            lateFlip.extended = true;
            // originalDeadline + extensionDuration ≪ 2^64 (both derive from uint48 domains).
            // forge-lint: disable-next-line(unsafe-typecast)
            emit ProposalExtended(proposalId, uint64(originalDeadline + extensionDuration));
        }
    }

    /// @dev Pre-count observation: sees the tally state this vote is about to change, catching
    ///      a failing state inherited from before the window and materializing a pending
    ///      extension before the tally mutates. Internal, so every cast path is covered —
    ///      including `castVoteBySig`/`castVoteWithReasonAndParamsBySig`, which the public
    ///      `castVote*` overrides below do not intercept.
    function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
        internal
        virtual
        override
        returns (uint256)
    {
        _observeLateFlip(proposalId);
        return super._castVote(proposalId, account, support, reason, params);
    }

    /// @dev Post-count observation: catches the vote that itself CREATES a failing state
    ///      inside the window (e.g. the dip of a dip-and-recover sequence).
    function _tallyUpdated(uint256 proposalId) internal virtual override {
        super._tallyUpdated(proposalId);
        _observeLateFlip(proposalId);
    }

    /// @inheritdoc IGovernor
    /// @dev Extended lazily past the original deadline (never before it — a mid-window flip
    ///      can still revert, so nothing is promised early). After the original deadline the
    ///      answer comes from the materialized bit or, until the first extension-period cast
    ///      materializes it, from a live read — sound because the tally is frozen from the
    ///      deadline until that first cast (so views stay authoritative even if nobody ever
    ///      votes in the extension and `ProposalExtended` never fires). `state()` needs no
    ///      override: Active-through-the-extension and the final verdict both follow from
    ///      this view.
    function proposalDeadline(uint256 proposalId) public view virtual override returns (uint256) {
        uint256 originalDeadline = super.proposalDeadline(proposalId);
        if (clock() <= originalDeadline) return originalDeadline;

        LateFlipExtension storage lateFlip = _lateFlip[proposalId];
        if (lateFlip.extended || (lateFlip.sawFailingInWindow && _wouldPass(proposalId))) {
            return originalDeadline + extensionDuration;
        }
        return originalDeadline;
    }

    // ─────────────────────────── Direct-vote nonce spend (D21) ───────────────────────────
    // Under mutable votes (Nexus 2) the last-applied cast wins, so an outstanding signed ballot a
    // voter handed a relayer could be submitted AFTER they change their mind and vote directly,
    // overriding that direct vote. OZ only spends the EIP-712 vote nonce on the `bySig` paths, so a
    // direct cast leaves outstanding signatures live. These overrides spend the voter's nonce on
    // every direct cast too, so acting directly invalidates any outstanding signed ballot — the
    // governance analogue of Seaport's `incrementCounter` / Permit2's `invalidateUnorderedNonces`.
    // The nonce is account-global, so a direct vote invalidates the voter's pending vote-signatures
    // across all open proposals, not just the one voted on (D21 accepted trade-off).

    /// @inheritdoc IGovernor
    function castVote(uint256 proposalId, uint8 support) public virtual override returns (uint256) {
        _useNonce(_msgSender());
        return super.castVote(proposalId, support);
    }

    /// @inheritdoc IGovernor
    function castVoteWithReason(uint256 proposalId, uint8 support, string calldata reason)
        public
        virtual
        override
        returns (uint256)
    {
        _useNonce(_msgSender());
        return super.castVoteWithReason(proposalId, support, reason);
    }

    /// @inheritdoc IGovernor
    function castVoteWithReasonAndParams(uint256 proposalId, uint8 support, string calldata reason, bytes memory params)
        public
        virtual
        override
        returns (uint256)
    {
        _useNonce(_msgSender());
        return super.castVoteWithReasonAndParams(proposalId, support, reason, params);
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
