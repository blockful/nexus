// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {BaseRuleset} from "./BaseRuleset.sol";

/// @title BondRuleset
/// @notice Lock-to-propose path (RFC §2.4): anyone may propose without meeting the
///         proposal threshold by staking an ENS bond. Approval follows the standard
///         rules (simple majority, 1M quorum), with an extra vote option:
///         0 = No, 1 = Yes, 2 = Abstain, 3 = No + Slash.
///         No + Slash counts toward opposition AND signals the bond should be slashed.
///
///         v1 slash rule (heuristic, to be finalized in the spec): the bond is slashed
///         iff the proposal is Defeated and No+Slash weight exceeds plain No weight —
///         i.e. the opposition's plurality deemed the proposal unnecessary. Slashed
///         bonds go to the treasury (timelock). All other terminal states refund.
contract BondRuleset is BaseRuleset {
    using SafeERC20 for IERC20;

    uint8 internal constant SUPPORT_AGAINST = 0;
    uint8 internal constant SUPPORT_FOR = 1;
    uint8 internal constant SUPPORT_ABSTAIN = 2;
    uint8 internal constant SUPPORT_AGAINST_AND_SLASH = 3;

    struct Bond {
        address proposer;
        uint96 amount;
        bool resolved;
    }

    IERC20 public immutable token;
    address public treasury;

    uint256 private _bondAmount;
    uint256 private _quorum;

    mapping(uint256 proposalId => Bond) public bonds;

    event BondLocked(uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondRefunded(uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondSlashed(uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event BondAmountSet(uint256 bondAmount);
    event QuorumSet(uint256 quorum);
    event TreasurySet(address treasury);

    error BondAlreadyResolved(uint256 proposalId);
    error NoBond(uint256 proposalId);
    error ProposalNotTerminal(uint256 proposalId, IGovernor.ProposalState state);

    constructor(
        address governor_,
        address owner_,
        uint256 votingPeriod_,
        uint256 quorum_,
        IERC20 token_,
        uint256 bondAmount_,
        address treasury_
    ) BaseRuleset(governor_, owner_, votingPeriod_) {
        token = token_;
        _setQuorum(quorum_);
        _setBondAmount(bondAmount_);
        _setTreasury(treasury_);
    }

    /// @inheritdoc BaseRuleset
    /// @dev Pulls the bond from the proposer; requires prior ERC20 approval to this
    ///      ruleset. The bond amount is snapshotted per proposal.
    function onPropose(uint256 proposalId, address proposer, address[] calldata, uint256[] calldata, bytes[] calldata, bytes32)
        external
        virtual
        override
        onlyGovernor
    {
        uint256 amount = _bondAmount;
        // safe: _setBondAmount enforces bondAmount <= type(uint96).max
        // forge-lint: disable-next-line(unsafe-typecast)
        bonds[proposalId] = Bond({proposer: proposer, amount: uint96(amount), resolved: false});
        token.safeTransferFrom(proposer, address(this), amount);
        emit BondLocked(proposalId, proposer, amount);
    }

    /// @notice Settles the bond once the vote outcome is final. Permissionless.
    ///         Defeated + slash plurality → bond to treasury; everything else → refund.
    ///         Succeeded/Queued proposals can never be slashed (slashing requires
    ///         Defeated), so their bonds refund immediately — a succeeded-but-never-
    ///         executed proposal must not lock the bond forever.
    function resolveBond(uint256 proposalId) external {
        Bond storage bond = bonds[proposalId];
        if (bond.proposer == address(0)) revert NoBond(proposalId);
        if (bond.resolved) revert BondAlreadyResolved(proposalId);

        IGovernor.ProposalState state = IGovernor(governor).state(proposalId);
        if (state == IGovernor.ProposalState.Pending || state == IGovernor.ProposalState.Active) {
            revert ProposalNotTerminal(proposalId, state);
        }

        bond.resolved = true;
        uint256 amount = bond.amount;

        bool slashed = state == IGovernor.ProposalState.Defeated
            && _tallies[proposalId][SUPPORT_AGAINST_AND_SLASH] > _tallies[proposalId][SUPPORT_AGAINST];

        if (slashed) {
            token.safeTransfer(treasury, amount);
            emit BondSlashed(proposalId, bond.proposer, amount);
        } else {
            token.safeTransfer(bond.proposer, amount);
            emit BondRefunded(proposalId, bond.proposer, amount);
        }
    }

    function quorum(uint256) public view virtual returns (uint256) {
        return _quorum;
    }

    function quorumReached(uint256 proposalId) public view virtual returns (bool) {
        return _tallies[proposalId][SUPPORT_FOR] + _tallies[proposalId][SUPPORT_ABSTAIN] >= _quorum;
    }

    /// @dev Simple majority; No + Slash counts as opposition.
    function voteSucceeded(uint256 proposalId) public view virtual returns (bool) {
        return _tallies[proposalId][SUPPORT_FOR]
            > _tallies[proposalId][SUPPORT_AGAINST] + _tallies[proposalId][SUPPORT_AGAINST_AND_SLASH];
    }

    function requiresProposerThreshold() public view virtual returns (bool) {
        return false;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public view virtual returns (string memory) {
        return "support=bravo,slash&quorum=for,abstain";
    }

    function bondAmount() public view returns (uint256) {
        return _bondAmount;
    }

    function setBondAmount(uint256 bondAmount_) external onlyOwner {
        _setBondAmount(bondAmount_);
    }

    function setQuorum(uint256 quorum_) external onlyOwner {
        _setQuorum(quorum_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        _setTreasury(treasury_);
    }

    function _setBondAmount(uint256 bondAmount_) internal {
        require(bondAmount_ <= type(uint96).max, "bond too large");
        _bondAmount = bondAmount_;
        emit BondAmountSet(bondAmount_);
    }

    function _setQuorum(uint256 quorum_) internal {
        _quorum = quorum_;
        emit QuorumSet(quorum_);
    }

    function _setTreasury(address treasury_) internal {
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function _isValidSupport(uint8 support) internal view virtual override returns (bool) {
        return support <= SUPPORT_AGAINST_AND_SLASH;
    }
}
