// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {GovernorNexus} from "../src/GovernorNexus.sol";
import {StandardRuleset} from "../src/StandardRuleset.sol";
import {ENSParams} from "../src/ENSParams.sol";

/// @dev Exercises `Deploy.run()` exactly as `forge script` would invoke it: no fork, no
///      mocked token/timelock. The token-constructor investigation (see task report) found
///      that neither `GovernorVotes` nor `GovernorTimelockControl`'s constructors make any
///      external call on the addresses they're given — both only store them (see
///      `lib/openzeppelin-contracts/contracts/governance/extensions/GovernorVotes.sol:18-20`
///      and `.../GovernorTimelockControl.sol:36-38,153-156`) — so `ENSParams.TOKEN` and
///      `ENSParams.TIMELOCK` can safely be no-code addresses here. The only constructor path
///      that reaches out during deploy is `GovernorNexus`'s ERC165 `staticcall` on the
///      ruleset, which is real, locally-deployed code. A fork is therefore unnecessary.
contract DeployTest is Test {
    Deploy internal deployScript;

    function setUp() public {
        deployScript = new Deploy();
    }

    function test_run_wiresStandardRulesetAndGovernorNexus() public {
        (StandardRuleset standardRuleset, GovernorNexus governor) = deployScript.run();

        // D11: name parity with the live governor's EIP-712 domain.
        assertEq(governor.name(), "ENS Governor");

        // Ruleset <-> governor wiring (cycle broken via the precompute).
        assertEq(standardRuleset.governor(), address(governor));
        assertEq(address(standardRuleset.token()), ENSParams.TOKEN);
        assertEq(standardRuleset.quorumNumerator(), ENSParams.QUORUM_NUMERATOR);

        // Bootstrap type row 0 is the default and carries the live ENS params.
        assertEq(governor.defaultTypeId(), 0);
        GovernorNexus.TypeConfig memory typeConfig = governor.getTypeConfig(0);
        assertEq(address(typeConfig.ruleset), address(standardRuleset));
        assertEq(typeConfig.votingDelay, ENSParams.VOTING_DELAY);
        assertEq(typeConfig.votingPeriod, ENSParams.VOTING_PERIOD);
        assertEq(typeConfig.proposalThreshold, ENSParams.PROPOSAL_THRESHOLD);
        assertTrue(typeConfig.active);
    }
}
