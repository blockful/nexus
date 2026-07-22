// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {BondRuleset} from "../src/BondRuleset.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IProposalValidator} from "../src/IProposalValidator.sol";
import {RulesetCounting} from "../src/RulesetCounting.sol";
import {MockENSToken} from "./mocks/MockENSToken.sol";

/// @dev Stand-in for the governor: the only surface the unit suite needs is
///      `proposalSnapshot` (quorum tests) — settle-path reads are exercised in the
///      integration suite (Task 6) against the real governor.
contract MockSnapshotGovernor {
    uint256 public snapshot;

    function setSnapshot(uint256 s) external {
        snapshot = s;
    }

    function proposalSnapshot(uint256) external view returns (uint256) {
        return snapshot;
    }
}

contract BondRulesetTest is Test {
    MockENSToken internal token;
    MockSnapshotGovernor internal govStub;
    address internal governorMock; // == address(govStub); pranked for countVote/validateProposal
    address internal treasury = makeAddr("treasury");
    uint256 internal constant BOND = 1_000e18;

    BondRuleset internal ruleset;

    function setUp() public {
        token = new MockENSToken();
        govStub = new MockSnapshotGovernor();
        governorMock = address(govStub);
        ruleset = new BondRuleset(governorMock, IVotes(address(token)), 1, BOND, treasury);
    }

    function test_constructor_pinsImmutables() public view {
        assertEq(address(ruleset.token()), address(token));
        assertEq(ruleset.quorumNumerator(), 1);
        assertEq(ruleset.bondAmount(), BOND);
        assertEq(ruleset.treasury(), treasury);
    }

    function test_constructor_revertsOnZeroBond() public {
        vm.expectRevert(abi.encodeWithSelector(BondRuleset.InvalidBondAmount.selector, 0));
        new BondRuleset(governorMock, IVotes(address(token)), 1, 0, treasury);
    }

    function test_constructor_revertsOnOversizedBond() public {
        uint256 tooBig = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(BondRuleset.InvalidBondAmount.selector, tooBig));
        new BondRuleset(governorMock, IVotes(address(token)), 1, tooBig, treasury);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(BondRuleset.ZeroTreasury.selector);
        new BondRuleset(governorMock, IVotes(address(token)), 1, BOND, address(0));
    }

    function test_constructor_revertsOnQuorumAbove100() public {
        vm.expectRevert(abi.encodeWithSelector(BondRuleset.InvalidQuorumFraction.selector, 101, 100));
        new BondRuleset(governorMock, IVotes(address(token)), 101, BOND, treasury);
    }

    function test_supportsInterface() public view {
        assertTrue(ruleset.supportsInterface(type(IRuleset).interfaceId));
        assertTrue(ruleset.supportsInterface(type(IProposalValidator).interfaceId));
        assertTrue(ruleset.supportsInterface(type(IERC165).interfaceId));
        assertFalse(ruleset.supportsInterface(0xdeadbeef));
    }

    function test_countingMode() public view {
        assertEq(ruleset.COUNTING_MODE(), "support=bravo,againstAndSlash&quorum=for,abstain");
    }

    function test_supportValues_acceptsFourRejectsFifth() public {
        vm.startPrank(governorMock);
        ruleset.countVote(1, address(1), 0, 1, "");
        ruleset.countVote(1, address(2), 1, 1, "");
        ruleset.countVote(1, address(3), 2, 1, "");
        ruleset.countVote(1, address(4), 3, 1, "");
        vm.expectRevert(RulesetCounting.InvalidVoteType.selector); // inherited error
        ruleset.countVote(1, address(5), 4, 1, "");
        vm.stopPrank();
    }

    function test_proposalVotes_fourBuckets() public {
        vm.startPrank(governorMock);
        ruleset.countVote(1, address(1), 0, 10, "");
        ruleset.countVote(1, address(2), 1, 20, "");
        ruleset.countVote(1, address(3), 2, 30, "");
        ruleset.countVote(1, address(4), 3, 40, "");
        vm.stopPrank();
        (uint256 against, uint256 forV, uint256 abstain, uint256 slash) = ruleset.proposalVotes(1);
        assertEq(against, 10);
        assertEq(forV, 20);
        assertEq(abstain, 30);
        assertEq(slash, 40);
    }
}
