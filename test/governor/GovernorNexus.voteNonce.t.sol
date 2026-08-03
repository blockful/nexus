// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {Box} from "../mocks/Box.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";

/// @dev Per-proposal ballot nonce suite. `voteNonce(proposalId, account)` scopes signed-ballot
///      invalidation to the proposal that was cast on; the inherited account-global
///      `nonces(address)` is orphaned at 0 and never spent.
contract GovernorNexusVoteNonceTest is GovernorNexusTestBase {
    address internal signer;
    uint256 internal signerKey;
    Box internal box;

    function setUp() public override {
        super.setUp();
        box = new Box(address(timelock));
        (signer, signerKey) = makeAddrAndKey("signer");
        _fund(signer, 30e18);
        vm.roll(block.number + 1);
    }

    // ─────────────────────────── Helpers ───────────────────────────

    /// @dev Propose a distinct box call as type 0 and roll into the active window.
    function _proposeActive(uint256 newValue, string memory description) internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = address(box);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Box.setValue, (newValue));
        vm.prank(alice);
        proposalId = governor.proposeWithType(targets, values, calldatas, description, 0);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            governor.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _signBallot(uint256 proposalId, uint8 support, address voter, uint256 key, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, support, voter, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signExtendedBallot(
        uint256 proposalId,
        uint8 support,
        address voter,
        uint256 key,
        uint256 nonce,
        string memory reason,
        bytes memory params
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                governor.EXTENDED_BALLOT_TYPEHASH(),
                proposalId,
                support,
                voter,
                nonce,
                keccak256(bytes(reason)),
                keccak256(params)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────────── Cross-proposal independence (the target case) ───────────────────────────

    /// @dev A direct vote on proposal A must NOT invalidate the voter's outstanding signed
    ///      ballot for proposal B — the nonce is scoped per proposal.
    function test_directVote_doesNotInvalidateSignaturesOnOtherProposals() public {
        uint256 idA = _proposeActive(1, "proposal A");
        uint256 idB = _proposeActive(2, "proposal B");

        bytes memory pendingB = _signBallot(idB, 1, signer, signerKey, governor.voteNonce(idB, signer));

        vm.prank(signer);
        governor.castVote(idA, 1);

        governor.castVoteBySig(idB, 1, signer, pendingB);

        (, uint256 forB,) = standardRuleset.proposalVotes(idB);
        assertEq(forB, 30e18, "ballot for B must survive a direct vote on A");
    }

    /// @dev Same-proposal protection is preserved: a direct vote invalidates the voter's
    ///      outstanding ballot for THAT proposal.
    function test_directVote_invalidatesOutstandingBallotSameProposal() public {
        uint256 id = _proposeActive(1, "same proposal");

        bytes memory pending = _signBallot(id, 1, signer, signerKey, governor.voteNonce(id, signer));

        vm.prank(signer);
        governor.castVote(id, 0);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        governor.castVoteBySig(id, 1, signer, pending);
    }

    // ─────────────────────────── Nonce accounting ───────────────────────────

    /// @dev Core invariant: voteNonce == number of applied casts, across every cast path.
    function test_voteNonce_incrementsOnEveryCastPath() public {
        uint256 idA = _proposeActive(1, "count A");
        uint256 idB = _proposeActive(2, "count B");

        assertEq(governor.voteNonce(idA, signer), 0, "fresh proposal starts at 0");

        vm.prank(signer);
        governor.castVote(idA, 1);
        assertEq(governor.voteNonce(idA, signer), 1, "direct cast bumps");
        assertEq(governor.voteNonce(idB, signer), 0, "other proposal untouched");

        bytes memory sig = _signBallot(idA, 0, signer, signerKey, governor.voteNonce(idA, signer));
        governor.castVoteBySig(idA, 0, signer, sig);
        assertEq(governor.voteNonce(idA, signer), 2, "bySig cast bumps");

        uint256[] memory ids = new uint256[](2);
        ids[0] = idA;
        ids[1] = idB;
        uint8[] memory supportValues = new uint8[](2);
        supportValues[0] = 1;
        supportValues[1] = 1;
        vm.prank(signer);
        governor.castVoteWithReasonAndParamsBatch(ids, supportValues, new string[](2), new bytes[](2));
        assertEq(governor.voteNonce(idA, signer), 3, "batch item bumps its own proposal");
        assertEq(governor.voteNonce(idB, signer), 1, "each batch item spends on its proposal");
    }

    /// @dev Duplicate ids inside one batch are intra-tx re-votes: each application bumps.
    function test_batch_duplicateIds_bumpNoncePerItem() public {
        uint256 idA = _proposeActive(1, "dup A");
        uint256 idB = _proposeActive(2, "dup B");

        uint256[] memory ids = new uint256[](3);
        ids[0] = idA;
        ids[1] = idB;
        ids[2] = idA;
        uint8[] memory supportValues = new uint8[](3);
        supportValues[0] = 1;
        supportValues[1] = 1;
        supportValues[2] = 0;
        vm.prank(signer);
        governor.castVoteWithReasonAndParamsBatch(ids, supportValues, new string[](3), new bytes[](3));

        assertEq(governor.voteNonce(idA, signer), 2, "duplicate id bumps once per item");
        assertEq(governor.voteNonce(idB, signer), 1, "single item bumps once");
    }

    /// @dev The inherited account-global Nonces is orphaned: nothing spends it anymore.
    function test_accountGlobalNonces_stayZero() public {
        uint256 id = _proposeActive(1, "orphaned nonces");

        vm.prank(signer);
        governor.castVote(id, 1);

        bytes memory sig = _signBallot(id, 0, signer, signerKey, governor.voteNonce(id, signer));
        governor.castVoteBySig(id, 0, signer, sig);

        assertEq(governor.nonces(signer), 0, "account-global nonce is never spent");
    }

    // ─────────────────────────── Re-signing and extended path ───────────────────────────

    /// @dev After a direct vote, a ballot signed against the FRESH per-proposal nonce is
    ///      valid — mutable votes, last-applied wins.
    function test_freshSignatureAfterDirectVote_succeeds() public {
        uint256 id = _proposeActive(1, "fresh re-sign");

        vm.prank(signer);
        governor.castVote(id, 0);

        bytes memory fresh = _signBallot(id, 1, signer, signerKey, governor.voteNonce(id, signer));
        governor.castVoteBySig(id, 1, signer, fresh);

        (uint256 against, uint256 for_,) = standardRuleset.proposalVotes(id);
        assertEq(for_, 30e18, "fresh bySig re-vote lands");
        assertEq(against, 0, "re-vote replaces the direct vote");
    }

    /// @dev The extended (reason+params) signature path binds to the same per-proposal nonce.
    function test_extendedBallot_usesPerProposalNonce() public {
        uint256 idA = _proposeActive(1, "extended A");
        uint256 idB = _proposeActive(2, "extended B");

        bytes memory pendingB =
            _signExtendedBallot(idB, 1, signer, signerKey, governor.voteNonce(idB, signer), "gm", "");

        vm.prank(signer);
        governor.castVote(idA, 1);

        governor.castVoteWithReasonAndParamsBySig(idB, 1, signer, "gm", "", pendingB);
        assertEq(governor.voteNonce(idB, signer), 1, "extended bySig applied and bumped");

        // A second cast on B invalidates a stale extended ballot for B.
        bytes memory stale = _signExtendedBallot(idB, 0, signer, signerKey, 0, "stale", "");
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        governor.castVoteWithReasonAndParamsBySig(idB, 0, signer, "stale", "", stale);
    }

    // ─────────────────────────── ERC-1271 contract-signer coverage ───────────────────────────

    /// @dev A ballot signed by the wallet's EOA owner validates through the ERC-1271 branch of
    ///      `SignatureChecker` and bumps the contract voter's per-proposal nonce.
    function test_castVoteBySig_erc1271Wallet_validatesAndBumpsNonce() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("walletOwner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(owner);
        _fund(address(wallet), 30e18);
        vm.roll(block.number + 1);

        uint256 id = _proposeActive(1, "erc1271 wallet vote");

        bytes memory ballot = _signBallot(id, 1, address(wallet), ownerKey, governor.voteNonce(id, address(wallet)));
        governor.castVoteBySig(id, 1, address(wallet), ballot);

        assertEq(governor.voteNonce(id, address(wallet)), 1, "wallet's per-proposal nonce bumped");
        (, uint256 forVotes,) = standardRuleset.proposalVotes(id);
        assertEq(forVotes, 30e18, "wallet ballot counted");
    }

    /// @dev Replaying that same ERC-1271-validated ballot fails: the nonce it was built
    ///      against is already spent.
    function test_castVoteBySig_erc1271Wallet_replayReverts() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("walletOwner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(owner);
        _fund(address(wallet), 30e18);
        vm.roll(block.number + 1);

        uint256 id = _proposeActive(1, "erc1271 wallet replay");

        bytes memory ballot = _signBallot(id, 1, address(wallet), ownerKey, governor.voteNonce(id, address(wallet)));
        governor.castVoteBySig(id, 1, address(wallet), ballot);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, address(wallet)));
        governor.castVoteBySig(id, 1, address(wallet), ballot);
    }
}
