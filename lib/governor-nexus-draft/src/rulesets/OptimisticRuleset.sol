// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseRuleset} from "./BaseRuleset.sol";

/// @title OptimisticRuleset
/// @notice Optimistic approval path for designated low-risk operational actions
///         (RFC §2.7): no quorum, proposals pass by default after the voting period
///         (15 days proposed) and fail only if opposition reaches the veto threshold
///         (500k ENS proposed). Eligibility is explicitly enumerated and conservative:
///         the proposer AND every (target, selector) action must be allowlisted, and
///         calls cannot carry ETH value.
contract OptimisticRuleset is BaseRuleset {
    uint8 internal constant SUPPORT_AGAINST = 0;
    uint8 internal constant SUPPORT_FOR = 1;
    uint8 internal constant SUPPORT_ABSTAIN = 2;

    uint256 private _vetoThreshold;
    mapping(address proposer => bool) public allowedProposer;
    mapping(address target => mapping(bytes4 selector => bool)) public allowedAction;

    event VetoThresholdSet(uint256 vetoThreshold);
    event ProposerAllowed(address indexed proposer, bool allowed);
    event ActionAllowed(address indexed target, bytes4 indexed selector, bool allowed);

    error ProposerNotAllowed(address proposer);
    error ActionNotAllowed(address target, bytes4 selector);
    error ValueNotAllowed(address target, uint256 value);
    error CalldataTooShort(address target);

    constructor(address governor_, address owner_, uint256 votingPeriod_, uint256 vetoThreshold_)
        BaseRuleset(governor_, owner_, votingPeriod_)
    {
        _setVetoThreshold(vetoThreshold_);
    }

    /// @inheritdoc BaseRuleset
    function onPropose(
        uint256,
        address proposer,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32
    ) external virtual override onlyGovernor {
        if (!allowedProposer[proposer]) revert ProposerNotAllowed(proposer);
        for (uint256 i = 0; i < targets.length; ++i) {
            if (values[i] != 0) revert ValueNotAllowed(targets[i], values[i]);
            if (calldatas[i].length < 4) revert CalldataTooShort(targets[i]);
            bytes4 selector = bytes4(calldatas[i][0:4]);
            if (!allowedAction[targets[i]][selector]) revert ActionNotAllowed(targets[i], selector);
        }
    }

    function quorum(uint256) public view virtual returns (uint256) {
        return 0;
    }

    function quorumReached(uint256) public view virtual returns (bool) {
        return true;
    }

    /// @dev Passes unless opposition reaches the veto threshold.
    function voteSucceeded(uint256 proposalId) public view virtual returns (bool) {
        return _tallies[proposalId][SUPPORT_AGAINST] < _vetoThreshold;
    }

    function requiresProposerThreshold() public view virtual returns (bool) {
        return false;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public view virtual returns (string memory) {
        return "support=bravo&quorum=optimistic";
    }

    function vetoThreshold() public view returns (uint256) {
        return _vetoThreshold;
    }

    function setVetoThreshold(uint256 vetoThreshold_) external onlyOwner {
        _setVetoThreshold(vetoThreshold_);
    }

    function setAllowedProposer(address proposer, bool allowed) external onlyOwner {
        allowedProposer[proposer] = allowed;
        emit ProposerAllowed(proposer, allowed);
    }

    function setAllowedAction(address target, bytes4 selector, bool allowed) external onlyOwner {
        allowedAction[target][selector] = allowed;
        emit ActionAllowed(target, selector, allowed);
    }

    function _setVetoThreshold(uint256 vetoThreshold_) internal {
        _vetoThreshold = vetoThreshold_;
        emit VetoThresholdSet(vetoThreshold_);
    }

    function _isValidSupport(uint8 support) internal view virtual override returns (bool) {
        return support <= SUPPORT_ABSTAIN;
    }
}
