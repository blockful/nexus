// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ENSGovernor} from "../../src/ENSGovernor.sol";
import {ENSParams} from "../../src/ENSParams.sol";
import {Box} from "../utils/TestUtils.sol";
import {IGov} from "./IGov.sol";

/// @dev Mainnet fork with the LIVE ENS governor and the stock v5 scaffold wired to the
///      REAL ENS token and REAL ENS timelock, both configured identically. The same
///      whale delegate (nick.eth) drives every operation on both sides.
abstract contract BaseTest is Test {
    address internal constant WHALE = 0xb8c2C29ee19D8307cb7255e1Cd9CbDE883A267d5; // nick.eth, ~3.26M votes
    uint256 internal constant FORK_BLOCK = 25_445_220;

    IGov internal liveGov = IGov(ENSParams.GOVERNOR);
    TimelockController internal timelock = TimelockController(ENSParams.TIMELOCK);
    ENSGovernor internal scaffold;
    IGov internal scaffoldGov;

    Box internal liveBox;
    Box internal scaffoldBox;

    function setUp() public virtual {
        // Default is a public archive endpoint (publicnode gates archive state behind a
        // token nowadays); override with MAINNET_RPC_URL for a dedicated key.
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);

        scaffold = new ENSGovernor(
            IVotes(ENSParams.TOKEN),
            timelock,
            ENSParams.VOTING_DELAY,
            ENSParams.VOTING_PERIOD,
            ENSParams.PROPOSAL_THRESHOLD,
            ENSParams.QUORUM_NUMERATOR
        );
        scaffoldGov = IGov(address(scaffold));

        // Migration end-state on the REAL timelock (it is its own admin on mainnet).
        // The live ENS timelock is OZ v4.3 — CANCELLER_ROLE doesn't exist there
        // (cancellation authority is PROPOSER_ROLE), so only these two are granted.
        vm.startPrank(ENSParams.TIMELOCK);
        timelock.grantRole(keccak256("PROPOSER_ROLE"), address(scaffold));
        timelock.grantRole(keccak256("EXECUTOR_ROLE"), address(scaffold));
        vm.stopPrank();

        // One target per governor: identical calldata against distinct targets keeps
        // timelock operation ids from colliding between the two sides.
        liveBox = new Box(ENSParams.TIMELOCK);
        scaffoldBox = new Box(ENSParams.TIMELOCK);
    }

    /// @dev Builds the standard single-action payload — `box.setValue(newValue)` — as the
    ///      (targets, values, calldatas) trio every governor entrypoint expects.
    function _actions(Box box, uint256 newValue)
        internal
        pure
        returns (address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        t = new address[](1);
        t[0] = address(box);
        v = new uint256[](1);
        c = new bytes[](1);
        c[0] = abi.encodeCall(Box.setValue, (newValue));
    }

    /// @dev Proposes `box.setValue(newValue)` on the given governor as the whale. Routing
    ///      both sides through this one helper keeps the A/B payloads identical by
    ///      construction — the only differences are the ones the test declares.
    function _propose(IGov gov, Box box, uint256 newValue, string memory desc) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _actions(box, newValue);
        vm.prank(WHALE);
        id = gov.propose(t, v, c, desc);
    }
}
