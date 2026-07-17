// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IRuleset} from "../../src/IRuleset.sol";
import {RulesetCounting} from "../../src/RulesetCounting.sol";

/// @dev Optimistic-style test ruleset: passes by default, fails only once Against weight
///      reaches `vetoThreshold`; no quorum requirement. Exercises the late-flip extension's
///      type-agnosticism (spec D36) — under these inverted semantics a failing→passing flip
///      reads as "opposition crossed the veto threshold and then receded", and the core's
///      mechanism must fire on it with zero type-specific code.
contract MockOptimisticRuleset is RulesetCounting {
    enum VoteType {
        Against,
        For,
        Abstain
    }

    uint256 public immutable vetoThreshold;

    constructor(address governor_, uint256 vetoThreshold_) RulesetCounting(governor_) {
        vetoThreshold = vetoThreshold_;
    }

    /// @dev No quorum requirement — always met (RFC §2.7: "No quorum requirement").
    function quorumReached(uint256) external pure returns (bool) {
        return true;
    }

    /// @dev Pass unless opposition has reached the veto threshold. Non-monotonic under
    ///      re-votes in both directions, like every RulesetCounting descendant.
    function voteSucceeded(uint256 proposalId) external view returns (bool) {
        return _tally(proposalId, uint8(VoteType.Against)) < vetoThreshold;
    }

    function _isValidSupport(uint8 support) internal pure override returns (bool) {
        return support <= uint8(VoteType.Abstain);
    }

    function quorum(uint256) public pure returns (uint256) {
        return 0;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo&quorum=none";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
