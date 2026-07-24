// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {BondRuleset} from "../../src/rulesets/BondRuleset.sol";
import {IRuleset} from "../../src/interfaces/IRuleset.sol";
import {GovernorNexusTestBase} from "../governor/GovernorNexusTestBase.sol";

/// @dev Extends the shared fixture with a registered bond type (proposalThreshold = 0, making
///      proposing permissionless), a fund-but-no-VP proposer, and a council address holding the
///      timelock's CANCELLER_ROLE to simulate the security-council veto.
abstract contract BondRulesetTestBase is GovernorNexusTestBase {
    uint256 internal constant BOND_AMOUNT = 1_000e18;

    BondRuleset internal bondRuleset;
    uint8 internal bondTypeId;
    address internal bob = makeAddr("bob"); // bond proposer: tokens, no delegation → 0 VP
    address internal council = makeAddr("council");

    function setUp() public virtual override {
        super.setUp();

        bondRuleset = new BondRuleset(address(governor), IVotes(address(token)), 1, BOND_AMOUNT, address(timelock));
        _executeSelfCall(
            abi.encodeCall(
                GovernorNexus.registerType, (IRuleset(address(bondRuleset)), VOTING_DELAY, VOTING_PERIOD, 0)
            ),
            "register bond type"
        );
        bondTypeId = governor.typeCount() - 1;

        token.mint(bob, 10 * BOND_AMOUNT); // deliberately NOT delegated — zero voting power

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        vm.prank(address(timelock));
        timelock.grantRole(cancellerRole, council);

        vm.roll(block.number + 1);
    }

    function _proposeBonded(string memory description)
        internal
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        targets = new address[](1);
        targets[0] = address(0xBEEF);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = "";
        descriptionHash = keccak256(bytes(description));

        vm.startPrank(bob);
        token.approve(address(bondRuleset), BOND_AMOUNT);
        proposalId = governor.proposeWithType(targets, values, calldatas, description, bondTypeId);
        vm.stopPrank();
    }
}
