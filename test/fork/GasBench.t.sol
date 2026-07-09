// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {Box, BaseTest} from "./Base.t.sol";
import {IGov} from "./IGov.sol";

/// @dev Mainnet-fork A/B gas benchmark: the LIVE ENS governor (real deployed bytecode,
///      real token checkpoint history) vs the stock v5 scaffold on the same fork, wired
///      to the REAL ENS token and REAL ENS timelock. Same structure as the draft repo's
///      benchmark (governor-nexus @ leo/gas-bench-and-notes) so numbers are comparable
///      across the three implementations: live v4, stock v5 scaffold, Nexus draft.
///
///      Run: forge test --match-contract GasBench -vv
///      (override the RPC with MAINNET_RPC_URL if the default is rate-limited)
contract GasBenchTest is BaseTest {
    // prepared in setUp (separate tx) so measured calls start from realistic cold state
    uint256 internal liveVoteId;
    uint256 internal scaffoldVoteId;

    function setUp() public override {
        super.setUp();
        liveVoteId = _propose(liveGov, liveBox, 101, "bench-vote-live");
        scaffoldVoteId = _propose(scaffoldGov, scaffoldBox, 102, "bench-vote-scaffold");
        vm.roll(block.number + liveGov.votingDelay() + 1);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _proposeMeasured(IGov gov, Box box, uint256 newValue, string memory label) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _actions(box, newValue);
        vm.prank(WHALE);
        uint256 g = gasleft();
        gov.propose(t, v, c, "bench-propose");
        console2.log(label, g - gasleft());
    }

    function _voteMeasured(IGov gov, uint256 id, uint8 support, string memory label) internal {
        vm.prank(WHALE);
        uint256 g = gasleft();
        gov.castVote(id, support);
        console2.log(label, g - gasleft());
    }

    /// @dev Fresh proposal, whale votes For (clears quorum alone), roll past deadline.
    function _passed(IGov gov, Box box, uint256 newValue, string memory desc)
        internal
        returns (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh)
    {
        (t, v, c) = _actions(box, newValue);
        dh = keccak256(bytes(desc));
        vm.prank(WHALE);
        uint256 id = gov.propose(t, v, c, desc);
        vm.roll(gov.proposalSnapshot(id) + 1);
        vm.prank(WHALE);
        gov.castVote(id, 1);
        vm.roll(gov.proposalDeadline(id) + 1);
    }

    // ─────────────────────────────── propose ───────────────────────────────

    function test_fork_propose_live() public {
        _proposeMeasured(liveGov, liveBox, 201, "fork propose | live gov:");
    }

    function test_fork_propose_scaffold() public {
        _proposeMeasured(scaffoldGov, scaffoldBox, 202, "fork propose | scaffold:");
    }

    // ─────────────────────────────── castVote ───────────────────────────────

    function test_fork_castVote_live() public {
        _voteMeasured(liveGov, liveVoteId, 1, "fork castVote | live gov:");
    }

    function test_fork_castVote_scaffold() public {
        _voteMeasured(scaffoldGov, scaffoldVoteId, 1, "fork castVote | scaffold:");
    }

    // ─────────────────────────────── queue / execute ───────────────────────────────

    function test_fork_queue_live() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) =
            _passed(liveGov, liveBox, 301, "bench-q-live");
        uint256 g = gasleft();
        liveGov.queue(t, v, c, dh);
        console2.log("fork queue | live gov:", g - gasleft());
    }

    function test_fork_queue_scaffold() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) =
            _passed(scaffoldGov, scaffoldBox, 302, "bench-q-scaffold");
        uint256 g = gasleft();
        scaffoldGov.queue(t, v, c, dh);
        console2.log("fork queue | scaffold:", g - gasleft());
    }

    function test_fork_execute_live() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) =
            _passed(liveGov, liveBox, 303, "bench-x-live");
        liveGov.queue(t, v, c, dh);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
        uint256 g = gasleft();
        liveGov.execute(t, v, c, dh);
        console2.log("fork execute | live gov:", g - gasleft());
    }

    function test_fork_execute_scaffold() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 dh) =
            _passed(scaffoldGov, scaffoldBox, 304, "bench-x-scaffold");
        scaffoldGov.queue(t, v, c, dh);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
        uint256 g = gasleft();
        scaffoldGov.execute(t, v, c, dh);
        console2.log("fork execute | scaffold:", g - gasleft());
    }
}
