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
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";

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

    function test_voteSucceeded_slashCountsAsOpposition() public {
        // For 50 vs Against 30 + Slash 30 → rejections 60 > 50 → not succeeded
        vm.startPrank(governorMock);
        ruleset.countVote(1, address(1), uint8(BondRuleset.VoteType.For), 50, "");
        ruleset.countVote(1, address(2), uint8(BondRuleset.VoteType.Against), 30, "");
        ruleset.countVote(1, address(3), uint8(BondRuleset.VoteType.AgainstAndSlash), 30, "");
        vm.stopPrank();
        assertFalse(ruleset.voteSucceeded(1));
    }

    function test_voteSucceeded_tieIsNotSuccess() public {
        vm.startPrank(governorMock);
        ruleset.countVote(1, address(1), uint8(BondRuleset.VoteType.For), 60, "");
        ruleset.countVote(1, address(2), uint8(BondRuleset.VoteType.AgainstAndSlash), 60, "");
        vm.stopPrank();
        assertFalse(ruleset.voteSucceeded(1));
    }

    function test_quorumReached_ignoresAgainstAndSlash() public {
        // Give the token real past supply: 1000e18 at the snapshot → quorum (1%) = 10e18.
        token.mint(makeAddr("holder"), 1000e18);
        vm.roll(block.number + 1);
        govStub.setSnapshot(block.number - 1);

        // Slash-only weight 100e18 must NOT satisfy quorum...
        vm.prank(governorMock);
        ruleset.countVote(1, address(1), uint8(BondRuleset.VoteType.AgainstAndSlash), 100e18, "");
        assertFalse(ruleset.quorumReached(1));
        // ...but 10e18 of Abstain does.
        vm.prank(governorMock);
        ruleset.countVote(1, address(2), uint8(BondRuleset.VoteType.Abstain), 10e18, "");
        assertTrue(ruleset.quorumReached(1));
    }

    function test_revote_movesWeightAcrossSlashBucket() public {
        vm.startPrank(governorMock);
        ruleset.countVote(1, address(1), uint8(BondRuleset.VoteType.AgainstAndSlash), 40, "");
        ruleset.countVote(1, address(1), uint8(BondRuleset.VoteType.For), 40, ""); // replace
        vm.stopPrank();
        (uint256 against,,, uint256 slash) = ruleset.proposalVotes(1);
        assertEq(slash, 0);
        assertEq(against, 0);
        assertTrue(ruleset.voteSucceeded(1));
    }

    function _lockArgs() internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) {
        t = new address[](1);
        t[0] = address(0xBEEF);
        v = new uint256[](1);
        c = new bytes[](1);
        c[0] = "";
        h = keccak256(bytes("bond proposal"));
    }

    function _canonicalId(address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(t, v, c, h)));
    }

    function test_validateProposal_locksBond_recordsDelta() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _lockArgs();
        address bob = makeAddr("bob");
        token.mint(bob, BOND);
        vm.prank(bob);
        token.approve(address(ruleset), BOND);

        vm.expectEmit(true, true, false, true);
        emit BondRuleset.BondLocked(_canonicalId(t, v, c, h), bob, BOND);
        vm.prank(governorMock);
        ruleset.validateProposal(bob, t, v, c, h);

        (address proposer, uint96 amount, bool settled) = ruleset.bondOf(_canonicalId(t, v, c, h));
        assertEq(proposer, bob);
        assertEq(amount, BOND);
        assertFalse(settled);
        assertEq(token.balanceOf(address(ruleset)), BOND);
    }

    function test_validateProposal_onlyGovernor() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _lockArgs();
        vm.expectRevert(abi.encodeWithSelector(RulesetCounting.Unauthorized.selector, address(this)));
        ruleset.validateProposal(makeAddr("bob"), t, v, c, h);
    }

    function test_validateProposal_revertsWithoutApproval() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _lockArgs();
        address bob = makeAddr("bob");
        token.mint(bob, BOND); // funded but no approve
        vm.prank(governorMock);
        vm.expectRevert(); // SafeERC20 insufficient-allowance revert
        ruleset.validateProposal(bob, t, v, c, h);
    }

    function test_validateProposal_duplicateLockReverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _lockArgs();
        address bob = makeAddr("bob");
        token.mint(bob, 2 * BOND);
        vm.prank(bob);
        token.approve(address(ruleset), 2 * BOND);
        vm.startPrank(governorMock);
        ruleset.validateProposal(bob, t, v, c, h);
        vm.expectRevert(abi.encodeWithSelector(BondRuleset.BondAlreadyLocked.selector, _canonicalId(t, v, c, h)));
        ruleset.validateProposal(bob, t, v, c, h);
        vm.stopPrank();
    }

    function test_validateProposal_feeOnTransfer_reverts() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        BondRuleset feeRuleset = new BondRuleset(governorMock, IVotes(address(feeToken)), 1, BOND, treasury);
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _lockArgs();
        address bob = makeAddr("bob");
        feeToken.mint(bob, BOND);
        vm.prank(bob);
        feeToken.approve(address(feeRuleset), BOND);
        vm.prank(governorMock);
        vm.expectRevert(BondRuleset.InsufficientBondReceived.selector);
        feeRuleset.validateProposal(bob, t, v, c, h);
    }
}
