// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GovernorNexus} from "draft/GovernorNexus.sol";
import {IRuleset} from "draft/interfaces/IRuleset.sol";
import {BondRuleset} from "draft/rulesets/BondRuleset.sol";
import {OptimisticRuleset} from "draft/rulesets/OptimisticRuleset.sol";
import {StandardRuleset} from "draft/rulesets/StandardRuleset.sol";

import {IBondRulesetVector, INexus, IOptimisticRulesetVector, IStandardRulesetVector} from "../ISystemUnderTest.sol";
import {VectorsFixture} from "../VectorsFixture.sol";

/// @dev Binds the vectors to the DRAFT implementation (lib/governor-nexus-draft, pinned at
///      the v0.1 reference commit). Deployment and wiring replicate the draft repo's
///      own NexusFixture exactly. The production binding lands with milestone 1+ and
///      overrides the same hook.
abstract contract DraftBinding is VectorsFixture {
    function _deploySystem() internal override {
        GovernorNexus nexus = new GovernorNexus(
            IVotes(address(token)),
            timelock,
            GovernorNexus.NexusConfig({
                votingDelay: VOTING_DELAY,
                votingPeriod: VOTING_PERIOD,
                proposalThreshold: THRESHOLD,
                maxActiveProposals: MAX_ACTIVE,
                lateVoteWindow: LATE_WINDOW,
                lateVoteExtension: LATE_EXTENSION
            })
        );

        StandardRuleset standard = new StandardRuleset(address(nexus), address(timelock), 0, QUORUM);
        OptimisticRuleset optimistic =
            new OptimisticRuleset(address(nexus), address(timelock), OPTIMISTIC_PERIOD, VETO_THRESHOLD);
        BondRuleset bond = new BondRuleset(
            address(nexus), address(timelock), 0, QUORUM, IERC20(address(token)), BOND_AMOUNT, address(timelock)
        );

        uint8[] memory typeIds = new uint8[](3);
        typeIds[0] = TYPE_STANDARD;
        typeIds[1] = TYPE_OPTIMISTIC;
        typeIds[2] = TYPE_BOND;
        IRuleset[] memory rulesets = new IRuleset[](3);
        rulesets[0] = standard;
        rulesets[1] = optimistic;
        rulesets[2] = bond;
        nexus.initializeRulesets(typeIds, rulesets);

        governor = INexus(address(nexus));
        standardRuleset = IStandardRulesetVector(address(standard));
        optimisticRuleset = IOptimisticRulesetVector(address(optimistic));
        bondRuleset = IBondRulesetVector(address(bond));
    }
}
