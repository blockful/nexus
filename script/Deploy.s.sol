// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ENSGovernor} from "../src/ENSGovernor.sol";
import {ENSParams} from "../src/ENSParams.sol";

/// @notice Deploys the stock scaffold wired to the real ENS token and timelock with the
///         live governor's current parameters. The governor gets no timelock roles here;
///         migration is a DAO proposal granting PROPOSER + EXECUTOR (the live timelock
///         is OZ v4.3: CANCELLER_ROLE does not exist there).
contract Deploy is Script {
    function run() external returns (ENSGovernor governor) {
        vm.startBroadcast();
        governor = new ENSGovernor(
            IVotes(ENSParams.TOKEN),
            TimelockController(ENSParams.TIMELOCK),
            ENSParams.VOTING_DELAY,
            ENSParams.VOTING_PERIOD,
            ENSParams.PROPOSAL_THRESHOLD,
            ENSParams.QUORUM_NUMERATOR
        );
        vm.stopBroadcast();
    }
}
