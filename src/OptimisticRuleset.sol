// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IProposalValidator} from "./IProposalValidator.sol";
import {IRuleset} from "./IRuleset.sol";
import {RulesetCounting} from "./RulesetCounting.sol";

/// @title OptimisticRuleset
/// @notice Pass-by-default ruleset: no quorum, and a proposal succeeds unless the Against
///         bucket holds `vetoThreshold` at the deadline — a proposal with zero votes cast
///         executes. Safety moves to propose time (`validateProposal`): only allowlisted
///         proposers, only allowlisted `(target, selector)` actions, no ETH value. Deploys
///         with empty allowlists; the setters answer only to `admin`, the governance
///         executor.
/// @dev Counting mechanics (buckets, receipts, replace-on-re-vote) come from
///      `RulesetCounting`, so a veto is withdrawable: a vetoer re-voting For/Abstain
///      drains the Against bucket and `voteSucceeded` flips back — non-monotonic in both
///      directions while voting is open. Threshold and validation logic are immutable;
///      the allowlist entries are the one mutable surface.
contract OptimisticRuleset is RulesetCounting, IProposalValidator {
    /// @dev Bravo-style bucket ordering: 0=Against, 1=For, 2=Abstain. Only Against is
    ///      outcome-bearing; For/Abstain are accepted for signal and veto withdrawal.
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /// @notice Governance executor that owns the allowlist setters. Must be the address
    ///         governance executions come from (the timelock), NOT the governor —
    ///         restricting to the governor would make the setters unreachable.
    address public immutable admin;

    /// @notice Absolute Against weight at which a proposal is defeated.
    uint256 public immutable vetoThreshold;

    /// @notice Accounts allowed to open proposals under this ruleset's type.
    mapping(address proposer => bool) public allowedProposers;

    /// @notice `(target, selector)` pairs a proposal under this ruleset's type may call.
    mapping(address target => mapping(bytes4 selector => bool)) public allowedActions;

    /// @notice A proposer allowlist entry was written.
    event ProposerAllowedSet(address indexed proposer, bool allowed);
    /// @notice An action allowlist entry was written.
    event ActionAllowedSet(address indexed target, bytes4 indexed selector, bool allowed);

    /// @notice `admin` is the zero address, which would freeze the allowlists empty forever.
    error AdminZeroAddress();
    /// @notice `vetoThreshold` is zero, which would defeat every proposal unconditionally.
    error VetoThresholdZero();
    /// @notice The proposal's `targets`/`values`/`calldatas` lengths disagree.
    error LengthMismatch();
    /// @notice `proposer` is not on the proposer allowlist.
    error ProposerNotAllowed(address proposer);
    /// @notice The action at `index` carries ETH value, which this ruleset forbids.
    error ValueNotAllowed(uint256 index);
    /// @notice The action at `index` has fewer than 4 bytes of calldata — no selector to check.
    error SelectorMissing(uint256 index);
    /// @notice `(target, selector)` is not on the action allowlist.
    error ActionNotAllowed(address target, bytes4 selector);
    /// @notice `target` is part of the governance core and can never be allowlisted.
    error SelfTargetForbidden(address target);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized(msg.sender);
        _;
    }

    /// @param governor_ The GovernorNexus this ruleset is deployed for (counting and
    ///        validation caller).
    /// @param admin_ Governance executor owning the allowlist setters; non-zero.
    /// @param vetoThreshold_ Absolute Against weight that defeats a proposal; non-zero.
    constructor(address governor_, address admin_, uint256 vetoThreshold_) RulesetCounting(governor_) {
        if (admin_ == address(0)) revert AdminZeroAddress();
        if (vetoThreshold_ == 0) revert VetoThresholdZero();
        admin = admin_;
        vetoThreshold = vetoThreshold_;
    }

    // ─────────────────────────── Propose-time validation ───────────────────────────

    /// @inheritdoc IProposalValidator
    /// @dev Checks the three lengths itself, before any indexing — it must hold with no
    ///      assumption about what runs after it in the governor. Empty proposals pass
    ///      vacuously (nothing is indexed; the stock `_propose` rejects them downstream).
    ///      Restricted to the governor so third parties cannot probe with spoofed arguments.
    function validateProposal(
        address proposer,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32
    ) external view onlyGovernor {
        if (targets.length != values.length || values.length != calldatas.length) {
            revert LengthMismatch();
        }
        if (!allowedProposers[proposer]) revert ProposerNotAllowed(proposer);

        for (uint256 i = 0; i < targets.length; ++i) {
            if (values[i] != 0) revert ValueNotAllowed(i);
            if (calldatas[i].length < 4) revert SelectorMissing(i);
            bytes4 selector = bytes4(calldatas[i]);
            if (!allowedActions[targets[i]][selector]) revert ActionNotAllowed(targets[i], selector);
        }
    }

    // ─────────────────────────── Allowlist setters ───────────────────────────

    /// @notice Allow or disallow `proposer` to open proposals under this ruleset's type.
    function setProposerAllowed(address proposer, bool allowed) external onlyAdmin {
        allowedProposers[proposer] = allowed;
        emit ProposerAllowedSet(proposer, allowed);
    }

    /// @notice Allow or disallow proposals under this ruleset's type to call
    ///         `selector` on `target`.
    /// @dev Permanently refuses the governance core as a target — governor, timelock
    ///      (`admin`), and this ruleset — so a zero-vote proposal can never reconfigure
    ///      the system that created it. The refusal is unconditional on `allowed`: a
    ///      self-target entry can never exist, so there is nothing to disable.
    function setActionAllowed(address target, bytes4 selector, bool allowed) external onlyAdmin {
        if (target == governor || target == admin || target == address(this)) {
            revert SelfTargetForbidden(target);
        }
        allowedActions[target][selector] = allowed;
        emit ActionAllowedSet(target, selector, allowed);
    }

    // ─────────────────────────── Outcome rules ───────────────────────────

    /// @inheritdoc IRuleset
    /// @dev No participation requirement, so quorum is unconditionally met — including
    ///      for ids this ruleset never counted (the interface's no-revert contract).
    function quorumReached(uint256) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IRuleset
    /// @dev Succeeds while Against holds strictly less than `vetoThreshold`; For/Abstain
    ///      never bear on the outcome. Non-monotonic in BOTH directions under re-votes —
    ///      a veto is withdrawable — so consumers needing finality must read at the
    ///      deadline.
    function voteSucceeded(uint256 proposalId) external view returns (bool) {
        return tally(proposalId, uint8(VoteType.Against)) < vetoThreshold;
    }

    /// @notice Against/For/Abstain tallies for `proposalId` — same name and return order
    ///         as OZ `GovernorCountingSimple`'s `proposalVotes`.
    /// @dev An id this ruleset never counted returns all-zero, never reverts.
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

    /// @dev The three Bravo options — accepting For/Abstain is what makes the veto
    ///      withdrawable (a re-vote must have somewhere to move the weight).
    function _isValidSupport(uint8 support) internal pure override returns (bool) {
        return support <= uint8(VoteType.Abstain);
    }

    /// @inheritdoc IRuleset
    /// @dev Tooling view only, never outcome logic: no participation is required, so zero.
    function quorum(uint256) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IRuleset
    /// @dev All three buckets are tallied; only Against bears on the outcome (see
    ///      `voteSucceeded`).
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo&quorum=against,for,abstain";
    }

    /// @inheritdoc IERC165
    /// @dev Advertising `IProposalValidator` is what opts this ruleset into the governor's
    ///      propose-time validation gate (detected once, at type registration).
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IProposalValidator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
