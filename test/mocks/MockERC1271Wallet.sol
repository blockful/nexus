// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @dev Minimal ERC-1271 smart-contract wallet: valid iff the ECDSA signature over `hash`
///      recovers to the immutable `owner`. Exists to exercise `SignatureChecker`'s
///      ERC-1271 branch in the vote-signature validators.
contract MockERC1271Wallet is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered,,) = ECDSA.tryRecover(hash, signature);
        return recovered == owner ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}
