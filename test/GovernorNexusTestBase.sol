// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {MockENSToken} from "./mocks/MockENSToken.sol";

/// @dev Shared fixture for GovernorNexus unit suites: deploys token + timelock + plain
///      `GovernorNexus` + bootstrap ruleset, funds a majority voter, and provides the
///      governance loop that is the only path to the `onlyGovernance` setters.
///
///      With real ruleset counting in place (Task 4) the suites run against production
///      `GovernorNexus` directly — no counting mixin, no subclass. The bootstrap ruleset's
///      1% quorum is trivially cleared by alice's 2_000_000e18 (the only funded holder here,
///      so total supply == her balance), keeping the governance loop passing.
abstract contract GovernorNexusTestBase is Test {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 50;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;

    MockENSToken internal token;
    TimelockController internal timelock;
    GovernorNexus internal governor;
    StandardRuleset internal standardRuleset;

    address internal alice = makeAddr("alice"); // proposer + majority voter
    address internal eoa = makeAddr("eoa"); // unauthorized caller

    function setUp() public virtual {
        vm.roll(1000);
        vm.warp(1_700_000_000);

        token = new MockENSToken();
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), new address[](0), address(this));

        // Wiring (spec §Wiring note): StandardRuleset.countVote is onlyGovernor and
        // quorumReached reads governor.proposalSnapshot, so the bootstrap ruleset must know
        // the governor address — but the governor constructor needs the ruleset. Break the
        // cycle by precomputing the governor's CREATE address (this deployer's next nonce
        // + 1) and asserting the prediction held.
        address predictedGovernor = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        standardRuleset = new StandardRuleset(predictedGovernor, IVotes(address(token)), 1);

        governor = new GovernorNexus(
            "GovernorNexus",
            IVotes(address(token)),
            timelock,
            standardRuleset,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            2
        );
        require(address(governor) == predictedGovernor, "governor address prediction failed");

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        _fund(alice, 2_000_000e18);
        vm.roll(block.number + 1);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.delegate(account);
    }

    /// @dev Deploys a fresh StandardRuleset (a valid IRuleset) wired to the fixture governor.
    function _newRuleset() internal returns (StandardRuleset) {
        return new StandardRuleset(address(governor), IVotes(address(token)), 1);
    }

    // ───────────────── Governance loop (the only path to the setters) ─────────────────

    /// @dev Propose (self-call) → vote → queue → warp past timelock; leaves the proposal
    ///      ready to `execute`. Caller executes so it can wrap `execute` with expectEmit /
    ///      expectRevert as needed.
    function _prepareSelfCall(bytes memory data, string memory description)
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = data;
        descriptionHash = keccak256(bytes(description));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
    }

    /// @dev Full loop including a successful execute.
    function _executeSelfCall(bytes memory data, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _prepareSelfCall(data, description);
        governor.execute(targets, values, calldatas, descriptionHash);
    }
}
