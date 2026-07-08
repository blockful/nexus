// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IRuleset} from "../interfaces/IRuleset.sol";

/// @title BaseRuleset
/// @notice Shared ruleset plumbing: governor-only access control, mutable-vote counting
///         over generic support buckets, and per-voter receipts. Vote mutability (RFC):
///         a re-vote removes the voter's previous weight from its bucket before adding
///         the new one, so the latest vote is the only one counted.
///
///         Parameter setters on concrete rulesets are Ownable; the owner is expected to
///         be the DAO's timelock so changes go through governance.
abstract contract BaseRuleset is IRuleset, Ownable {
    struct VoteReceipt {
        bool hasVoted;
        uint8 support;
        uint240 weight;
    }

    address public immutable governor;

    uint256 private _votingPeriod;

    // Tallies keyed by support value, so rulesets can define extra vote options
    // (e.g. Bond's No+Slash) without changing the storage layout.
    mapping(uint256 proposalId => mapping(uint8 support => uint256 weight)) internal _tallies;
    mapping(uint256 proposalId => mapping(address voter => VoteReceipt)) internal _receipts;

    event VotingPeriodSet(uint256 votingPeriod);

    error OnlyGovernor(address caller);
    error InvalidSupport(uint8 support);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor(msg.sender);
        _;
    }

    constructor(address governor_, address owner_, uint256 votingPeriod_) Ownable(owner_) {
        governor = governor_;
        _setVotingPeriod(votingPeriod_);
    }

    /// @inheritdoc IRuleset
    /// @dev Default: no extra eligibility or setup. Override for bonds/allowlists.
    function onPropose(uint256, address, address[] calldata, uint256[] calldata, bytes[] calldata, bytes32)
        external
        virtual
        onlyGovernor
    {}

    /// @inheritdoc IRuleset
    function countVote(uint256 proposalId, address account, uint8 support, uint256 totalWeight, bytes calldata)
        external
        virtual
        onlyGovernor
        returns (uint256)
    {
        if (!_isValidSupport(support)) revert InvalidSupport(support);

        VoteReceipt storage receipt = _receipts[proposalId][account];
        if (receipt.hasVoted) {
            _tallies[proposalId][receipt.support] -= receipt.weight;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.weight = SafeCast.toUint240(totalWeight);
        _tallies[proposalId][support] += totalWeight;

        return totalWeight;
    }

    /// @inheritdoc IRuleset
    function hasVoted(uint256 proposalId, address account) external view virtual returns (bool) {
        return _receipts[proposalId][account].hasVoted;
    }

    /// @notice The currently-counted vote of `account` on `proposalId`.
    function voteReceipt(uint256 proposalId, address account) external view returns (VoteReceipt memory) {
        return _receipts[proposalId][account];
    }

    /// @notice Total weight currently in a support bucket.
    function tally(uint256 proposalId, uint8 support) external view returns (uint256) {
        return _tallies[proposalId][support];
    }

    /// @inheritdoc IRuleset
    function votingPeriod() external view virtual returns (uint256) {
        return _votingPeriod;
    }

    function setVotingPeriod(uint256 votingPeriod_) external onlyOwner {
        _setVotingPeriod(votingPeriod_);
    }

    function _setVotingPeriod(uint256 votingPeriod_) internal {
        _votingPeriod = votingPeriod_;
        emit VotingPeriodSet(votingPeriod_);
    }

    /// @dev Which support values this ruleset accepts.
    function _isValidSupport(uint8 support) internal view virtual returns (bool);
}
