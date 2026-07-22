// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Test} from "forge-std/Test.sol";

import {BondRuleset} from "../src/BondRuleset.sol";
import {GovernorNexus} from "../src/GovernorNexus.sol";
import {MockENSToken} from "./mocks/MockENSToken.sol";
import {BondRulesetTestBase} from "./BondRulesetTestBase.sol";

/// @dev Drives randomized propose/vote/roll/resolve sequences against the
///      real governor + BondRuleset and checks conservation: the ruleset's balance always
///      covers every unsettled bond, and no bond ever pays out twice.
contract BondHandler is Test {
    GovernorNexus public governor;
    BondRuleset public ruleset;
    MockENSToken public token;
    uint8 public bondTypeId;
    address public proposerPool; // single bonded proposer keeps VP bookkeeping simple
    address public voter;

    uint256[] public ids;
    mapping(uint256 => bool) public resolvedOnce;
    uint256 public doubleSettles; // must stay 0

    uint256 internal nonce;

    constructor(GovernorNexus g, BondRuleset r, MockENSToken t, uint8 typeId, address proposer_, address voter_) {
        governor = g;
        ruleset = r;
        token = t;
        bondTypeId = typeId;
        proposerPool = proposer_;
        voter = voter_;
    }

    function propose() external {
        ++nonce;
        string memory description = string(abi.encodePacked("bond#", vm.toString(nonce)));
        address[] memory t = new address[](1);
        t[0] = address(0xBEEF);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodePacked(nonce); // unique calldata → unique id
        vm.startPrank(proposerPool);
        token.approve(address(ruleset), ruleset.bondAmount());
        try governor.proposeWithType(t, v, c, description, bondTypeId) returns (uint256 id) {
            ids.push(id);
        } catch {} // spam-limit cap etc. — fine
        vm.stopPrank();
    }

    function vote(uint256 idSeed, uint8 support) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        support = support % 4;
        vm.prank(voter);
        try governor.castVote(id, support) {} catch {}
    }

    function roll(uint16 blocks) external {
        vm.roll(block.number + (uint256(blocks) % 100) + 1);
    }

    function resolve(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        try ruleset.resolveBond(id) {
            if (resolvedOnce[id]) ++doubleSettles;
            resolvedOnce[id] = true;
        } catch {}
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }
}

contract BondRulesetInvariantTest is BondRulesetTestBase {
    BondHandler internal handler;

    function setUp() public override {
        super.setUp();
        token.mint(bob, 1_000_000e18); // deep pool for many proposals
        handler = new BondHandler(governor, bondRuleset, token, bondTypeId, bob, alice);
        targetContract(address(handler));
    }

    function _maxActiveProposals() internal pure override returns (uint8) {
        return 10;
    }

    /// Conservation: ruleset balance covers every unsettled bond.
    function invariant_bondConservation() public view {
        uint256 owed;
        uint256 n = handler.idsLength();
        for (uint256 i = 0; i < n; ++i) {
            (, uint96 amount, bool settled) = bondRuleset.bondOf(handler.idAt(i));
            if (!settled) owed += amount;
        }
        assertGe(token.balanceOf(address(bondRuleset)), owed);
    }

    /// One-shot settlement: resolveBond never succeeds twice for the same id.
    function invariant_noDoubleSettle() public view {
        assertEq(handler.doubleSettles(), 0);
    }
}
