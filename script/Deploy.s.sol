// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {ENSParams} from "../src/ENSParams.sol";

/// @notice Deploys the Nexus system — `StandardRuleset` + `GovernorNexus` — wired to the
///         real ENS token and timelock with the live governor's current parameters. Neither
///         contract is granted timelock roles here; migration onto the live timelock is a
///         DAO proposal granting PROPOSER + EXECUTOR (the live timelock is OZ v4.3:
///         CANCELLER_ROLE does not exist there).
/// @dev Wiring (spec §Wiring note): `StandardRuleset.countVote` is `onlyGovernor` and
///      `quorumReached` reads `governor.proposalSnapshot`, so the ruleset must be
///      constructed with the governor's address — but the governor's constructor needs the
///      ruleset (it registers row 0 with it). Break the cycle by precomputing the
///      governor's CREATE address before either contract deploys: the ruleset deploys at
///      nonce N, the governor at nonce N + 1, so `computeCreateAddress(sender, N + 1)`
///      predicts it up front. `require` on the actual governor address afterwards turns any
///      broken assumption (e.g. an intervening transaction bumping the nonce) into a hard
///      revert instead of a silently miswired deploy.
///
///      Broadcast-context subtlety: inside `vm.startBroadcast()`, CREATE addresses derive
///      from the BROADCASTER's address and nonce, not the script contract's
///      (`address(this)`). Forge-std resolves the broadcaster as: `--sender` if given, else
///      the sole configured signer, else the default Foundry sender — never the script
///      contract. `vm.readCallers()` reports that resolved address, so the nonce used for
///      the prediction is read from it, not from `address(this)`.
contract Deploy is Script {
    /// @notice Deploys `StandardRuleset` then `GovernorNexus` (in that order, address
    ///         prediction enforced), wired to the live ENS token/timelock/params.
    /// @return standardRuleset The deployed ruleset, registered as GovernorNexus's type 0.
    /// @return governor The deployed GovernorNexus, at the address `standardRuleset` was
    ///         constructed with.
    function run() external returns (StandardRuleset standardRuleset, GovernorNexus governor) {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();

        address predictedGovernor = vm.computeCreateAddress(broadcaster, vm.getNonce(broadcaster) + 1);

        standardRuleset = new StandardRuleset(predictedGovernor, IVotes(ENSParams.TOKEN), ENSParams.QUORUM_NUMERATOR);

        // Name "ENS Governor" so `name()` and the EIP-712 vote-by-sig domain match the live
        // governor (spec D11).
        governor = new GovernorNexus(
            "ENS Governor",
            IVotes(ENSParams.TOKEN),
            TimelockController(ENSParams.TIMELOCK),
            standardRuleset,
            ENSParams.VOTING_DELAY,
            ENSParams.VOTING_PERIOD,
            ENSParams.PROPOSAL_THRESHOLD
        );
        require(address(governor) == predictedGovernor, "Deploy: governor address prediction failed");

        vm.stopBroadcast();
    }
}
