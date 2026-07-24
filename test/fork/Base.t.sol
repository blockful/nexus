// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../../src/GovernorNexus.sol";
import {StandardRuleset} from "../../src/StandardRuleset.sol";
import {ENSParams} from "../../src/ENSParams.sol";
import {Box} from "../mocks/Box.sol";
import {IGov} from "./IGov.sol";

/// @dev Mainnet fork with the LIVE ENS governor and a locally-deployed GovernorNexus
///      scaffold (type 0 = StandardRuleset, ENS params) wired to the REAL ENS token and
///      REAL ENS timelock, both configured identically. Type 0 is designed to be
///      observationally indistinguishable from the live v4 governor. The same whale
///      delegate (nick.eth) drives every operation on both sides.
abstract contract BaseTest is Test {
    address internal constant WHALE = 0xb8c2C29ee19D8307cb7255e1Cd9CbDE883A267d5; // nick.eth, ~3.26M votes
    uint256 internal constant FORK_BLOCK = 25_445_220;

    IGov internal liveGov = IGov(ENSParams.GOVERNOR);
    TimelockController internal timelock = TimelockController(ENSParams.TIMELOCK);
    GovernorNexus internal scaffold;
    StandardRuleset internal standardRuleset;
    IGov internal scaffoldGov;

    Box internal liveBox;
    Box internal scaffoldBox;

    function setUp() public virtual {
        // Default is a public archive endpoint (publicnode gates archive state behind a
        // token nowadays); override with MAINNET_RPC_URL for a dedicated key.
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);

        // Wiring: StandardRuleset.countVote is onlyGovernor and
        // quorumReached reads governor.proposalSnapshot, so the ruleset must be constructed
        // with the governor's address — but the governor constructor needs the ruleset. Break
        // the cycle by precomputing the governor's CREATE address (this deployer's next nonce
        // + 1, since the ruleset deploys first) and asserting the prediction held.
        address predictedGovernor = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        standardRuleset = new StandardRuleset(predictedGovernor, IVotes(ENSParams.TOKEN), ENSParams.QUORUM_NUMERATOR);

        // Name "ENS Governor" so `name()` and the EIP-712 vote-by-sig domain match the live
        // governor. Type 0 = StandardRuleset with the live ENS params.
        scaffold = new GovernorNexus(
            "ENS Governor",
            IVotes(ENSParams.TOKEN),
            timelock,
            standardRuleset,
            ENSParams.VOTING_DELAY,
            ENSParams.VOTING_PERIOD,
            ENSParams.PROPOSAL_THRESHOLD,
            ENSParams.MAX_ACTIVE_PROPOSALS,
            ENSParams.EXTENSION_WINDOW,
            ENSParams.EXTENSION_DURATION
        );
        require(address(scaffold) == predictedGovernor, "scaffold governor address prediction failed");
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
