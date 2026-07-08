// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {Box} from "../utils/TestUtils.sol";
import {IOptimisticRulesetVector} from "./ISystemUnderTest.sol";
import {VectorsFixture} from "./VectorsFixture.sol";

/// @dev Optimistic ruleset vectors — port of the draft repo's OptimisticRuleset.t.sol
///      (10 tests), verbatim except for interface-typed handles.
abstract contract OptimisticRulesetVectors is VectorsFixture {
    function setUp() public virtual override {
        super.setUp();
        // Conservative, explicitly enumerated eligibility (RFC §2.7):
        // dave (a working-group multisig stand-in, zero voting power) may call Box.setValue.
        vm.startPrank(address(timelock));
        optimisticRuleset.setAllowedProposer(dave, true);
        optimisticRuleset.setAllowedAction(address(box), Box.setValue.selector, true);
        vm.stopPrank();
    }

    function _proposeOptimistic(address proposer, uint256 newValue, string memory description)
        internal
        returns (uint256 proposalId)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) =
            _boxProposal(newValue, description);
        vm.prank(proposer);
        proposalId = governor.proposeWithType(targets, values, calldatas, description, TYPE_OPTIMISTIC);
    }

    function test_passesByDefault_withNoVotesAndNoQuorum() public {
        uint256 proposalId = _proposeOptimistic(dave, 7, "routine op");
        assertEq(governor.proposalDeadline(proposalId), governor.proposalSnapshot(proposalId) + OPTIMISTIC_PERIOD);

        _rollPastDeadline(proposalId); // nobody voted
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        _queueAndExecute(7, "routine op");
        assertEq(box.value(), 7);
    }

    function test_vetoAtThreshold_defeatsProposal() public {
        uint256 proposalId = _proposeOptimistic(dave, 7, "vetoed op");
        _rollToActive(proposalId);

        vm.prank(carol);
        governor.castVote(proposalId, 0); // 50e18 Against == veto threshold

        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_oppositionBelowThreshold_stillPasses() public {
        uint256 proposalId = _proposeOptimistic(dave, 7, "weak opposition");
        _rollToActive(proposalId);

        vm.prank(carol);
        governor.castVote(proposalId, 0);
        vm.prank(carol);
        governor.castVote(proposalId, 1); // mutable vote: carol reconsiders

        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_proposerWithoutThreshold_isEligible() public {
        // dave has zero voting power; optimistic path does not require the threshold
        uint256 proposalId = _proposeOptimistic(dave, 7, "no threshold needed");
        assertEq(governor.proposalType(proposalId), TYPE_OPTIMISTIC);
    }

    function test_nonAllowlistedProposer_reverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(7, "intruder");
        vm.prank(alice); // huge voting power but not allowlisted
        vm.expectRevert(abi.encodeWithSelector(IOptimisticRulesetVector.ProposerNotAllowed.selector, alice));
        governor.proposeWithType(targets, values, calldatas, "intruder", TYPE_OPTIMISTIC);
    }

    function test_nonAllowlistedAction_reverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(token); // token.transfer is not allowlisted
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", dave, 1e18);

        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptimisticRulesetVector.ActionNotAllowed.selector, address(token), bytes4(calldatas[0])
            )
        );
        governor.proposeWithType(targets, values, calldatas, "sneaky transfer", TYPE_OPTIMISTIC);
    }

    function test_nonzeroValue_reverts() public {
        (address[] memory targets,, bytes[] memory calldatas,) = _boxProposal(7, "with value");
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;

        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticRulesetVector.ValueNotAllowed.selector, address(box), 1 ether)
        );
        governor.proposeWithType(targets, values, calldatas, "with value", TYPE_OPTIMISTIC);
    }

    function test_shortCalldata_reverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(box);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"deadbe"; // < 4 bytes, no selector

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticRulesetVector.CalldataTooShort.selector, address(box)));
        governor.proposeWithType(targets, values, calldatas, "raw call", TYPE_OPTIMISTIC);
    }

    function test_strangerCannotCancel_optimisticProposal() public {
        // permissionless below-threshold cancel must NOT apply: this ruleset never
        // required the proposer threshold in the first place
        uint256 proposalId = _proposeOptimistic(dave, 7, "cancel probe");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(7, "cancel probe");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, bob));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    function test_allowlistManagement_onlyOwner() public {
        vm.prank(bob);
        vm.expectRevert();
        optimisticRuleset.setAllowedProposer(bob, true);

        vm.prank(bob);
        vm.expectRevert();
        optimisticRuleset.setAllowedAction(address(box), Box.setValue.selector, true);
    }
}
