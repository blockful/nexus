// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {IRuleset} from "../../src/IRuleset.sol";

/// @title Malicious / broken ruleset mocks for the adversarial suite
/// @notice Each concrete ruleset below embodies exactly ONE attack or failure mode against a
///         GovernorNexus core, so `GovernorNexus.adversarial.t.sol` can pin the blast radius
///         the core guarantees: a bad ruleset breaks voting on ITS OWN proposals only.
/// @dev All variants advertise `IRuleset` via ERC165 so they pass registration — the trust
///      boundary is procedural (rulesets are DAO-vote-gated code), not a runtime
///      interface check, so a malicious ruleset that implements the interface WILL register.

/// @dev Shared plumbing: ERC165 advertisement + the inert view surface (`quorum`,
///      `COUNTING_MODE`, `supportsInterface`) that no attack here exercises. Kept `pure` so it
///      raises zero mutability warnings; the counting/outcome hooks each mock actually attacks
///      with are declared by `IRuleset` and implemented in the concrete contracts below.
abstract contract AdversarialRulesetBase is IRuleset {
    /// @dev The governor this ruleset trusts as the sole `countVote` caller / reentrancy target.
    address public immutable governor;

    constructor(address governor_) {
        governor = governor_;
    }

    /// @inheritdoc IRuleset
    function quorum(uint256) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IRuleset
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo&quorum=for";
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Honest tally shared by the mocks whose attack is NOT in the counting logic itself
///      (weight inflation, reentrancy) — so they differ from a well-behaved ruleset by exactly
///      their one attack and nothing else. One-vote-per-voter, For/Against buckets; quorum is
///      met once any For weight lands, success is For > Against.
abstract contract TallyingRulesetBase is AdversarialRulesetBase {
    mapping(uint256 => uint256) internal _forVotes;
    mapping(uint256 => uint256) internal _againstVotes;
    mapping(uint256 => mapping(address => bool)) internal _voted;

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor(address governor_) AdversarialRulesetBase(governor_) {}

    function _tally(uint256 proposalId, address voter, uint8 support, uint256 weight) internal {
        require(!_voted[proposalId][voter], "already voted");
        _voted[proposalId][voter] = true;
        if (support == 1) {
            _forVotes[proposalId] += weight;
        } else {
            _againstVotes[proposalId] += weight;
        }
    }

    /// @inheritdoc IRuleset
    function quorumReached(uint256 proposalId) external view returns (bool) {
        return _forVotes[proposalId] > 0;
    }

    /// @inheritdoc IRuleset
    function voteSucceeded(uint256 proposalId) external view returns (bool) {
        return _forVotes[proposalId] > _againstVotes[proposalId];
    }

    /// @inheritdoc IRuleset
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _voted[proposalId][voter];
    }
}

/// @notice Attack: `countVote` always reverts.
/// @dev Blocks voting on its OWN proposals. `quorumReached`/`voteSucceeded` stay honest-false
///      so `state()` (which consults them only after the deadline) still resolves — to
///      Defeated — rather than reverting: the outage is confined to casting votes.
contract RevertingRuleset is AdversarialRulesetBase {
    error CountVoteDisabled();

    constructor(address governor_) AdversarialRulesetBase(governor_) {}

    /// @inheritdoc IRuleset
    function countVote(uint256, address, uint8, uint256, bytes calldata) external pure returns (uint256) {
        revert CountVoteDisabled();
    }

    /// @inheritdoc IRuleset
    function quorumReached(uint256) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IRuleset
    function voteSucceeded(uint256) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IRuleset
    function hasVoted(uint256, address) external pure returns (bool) {
        return false;
    }
}

/// @notice Attack: outcome views always return `true`, recording nothing.
/// @dev Makes its proposal Succeed after the deadline with ZERO votes cast. This is the
///      accepted-risk consequence of the trust model (rulesets are trusted DAO-approved
///      code); the suite documents the blast radius, it is not a core bug.
contract LyingRuleset is AdversarialRulesetBase {
    constructor(address governor_) AdversarialRulesetBase(governor_) {}

    /// @inheritdoc IRuleset
    function countVote(uint256, address, uint8, uint256 weight, bytes calldata) external pure returns (uint256) {
        return weight; // accepts silently, tallies nothing
    }

    /// @inheritdoc IRuleset
    function quorumReached(uint256) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IRuleset
    function voteSucceeded(uint256) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IRuleset
    function hasVoted(uint256, address) external pure returns (bool) {
        return false;
    }
}

/// @notice Attack: the outcome views (`quorumReached`/`voteSucceeded`) revert.
/// @dev `state()` calls these only in the deadline-passed branch, so voting stays open and
///      queryable up to the deadline, then `state()` reverts, making queue/execute impossible
///      for that proposal only. `GovernorPreventLateFlip` also reads these views on every cast
///      inside the final `extensionWindow`, so `castVote` itself reverts for that slice of the
///      voting period too — the poison surfaces earlier than the deadline, not only after it.
contract RevertingViewsRuleset is AdversarialRulesetBase {
    error ViewPoisoned();

    constructor(address governor_) AdversarialRulesetBase(governor_) {}

    /// @inheritdoc IRuleset
    function countVote(uint256, address, uint8, uint256 weight, bytes calldata) external pure returns (uint256) {
        return weight;
    }

    /// @inheritdoc IRuleset
    function quorumReached(uint256) external pure returns (bool) {
        revert ViewPoisoned();
    }

    /// @inheritdoc IRuleset
    function voteSucceeded(uint256) external pure returns (bool) {
        revert ViewPoisoned();
    }

    /// @inheritdoc IRuleset
    function hasVoted(uint256, address) external pure returns (bool) {
        return false;
    }
}

/// @notice Attack: `countVote` returns weight * 1000 (more than it was passed / tallied).
/// @dev The honest tally still stores the REAL weight; only the RETURN value is inflated. That
///      return feeds nothing but the `VoteCast` event's weight field and `castVote`'s return —
///      it can touch neither checkpointed voting power nor other rulesets' quorum math.
contract WeightInflatingRuleset is TallyingRulesetBase {
    uint256 public constant INFLATION = 1000;

    constructor(address governor_) TallyingRulesetBase(governor_) {}

    /// @inheritdoc IRuleset
    function countVote(uint256 proposalId, address voter, uint8 support, uint256 weight, bytes calldata)
        external
        onlyGovernor
        returns (uint256)
    {
        _tally(proposalId, voter, support, weight); // honest internal accounting
        return weight * INFLATION; // the attack: report more than was counted
    }
}

/// @notice Attack: `countVote` re-enters the governor from inside the counting hook.
/// @dev Two reentry targets, one per test, to pin that neither corrupts a core invariant:
///      - `CallGovernance`: attempts an `onlyGovernance` setter — must be rejected with
///        `GovernorOnlyExecutor` (msg.sender is this ruleset, not the timelock executor).
///      - `Propose`: opens a fresh proposal mid-tally on `proposeType` (a zero-threshold type
///        this ruleset can propose on) — must succeed as an ordinary proposal without
///        disturbing the outer `castVote`'s already-frozen weight/accounting.
///      Reentry is attempted once (guarded by `attempted`) so recursion terminates; the outer
///      vote is then tallied honestly.
contract ReentrantRuleset is TallyingRulesetBase {
    enum Reentry {
        CallGovernance,
        Propose
    }

    Reentry public immutable reentry;
    /// @dev Zero-threshold type the `Propose` reentry targets (unused for `CallGovernance`).
    uint8 public immutable proposeType;

    bool public attempted;
    /// @dev Raw revert data captured from the `CallGovernance` reentry attempt (empty if none).
    bytes public governanceReentryRevert;
    /// @dev Proposal id minted by the `Propose` reentry (0 if none).
    uint256 public reentrantProposalId;

    constructor(address governor_, Reentry reentry_, uint8 proposeType_) TallyingRulesetBase(governor_) {
        reentry = reentry_;
        proposeType = proposeType_;
    }

    /// @inheritdoc IRuleset
    function countVote(uint256 proposalId, address voter, uint8 support, uint256 weight, bytes calldata)
        external
        onlyGovernor
        returns (uint256)
    {
        if (!attempted) {
            attempted = true;
            if (reentry == Reentry.CallGovernance) {
                // Try to flip an onlyGovernance switch from inside the hook; capture the revert.
                try GovernorNexus(payable(governor)).setTypeActive(0, false) {}
                catch (bytes memory reason) {
                    governanceReentryRevert = reason;
                }
            } else {
                // Open a fresh proposal mid-tally on a type this (zero-vote) ruleset can use.
                address[] memory targets = new address[](1);
                targets[0] = address(this);
                uint256[] memory values = new uint256[](1);
                bytes[] memory calldatas = new bytes[](1);
                calldatas[0] = "";
                reentrantProposalId = GovernorNexus(payable(governor))
                    .proposeWithType(targets, values, calldatas, "reentrant proposal", proposeType);
            }
        }

        _tally(proposalId, voter, support, weight);
        return weight;
    }
}
