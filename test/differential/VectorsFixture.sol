// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Box, MockVotesToken} from "../utils/TestUtils.sol";
import {IBondRulesetVector, INexus, IOptimisticRulesetVector, IStandardRulesetVector} from "./ISystemUnderTest.sol";

/// @dev Shared-vector fixture: the port of the draft repo's NexusFixture with the
///      implementation under test injected through `_deploySystem`. Bindings (one per
///      implementation) deploy their concrete system and hand back interface-typed
///      handles; every vector below runs unchanged against any binding.
///
///      Parameters, actors, and setup order are byte-for-byte the draft fixture's, so
///      vector outcomes are comparable across implementations by construction.
abstract contract VectorsFixture is Test {
    // Test-scale parameters (clock = block numbers on the mock token).
    uint48 internal constant VOTING_DELAY = 100; // RFC: 2 days
    uint32 internal constant VOTING_PERIOD = 700; // default / Standard
    uint256 internal constant THRESHOLD = 10e18;
    uint8 internal constant MAX_ACTIVE = 2; // RFC: per-proposer active limit
    uint48 internal constant LATE_WINDOW = 100; // RFC: last 24h
    uint48 internal constant LATE_EXTENSION = 200; // RFC: +48h
    uint256 internal constant QUORUM = 100e18; // RFC: 1M ENS
    uint256 internal constant OPTIMISTIC_PERIOD = 1500; // RFC: 15 days
    uint256 internal constant VETO_THRESHOLD = 50e18; // RFC: 500k ENS
    uint256 internal constant BOND_AMOUNT = 5e18;
    uint256 internal constant TIMELOCK_DELAY = 2 days; // seconds (timelock is timestamp-based)

    uint8 internal constant TYPE_STANDARD = 0;
    uint8 internal constant TYPE_OPTIMISTIC = 1;
    uint8 internal constant TYPE_BOND = 2;

    MockVotesToken internal token;
    TimelockController internal timelock;
    Box internal box;

    // Implementation under test, behind neutral handles.
    INexus internal governor;
    IStandardRulesetVector internal standardRuleset;
    IOptimisticRulesetVector internal optimisticRuleset;
    IBondRulesetVector internal bondRuleset;

    address internal alice = makeAddr("alice"); // large delegate
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave"); // no voting power

    /// @dev Deploys the concrete system (governor + the three rulesets, types
    ///      registered) and assigns the interface-typed handles above. Runs as the test
    ///      contract, so deployer-restricted bootstraps see the fixture as deployer.
    function _deploySystem() internal virtual;

    function setUp() public virtual {
        vm.roll(1000);
        vm.warp(1_700_000_000);

        token = new MockVotesToken();
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), new address[](0), address(this));

        _deploySystem();

        // Migration end-state: governor drives the timelock, admin renounced.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        box = new Box(address(timelock));

        _fund(alice, 200e18);
        _fund(bob, 100e18);
        _fund(carol, 50e18);
        vm.roll(block.number + 1); // make balances visible to getPastVotes(clock - 1)
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

    function _proposeStandard(address proposer, uint256 newValue, string memory description)
        internal
        returns (uint256 proposalId)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) =
            _boxProposal(newValue, description);
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function _rollToActive(uint256 proposalId) internal {
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
    }

    function _rollPastDeadline(uint256 proposalId) internal {
        vm.roll(governor.proposalDeadline(proposalId) + 1);
    }

    function _queueAndExecute(uint256 newValue, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _boxProposal(newValue, description);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }
}
