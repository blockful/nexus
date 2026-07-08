// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {IBondRulesetVector, IRulesetErrors} from "./ISystemUnderTest.sol";
import {VectorsFixture} from "./VectorsFixture.sol";

/// @dev Bond ruleset vectors — port of the draft repo's BondRuleset.t.sol (12 tests),
///      verbatim except for interface-typed handles.
abstract contract BondRulesetVectors is VectorsFixture {
    function setUp() public virtual override {
        super.setUp();
        // dave has tokens but no delegated voting power: below threshold, can still
        // propose by locking a bond (RFC §2.4)
        token.mint(dave, BOND_AMOUNT);
        vm.prank(dave);
        token.approve(address(bondRuleset), type(uint256).max);
        vm.roll(block.number + 1);
    }

    function _proposeBond(address proposer, uint256 newValue, string memory description)
        internal
        returns (uint256 proposalId)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) =
            _boxProposal(newValue, description);
        vm.prank(proposer);
        proposalId = governor.proposeWithType(targets, values, calldatas, description, TYPE_BOND);
    }

    function test_proposeWithBond_belowThreshold() public {
        assertEq(governor.getVotes(dave, block.number - 1), 0);

        uint256 balanceBefore = token.balanceOf(dave);
        uint256 proposalId = _proposeBond(dave, 9, "bonded proposal");

        assertEq(token.balanceOf(dave), balanceBefore - BOND_AMOUNT);
        assertEq(token.balanceOf(address(bondRuleset)), BOND_AMOUNT);
        (address bondProposer, uint96 amount, bool resolved) = bondRuleset.bonds(proposalId);
        assertEq(bondProposer, dave);
        assertEq(amount, BOND_AMOUNT);
        assertFalse(resolved);
    }

    function test_proposeWithoutApproval_reverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(9, "no approval");
        vm.prank(carol); // never approved the ruleset
        vm.expectRevert();
        governor.proposeWithType(targets, values, calldatas, "no approval", TYPE_BOND);
    }

    function test_successfulProposal_executesAndRefundsBond() public {
        uint256 proposalId = _proposeBond(dave, 9, "good idea");
        _rollToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 1); // 200e18 For >= quorum

        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        _queueAndExecute(9, "good idea");
        assertEq(box.value(), 9);

        uint256 balanceBefore = token.balanceOf(dave);
        bondRuleset.resolveBond(proposalId);
        assertEq(token.balanceOf(dave), balanceBefore + BOND_AMOUNT);
    }

    function test_succeededButNeverExecuted_bondNotLocked() public {
        uint256 proposalId = _proposeBond(dave, 9, "succeeded, never queued");
        _rollToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // outcome is final (a Succeeded proposal can never be slashed): refund now
        bondRuleset.resolveBond(proposalId);
        assertEq(token.balanceOf(dave), BOND_AMOUNT);
    }

    function test_defeatedWithSlashPlurality_slashesBondToTreasury() public {
        uint256 proposalId = _proposeBond(dave, 9, "spam proposal");
        _rollToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 3); // No + Slash: 200e18
        vm.prank(carol);
        governor.castVote(proposalId, 0); // plain No: 50e18

        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));

        uint256 treasuryBefore = token.balanceOf(address(timelock));
        bondRuleset.resolveBond(proposalId);
        assertEq(token.balanceOf(address(timelock)), treasuryBefore + BOND_AMOUNT);
        assertEq(token.balanceOf(dave), 0);
    }

    function test_defeatedWithoutSlashPlurality_refundsBond() public {
        uint256 proposalId = _proposeBond(dave, 9, "honest but defeated");
        _rollToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 0); // plain No: 200e18
        vm.prank(carol);
        governor.castVote(proposalId, 3); // No + Slash: 50e18 (minority of opposition)

        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));

        bondRuleset.resolveBond(proposalId);
        assertEq(token.balanceOf(dave), BOND_AMOUNT);
    }

    function test_slashVotesCountTowardOpposition() public {
        uint256 proposalId = _proposeBond(dave, 9, "slash counts");
        _rollToActive(proposalId);

        vm.prank(bob);
        governor.castVote(proposalId, 1); // 100e18 For (meets quorum)
        vm.prank(alice);
        governor.castVote(proposalId, 3); // 200e18 No+Slash

        _rollPastDeadline(proposalId);
        // For (100) < No (0) + No+Slash (200): defeated
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_selfCancel_refundsBond() public {
        uint256 proposalId = _proposeBond(dave, 9, "changed my mind");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(9, "changed my mind");
        vm.prank(dave);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        bondRuleset.resolveBond(proposalId);
        assertEq(token.balanceOf(dave), BOND_AMOUNT);
    }

    function test_resolveBond_revertsWhileVoting() public {
        uint256 proposalId = _proposeBond(dave, 9, "too early");
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondRulesetVector.ProposalNotTerminal.selector, proposalId, IGovernor.ProposalState.Pending
            )
        );
        bondRuleset.resolveBond(proposalId);
    }

    function test_resolveBond_revertsOnDoubleResolve() public {
        uint256 proposalId = _proposeBond(dave, 9, "double resolve");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(9, "double resolve");
        vm.prank(dave);
        governor.cancel(targets, values, calldatas, descriptionHash);

        bondRuleset.resolveBond(proposalId);
        vm.expectRevert(abi.encodeWithSelector(IBondRulesetVector.BondAlreadyResolved.selector, proposalId));
        bondRuleset.resolveBond(proposalId);
    }

    function test_invalidSupportValue_reverts() public {
        uint256 proposalId = _proposeBond(dave, 9, "bad support");
        _rollToActive(proposalId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRulesetErrors.InvalidSupport.selector, 4));
        governor.castVote(proposalId, 4);
    }

    function test_slashOptionRejected_onStandardProposals() public {
        uint256 proposalId = _proposeStandard(alice, 1, "standard no slash");
        _rollToActive(proposalId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRulesetErrors.InvalidSupport.selector, 3));
        governor.castVote(proposalId, 3);
    }
}
