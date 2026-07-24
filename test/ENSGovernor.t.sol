// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ENSGovernor} from "../src/ENSGovernor.sol";
import {ENSParams} from "../src/ENSParams.sol";
import {Box} from "./mocks/Box.sol";
import {MockENSToken} from "./mocks/MockENSToken.sol";

/// @dev Unit suite for `ENSGovernor`, configured with the live ENS parameters.
///      Exercises the full lifecycle against a mock token + fresh timelock; the fork
///      suite (test/fork) repeats this against the real token/timelock and live governor.
contract ENSGovernorTest is Test {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    MockENSToken internal token;
    TimelockController internal timelock;
    ENSGovernor internal governor;
    Box internal box;

    address internal alice = makeAddr("alice"); // above proposal threshold, clears quorum
    address internal bob = makeAddr("bob"); // small holder

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);

        token = new MockENSToken();
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), new address[](0), address(this));
        governor = new ENSGovernor(
            IVotes(address(token)),
            timelock,
            ENSParams.VOTING_DELAY,
            ENSParams.VOTING_PERIOD,
            ENSParams.PROPOSAL_THRESHOLD,
            ENSParams.QUORUM_NUMERATOR
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        box = new Box(address(timelock));

        // 100M total supply mirrors ENS scale: alice alone clears the 1% quorum.
        _fund(alice, 2_000_000e18);
        _fund(bob, 98_000_000e18 - 2_000_000e18);
        vm.prank(bob);
        token.delegate(address(0)); // bob holds supply but delegates nothing
        _fund(address(0xdead), 2_000_000e18);
        vm.roll(block.number + 1);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.delegate(account);
    }

    function _boxProposal(uint256 newValue, string memory description)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(box);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Box.setValue, (newValue));
        descriptionHash = keccak256(bytes(description));
    }

    // ─────────────────────────── Configuration ───────────────────────────

    function test_parametersMatchLiveENSGovernor() public view {
        assertEq(governor.name(), "ENS Governor");
        assertEq(governor.votingDelay(), 1);
        assertEq(governor.votingPeriod(), 45_818);
        assertEq(governor.proposalThreshold(), 100_000e18);
        assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertEq(address(governor.token()), address(token));
        assertEq(governor.timelock(), address(timelock));
    }

    function test_quorumIsOnePercentOfPastSupply() public view {
        assertEq(governor.quorum(block.number - 1), token.getPastTotalSupply(block.number - 1) / 100);
    }

    // ─────────────────────────── Lifecycle ───────────────────────────

    function test_fullLifecycle_proposeVoteQueueExecute() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(42, "set 42");

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "set 42");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
        assertEq(governor.proposalSnapshot(proposalId), block.number + ENSParams.VOTING_DELAY);

        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        vm.roll(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(box.value(), 42);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_proposeBelowThreshold_reverts() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(1, "no votes");
        vm.prank(bob); // delegated away, zero voting power
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, bob, 0, ENSParams.PROPOSAL_THRESHOLD
            )
        );
        governor.propose(targets, values, calldatas, "no votes");
    }

    function test_defeated_whenQuorumNotReached() public {
        // drop alice below quorum: 500k < 1% of ~102M
        vm.prank(alice);
        token.delegate(alice); // no-op, keeps her power for proposing
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(1, "no quorum");
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "no quorum");

        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        // nobody votes at all
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_cannotVoteBeforeSnapshot() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(1, "early vote");
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "early vote");

        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_cannotRevote_stockGovernorVotesAreImmutable() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = _boxProposal(1, "immutable");
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "immutable");
        vm.roll(governor.proposalSnapshot(proposalId) + 1);

        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, alice));
        governor.castVote(proposalId, 0);
    }
}
