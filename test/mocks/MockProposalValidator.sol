// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IProposalValidator} from "../../src/IProposalValidator.sol";
import {IRuleset} from "../../src/IRuleset.sol";
import {StandardRuleset} from "../../src/StandardRuleset.sol";

/// @dev StandardRuleset that also implements IProposalValidator — records the last call and
///      can be armed to revert, so registry tests can observe gating and fail-fast order.
contract MockProposalValidator is StandardRuleset, IProposalValidator {
    address public lastProposer;
    bytes32 public lastDescriptionHash;
    uint256 public calls;
    bool public shouldRevert;

    error ValidatorRejected();

    constructor(address governor_, IVotes token_) StandardRuleset(governor_, token_, 1) {}

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function validateProposal(
        address proposer,
        address[] calldata,
        uint256[] calldata,
        bytes[] calldata,
        bytes32 descriptionHash
    ) external {
        if (shouldRevert) revert ValidatorRejected();
        lastProposer = proposer;
        lastDescriptionHash = descriptionHash;
        ++calls;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IProposalValidator).interfaceId || interfaceId == type(IRuleset).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
