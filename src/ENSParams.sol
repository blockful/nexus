// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ENSParams
/// @notice Mainnet addresses and the live ENS governor's current parameters, read from
///         0x323A…b7E3 at block 25445220. Single source of truth for the deploy script
///         and the fork parity/gas suites.
library ENSParams {
    address internal constant TOKEN = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
    address payable internal constant TIMELOCK = payable(0xFe89cc7aBB2C4183683ab71653C4cdc9B02D44b7);
    address internal constant GOVERNOR = 0x323A76393544d5ecca80cd6ef2A560C6a395b7E3;

    uint48 internal constant VOTING_DELAY = 1; // blocks
    uint32 internal constant VOTING_PERIOD = 45_818; // blocks (~1 week)
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18; // 100k ENS
    // Live governor expresses quorum as 100/10000; OZ v5's default denominator is 100,
    // so numerator 1 encodes the same 1%. Parity is asserted on quorum() output, which
    // is denominator-independent.
    uint256 internal constant QUORUM_NUMERATOR = 1;

    // Late-flip extension: final-24h trigger window and 48h extension, in
    // blocks (~12s/block), matching the block-denominated voting period above.
    uint48 internal constant EXTENSION_WINDOW = 7200; // 24h
    uint48 internal constant EXTENSION_DURATION = 14_400; // 48h
}
