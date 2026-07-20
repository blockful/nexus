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
/// @dev Hardened for mutable (non-monotonic) tallies: the trigger is a window low-water
///      mark, and a proposal's {LateFlipStage} only moves toward GRANTING the extension.
///      Integration requirement: every proposal's voting period must exceed
///      `extensionWindow` — this contract cannot enforce that generically; validate it
///      wherever voting periods are configured.
abstract contract GovernorPreventLateFlip is Governor {
    /// @notice Final-window length of the late-flip trigger, in clock units.
    uint48 public immutable extensionWindow;
    /// @notice Length added past the ORIGINAL deadline when the extension fires, in clock
    ///         units.
    uint48 public immutable extensionDuration;

    /// @dev Monotone ladder: a proposal's stage only ever moves forward, so no vote
    ///      sequence can consume the protection. `Extended` is reachable only through
    ///      `FailingObserved` — "extended without a failing witness" is unrepresentable.
    enum LateFlipStage {
        None,
        FailingObserved,
        Extended
    }

    mapping(uint256 proposalId => LateFlipStage) private _lateFlipStage;

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

    /// @dev The single observation point, run pre-count (from `_castVote`) and post-count
    ///      (from `_tallyUpdated`). Must never revert on its own arithmetic (`_tallyUpdated`
    ///      hard rule); the in-window bound is computed additively so a nonexistent id
    ///      (deadline 0) cannot underflow. It does NOT defend against `_quorumReached`/
    ///      `_voteSucceeded` themselves reverting — if the governor's implementation of those
    ///      hooks can revert (e.g. dispatch to pluggable external code), a cast landing inside
    ///      the final window reverts too, not just post-deadline queries.
    function _observeLateFlip(uint256 proposalId) private {
        uint256 originalDeadline = super.proposalDeadline(proposalId);
        uint256 current = clock();
        bool votingOpen = current <= originalDeadline;

        if (votingOpen) {
            bool inFinalWindow = current + extensionWindow >= originalDeadline;
            if (inFinalWindow && _lateFlipStage[proposalId] == LateFlipStage.None && !_wouldPass(proposalId)) {
                _lateFlipStage[proposalId] = LateFlipStage.FailingObserved;
            }
        } else if (_lateFlipStage[proposalId] == LateFlipStage.FailingObserved && _wouldPass(proposalId)) {
            _lateFlipStage[proposalId] = LateFlipStage.Extended;
            // originalDeadline + extensionDuration ≪ 2^64 (both derive from uint48 domains).
            // forge-lint: disable-next-line(unsafe-typecast)
            emit ProposalExtended(proposalId, uint64(originalDeadline + extensionDuration));
        }
    }

    /// @dev Pre-count observation. Internal, so every cast path is covered — including the
    ///      `bySig` variants, which public `castVote*` overrides in inheritors do not
    ///      intercept.
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
    /// @dev Extended lazily past the original deadline: the answer comes from the
    ///      materialized stage or, until the first extension-period cast sets it, a live read.
    function proposalDeadline(uint256 proposalId) public view virtual override returns (uint256) {
        uint256 originalDeadline = super.proposalDeadline(proposalId);
        if (clock() <= originalDeadline) return originalDeadline;

        LateFlipStage stage = _lateFlipStage[proposalId];
        if (stage == LateFlipStage.Extended || (stage == LateFlipStage.FailingObserved && _wouldPass(proposalId))) {
            return originalDeadline + extensionDuration;
        }
        return originalDeadline;
    }
}
