// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DraftBinding} from "./bindings/DraftBinding.sol";
import {BondRulesetVectors} from "./BondRulesetVectors.sol";
import {GovernorCoreVectors} from "./GovernorCoreVectors.sol";
import {OptimisticRulesetVectors} from "./OptimisticRulesetVectors.sol";
import {VectorsFixture} from "./VectorsFixture.sol";

/// @dev The 46 shared vectors executed against the DRAFT implementation (v0.1 reference).
///      When the production implementation lands (milestone 1+), a ProductionBinding
///      overrides `_deploySystem` and three sibling contracts here run the exact same
///      vectors against it — the differential comparison the roadmap's clean-room
///      verdicts are based on.
contract DraftGovernorCoreTest is GovernorCoreVectors, DraftBinding {}

contract DraftBondRulesetTest is BondRulesetVectors, DraftBinding {
    function setUp() public override(VectorsFixture, BondRulesetVectors) {
        super.setUp();
    }
}

contract DraftOptimisticRulesetTest is OptimisticRulesetVectors, DraftBinding {
    function setUp() public override(VectorsFixture, OptimisticRulesetVectors) {
        super.setUp();
    }
}
