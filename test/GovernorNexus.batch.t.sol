// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {GovernorNexus} from "../src/GovernorNexus.sol";
import {Box} from "./mocks/Box.sol";
import {GovernorNexusTestBase} from "./GovernorNexusTestBase.sol";

/// @dev Batch voting suite (Nexus 6, DEV-1002 — spec D27–D32). Extends the shared base:
///      alice (2_000_000e18) proposes; carol (30e18) is the batch voter so every weight
///      assertion reads 30e18. All-or-nothing semantics (D29), one nonce spend per batch
///      (D30), duplicates are intra-tx re-votes (D32).
contract GovernorNexusBatchTest is GovernorNexusTestBase {
    address internal carol = makeAddr("carol");
    Box internal box;

    function setUp() public override {
        super.setUp();
        box = new Box(address(timelock));
        _fund(carol, 30e18);
        vm.roll(block.number + 1);
    }

    // ─────────────────────────── Helpers ───────────────────────────

    function _boxCall(uint256 newValue, string memory description)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(box);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Box.setValue, (newValue));
        descriptionHash = keccak256(bytes(description));
    }

    /// @dev Propose a box call as `typeId` and roll into the active window.
    function _proposeActive(uint256 newValue, string memory description, uint8 typeId)
        internal
        returns (uint256 proposalId)
    {
        (address[] memory t, uint256[] memory v, bytes[] memory c,) = _boxCall(newValue, description);
        vm.prank(alice);
        proposalId = governor.proposeWithType(t, v, c, description, typeId);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _supports(uint8 a, uint8 b) internal pure returns (uint8[] memory arr) {
        arr = new uint8[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _reasons(string memory a, string memory b) internal pure returns (string[] memory arr) {
        arr = new string[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _params(bytes memory a, bytes memory b) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // ─────────────────────────── 1. Happy path (D27) ───────────────────────────

    function test_castVoteBatch_votesOnMultipleProposals() public {
        uint256 p1 = _proposeActive(1, "batch 1", 0);
        uint256 p2 = _proposeActive(2, "batch 2", 0);

        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(carol, p1, 1, 30e18, "yes");
        vm.expectEmit(true, true, true, true, address(governor));
        emit IGovernor.VoteCast(carol, p2, 0, 30e18, "");

        vm.prank(carol);
        uint256[] memory weights =
            governor.castVoteBatch(_ids(p1, p2), _supports(1, 0), _reasons("yes", ""), _params("", ""));

        assertEq(weights.length, 2, "one weight per item");
        assertEq(weights[0], 30e18, "p1 weight");
        assertEq(weights[1], 30e18, "p2 weight");
        assertTrue(governor.hasVoted(p1, carol));
        assertTrue(governor.hasVoted(p2, carol));
        assertEq(standardRuleset.tally(p1, 1), 30e18, "For tally on p1");
        assertEq(standardRuleset.tally(p2, 0), 30e18, "Against tally on p2");
    }

    // ─────────────────────────── 2. Guards (D29) ───────────────────────────

    function test_castVoteBatch_emptyBatchReverts() public {
        vm.expectRevert(GovernorNexus.EmptyBatch.selector);
        vm.prank(carol);
        governor.castVoteBatch(new uint256[](0), new uint8[](0), new string[](0), new bytes[](0));
    }

    function test_castVoteBatch_lengthMismatchReverts() public {
        // supports shorter
        vm.expectRevert(GovernorNexus.BatchLengthMismatch.selector);
        vm.prank(carol);
        governor.castVoteBatch(new uint256[](2), new uint8[](1), new string[](2), new bytes[](2));
        // reasons shorter
        vm.expectRevert(GovernorNexus.BatchLengthMismatch.selector);
        vm.prank(carol);
        governor.castVoteBatch(new uint256[](2), new uint8[](2), new string[](1), new bytes[](2));
        // params shorter
        vm.expectRevert(GovernorNexus.BatchLengthMismatch.selector);
        vm.prank(carol);
        governor.castVoteBatch(new uint256[](2), new uint8[](2), new string[](2), new bytes[](1));
    }

    // ─────────────────────────── 3. Nonce spend (D30) ───────────────────────────

    /// @dev A batch is a direct cast: it must invalidate the voter's outstanding signed
    ///      ballots, exactly like the single-vote D21 overrides. Without this, the batch
    ///      path reopens the Nexus 2 audit-panel Medium (stale relayer ballot overriding a
    ///      later direct vote).
    function test_castVoteBatch_invalidatesOutstandingSignedBallot() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        _fund(signer, 30e18);
        vm.roll(block.number + 1);

        uint256 p1 = _proposeActive(1, "batched direct vote", 0);
        uint256 p2 = _proposeActive(2, "held ballot", 0);

        // Signer hands a relayer a For ballot on p2, then changes their mind and
        // batch-votes (on p1 only — the nonce is account-global, D21).
        bytes memory pendingFor = _signBallot(p2, 1, signer, signerKey, governor.nonces(signer));

        uint256[] memory ids = new uint256[](1);
        ids[0] = p1;
        uint8[] memory supportValues = new uint8[](1);
        string[] memory reasons = new string[](1);
        bytes[] memory params = new bytes[](1);
        vm.prank(signer);
        governor.castVoteBatch(ids, supportValues, reasons, params);

        // The outstanding ballot died with the batch.
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        governor.castVoteBySig(p2, 1, signer, pendingFor);
    }

    function _signBallot(uint256 proposalId, uint8 support, address voter, uint256 key, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, support, voter, nonce));
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            governor.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
