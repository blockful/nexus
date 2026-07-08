// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseRuleset} from "./BaseRuleset.sol";

/// @title StandardRuleset
/// @notice Default ENS proposal path (RFC type table): simple majority (For > Against),
///         absolute quorum counted over For + Abstain (1M ENS proposed), proposer must
///         hold — and keep — the governor's proposal threshold.
contract StandardRuleset is BaseRuleset {
    uint8 internal constant SUPPORT_AGAINST = 0;
    uint8 internal constant SUPPORT_FOR = 1;
    uint8 internal constant SUPPORT_ABSTAIN = 2;

    uint256 private _quorum;

    event QuorumSet(uint256 quorum);

    constructor(address governor_, address owner_, uint256 votingPeriod_, uint256 quorum_)
        BaseRuleset(governor_, owner_, votingPeriod_)
    {
        _setQuorum(quorum_);
    }

    function quorum(uint256) public view virtual returns (uint256) {
        return _quorum;
    }

    function quorumReached(uint256 proposalId) public view virtual returns (bool) {
        return _tallies[proposalId][SUPPORT_FOR] + _tallies[proposalId][SUPPORT_ABSTAIN] >= _quorum;
    }

    function voteSucceeded(uint256 proposalId) public view virtual returns (bool) {
        return _tallies[proposalId][SUPPORT_FOR] > _tallies[proposalId][SUPPORT_AGAINST];
    }

    function requiresProposerThreshold() public view virtual returns (bool) {
        return true;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public view virtual returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    function setQuorum(uint256 quorum_) external onlyOwner {
        _setQuorum(quorum_);
    }

    function _setQuorum(uint256 quorum_) internal {
        _quorum = quorum_;
        emit QuorumSet(quorum_);
    }

    function _isValidSupport(uint8 support) internal view virtual override returns (bool) {
        return support <= SUPPORT_ABSTAIN;
    }
}
