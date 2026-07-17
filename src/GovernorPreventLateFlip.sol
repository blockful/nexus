// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";

/// @title GovernorPreventLateFlip
/// @notice Governor extension that counters last-minute outcome flips ("sniping"): a
///         proposal that flips from failing to passing inside the final `extensionWindow`
///         of its voting period has its deadline extended once, by `extensionDuration`
///         past the ORIGINAL deadline — never past flip time, so placing the flip later
///         buys no extra calendar time. Voting stays unrestricted during the extension;
///         the tally at the extended deadline decides.
/// @dev Companion to OZ's `GovernorPreventLateQuorum`, hardened for non-monotonic tallies
///      (mutable votes, where re-voting can move the outcome in both directions). That
///      contract arms a consumable one-shot slot on the first quorum crossing, which a
///      re-vote sequence can burn on purpose: cross early, re-vote down, snipe late with
///      the protection already spent. Here nothing is armed on a tally-crossing event.
///      The trigger is a "window low-water mark": extend iff the proposal was observed
///      failing at any point inside the window AND would pass at the original deadline.
///      Both stored bits move only toward GRANTING the extension, so no vote sequence can
///      consume it — the only way to avoid the extension is holding the proposal visibly
///      passing for the entire final window, which is itself the response time this
///      mechanism exists to guarantee. Under monotonic (immutable-vote) tallies the
///      behavior degenerates to plain late-flip detection, so the extension is safe to
///      adopt in any Governor.
///
///      Observation is complete because tallies only change inside `_castVote`: a failing
///      state created by a vote is seen post-count (`_tallyUpdated`), one inherited from
///      before the window is seen by the first in-window cast's pre-count check, and a
///      window with no votes cannot contain a flip at all.
///
///      Integration requirement: every proposal's voting period must exceed
///      `extensionWindow`, otherwise the "final window" spans the whole vote — every vote
///      is a "late" vote and, since proposals start failing (empty tally), any proposal
///      that ends up passing would get the extension. This contract cannot enforce that
///      generically (periods are the inheritor's concern); validate it wherever voting
///      periods are configured.
abstract contract GovernorPreventLateFlip is Governor {
    /// @notice Final-window length of the late-flip trigger, in clock units.
    uint48 public immutable extensionWindow;
    /// @notice Length added past the ORIGINAL deadline when the extension fires, in clock
    ///         units.
    uint48 public immutable extensionDuration;

    /// @dev Both bits are protection-monotone — they only ever move toward granting the
    ///      extension, so there is nothing a re-vote sequence can burn. One slot, written
    ///      at most twice per proposal.
    struct LateFlipExtension {
        bool sawFailingInWindow;
        bool extended;
    }

    mapping(uint256 proposalId => LateFlipExtension) private _lateFlip;

    /// @notice A proposal's voting period was extended by a late failing→passing flip.
    /// @dev Same ABI as OZ `GovernorPreventLateQuorum`'s event, so stock tooling decodes it.
    event ProposalExtended(uint256 indexed proposalId, uint64 extendedDeadline);

    /// @notice A late-flip extension parameter is zero.
    error InvalidExtensionConfig();

    /// @param extensionWindow_ Final-window length of the trigger, in clock units; non-zero.
    /// @param extensionDuration_ Extension length past the original deadline, in clock
    ///        units; non-zero.
    constructor(uint48 extensionWindow_, uint48 extensionDuration_) {
        if (extensionWindow_ == 0 || extensionDuration_ == 0) revert InvalidExtensionConfig();
        extensionWindow = extensionWindow_;
        extensionDuration = extensionDuration_;
    }

    /// @dev "Would the proposal pass if voting closed now" — the exact conjunction
    ///      `state()`'s post-deadline branch evaluates.
    function _wouldPass(uint256 proposalId) private view returns (bool) {
        return _quorumReached(proposalId) && _voteSucceeded(proposalId);
    }

    /// @dev The single observation point, run pre-count (from `_castVote`, seeing the tally
    ///      a vote is about to change) and post-count (from `_tallyUpdated`, seeing what it
    ///      changed). In the window: record a failing observation. After the original
    ///      deadline: materialize the (already-determined) extension on the first cast —
    ///      freezing the decision BEFORE this vote mutates the tally, which is sound
    ///      because the tally cannot have changed between the deadline and now (any earlier
    ///      post-deadline cast would have materialized first). Never reverts (`_tallyUpdated`
    ///      hard rule); a cast that reaches this while the proposal is not Active is undone
    ///      wholesale when `super._castVote` reverts, so `extended` only ever commits as
    ///      true. The in-window bound is computed additively so a nonexistent id
    ///      (deadline 0) cannot underflow — it falls through untouched to stock existence
    ///      reverts.
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

    /// @dev Pre-count observation: sees the tally state this vote is about to change,
    ///      catching a failing state inherited from before the window and materializing a
    ///      pending extension before the tally mutates. Internal, so every cast path is
    ///      covered — including the `bySig` variants, which public `castVote*` overrides
    ///      in inheritors do not intercept.
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

    /// @inheritdoc Governor
    /// @dev Extended lazily past the original deadline (never before it — a mid-window flip
    ///      can still revert, so nothing is promised early). After the original deadline
    ///      the answer comes from the materialized bit or, until the first extension-period
    ///      cast materializes it, from a live read — sound because the tally is frozen from
    ///      the deadline until that first cast (so views stay authoritative even if nobody
    ///      ever votes in the extension and `ProposalExtended` never fires). `state()`
    ///      needs no override: Active-through-the-extension and the final verdict both
    ///      follow from this view.
    function proposalDeadline(uint256 proposalId) public view virtual override returns (uint256) {
        uint256 originalDeadline = super.proposalDeadline(proposalId);
        if (clock() <= originalDeadline) return originalDeadline;

        LateFlipExtension storage lateFlip = _lateFlip[proposalId];
        if (lateFlip.extended || (lateFlip.sawFailingInWindow && _wouldPass(proposalId))) {
            return originalDeadline + extensionDuration;
        }
        return originalDeadline;
    }
}
