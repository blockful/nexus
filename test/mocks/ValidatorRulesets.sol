// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IProposalValidator} from "../../src/IProposalValidator.sol";
import {IRuleset} from "../../src/IRuleset.sol";

/// @title Validator ruleset mocks for the propose-time validation gate suite
/// @notice Each concrete ruleset below differs from a plain inert ruleset by exactly one
///         validator behavior, so `GovernorNexus.proposalValidation.t.sol` can pin the
///         gate's properties — detection/pinning at registration, revert propagation, and
///         blast-radius containment — independent of any production ruleset.

/// @dev Minimal well-formed ruleset base: honest inert counting surface, so each concrete
///      mock is its one validator behavior and nothing else.
abstract contract ValidatorMockBase is IRuleset {
    function countVote(uint256, address, uint8, uint256 weight, bytes calldata) external pure returns (uint256) {
        return weight;
    }

    function quorumReached(uint256) external pure returns (bool) {
        return false;
    }

    function voteSucceeded(uint256) external pure returns (bool) {
        return false;
    }

    function hasVoted(uint256, address) external pure returns (bool) {
        return false;
    }

    function quorum(uint256) external pure returns (uint256) {
        return 0;
    }

    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() external pure returns (string memory) {
        return "support=bravo&quorum=for";
    }
}

/// @dev Well-behaved validator: accepts every proposal. The healthy control a containment
///      test proposes through while a sibling type's validator is misbehaving.
contract AcceptingValidatorRuleset is ValidatorMockBase, IProposalValidator {
    function validateProposal(address, address[] calldata, uint256[] calldata, bytes[] calldata) external pure {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IProposalValidator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Attack: `validateProposal` always reverts — a poisoned gate. Containment expected:
///      only proposes of ITS OWN type brick; every other type is unaffected.
contract PoisonedValidatorRuleset is ValidatorMockBase, IProposalValidator {
    error ValidatorPoisoned();

    function validateProposal(address, address[] calldata, uint256[] calldata, bytes[] calldata) external pure {
        revert ValidatorPoisoned();
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IProposalValidator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Attack: `validateProposal` burns all forwarded gas. Same containment expectation.
contract GasBurnValidatorRuleset is ValidatorMockBase, IProposalValidator {
    function validateProposal(address, address[] calldata, uint256[] calldata, bytes[] calldata) external pure {
        for (uint256 i = 0;; ++i) {}
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IProposalValidator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev A ruleset whose ERC165 answer for `IProposalValidator` is MUTABLE — impossible for
///      the immutable rulesets the DAO actually registers, built here to pin that detection
///      happens once, at registration, and is never re-queried.
contract ToggleableValidatorRuleset is ValidatorMockBase, IProposalValidator {
    error ShouldNeverRun();

    bool public advertiseValidator;

    function setAdvertiseValidator(bool advertise) external {
        advertiseValidator = advertise;
    }

    /// @dev Would brick every propose if the gate ever became live for this type.
    function validateProposal(address, address[] calldata, uint256[] calldata, bytes[] calldata) external pure {
        revert ShouldNeverRun();
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (interfaceId == type(IProposalValidator).interfaceId) return advertiseValidator;
        return interfaceId == type(IRuleset).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
