# nexus

Production implementation of **Governor Nexus** — blockful's modular security upgrade
for ENS governance ([RFC](https://discuss.ens.domains/t/rfc-governor-nexus-modular-security-upgrade-for-ens-governance/21942)).

Current milestone (Nexus 1): `GovernorNexus`, a modular governor core that replaces a
stock governor's baked-in settings/counting/quorum with a vote-governed registry of
proposal types, each dispatching vote-counting to a pluggable external `IRuleset`.
Behavioral parity against the live deployed ENS governor is proven on a mainnet fork,
both for the bootstrap ruleset's counting semantics and for the governor's day-to-day
surface. Nexus mechanisms continue to land milestone by milestone.

## Architecture (Nexus 1)

`GovernorNexus` generalizes the single hard-coded configuration of a stock governor into
a vote-governed, append-only registry of proposal types: each type pins an external
`IRuleset` plus its own voting delay, voting period, and proposal threshold, and once
registered a type's ruleset and parameters never change — only its `active` flag and the
registry's default pointer can move, both gated behind governance. Every proposal is
pinned to exactly one type at creation, for its lifetime; the pin is looked up
transiently (EIP-1153) only while the stock proposal-creation body runs, so the
type-scoped delay/period never leak into externally observable state. Counting itself is
never done by the core — `countVote`, `quorumReached`, `voteSucceeded`, and `hasVoted`
all dispatch to the proposal's pinned ruleset, an immutable, single-purpose contract the
DAO can swap per type without touching the governor. `StandardRuleset` is the bootstrap
ruleset (registered as type 0, the initial default): it reproduces the live ENS
governor's Bravo-style vote buckets (Against/For/Abstain) and fractional quorum exactly,
so a migrated DAO sees identical outcomes until it opts into new types. Untyped surface —
`votingDelay()`, `votingPeriod()`, `quorum()`, `COUNTING_MODE()` — reads the current
default type's row, so the governor stays a drop-in `IGovernor` even though its real
behavior is per-type.

## Spam limit (Nexus 4)

`GovernorNexus` caps how many proposals a single proposer can hold concurrently live —
`Pending` or `Active`, nothing else: a proposal that already survived its vote (`Queued`)
does not occupy a slot, and one that's `Canceled`/`Defeated`/`Executed` frees its slot
immediately. This is a concurrency cap, not a rate limit — it bounds a key's in-flight
governance-attention footprint, not how often it can propose over time. Enforcement is
lazy: on each propose, the governor drops any of the proposer's tracked ids that left the
live set, then reverts if the survivors already fill the cap; a proposal is added to the
tracked set only after that check passes. The cap is governance-settable
(`setMaxActiveProposals`) within `1..MAX_ACTIVE_PROPOSALS_CEILING` (10) — zero is rejected
because it would revert every propose, including the governance proposal needed to raise
it back — and deploys at 2 for the ENS migration (`ENSParams.MAX_ACTIVE_PROPOSALS`). The
cap is per-address and, like `proposalThreshold`, does not resist an attacker willing to
split voting power across multiple addresses — accepted, consistent with every per-address
proposal cap in production governance (Bravo/Nouns/Uniswap all share this property).

## Layout

| Path | What |
|---|---|
| `src/GovernorNexus.sol` | Nexus 1 governor core — proposal-type registry, per-proposal pin, ruleset dispatch |
| `src/IRuleset.sol` | Interface a pluggable ruleset implements (counting, quorum, vote success) |
| `src/StandardRuleset.sol` | Bootstrap ruleset — live-ENS-parity counting (Bravo buckets, fractional quorum) |
| `src/ENSGovernor.sol` | Nexus 0 baseline (kept for reference) — stock OZ v5.6.1 composition, zero custom logic |
| `src/ENSParams.sol` | Live ENS addresses + current governor parameters (single source of truth) |
| `script/Deploy.s.sol` | Deploys `StandardRuleset` + `GovernorNexus` (two-contract, CREATE-address-precompute deploy) against the real ENS token + timelock |
| `test/GovernorNexus.registry.t.sol` | Unit suite: type registration, activation, default-pointer moves |
| `test/GovernorNexus.propose.t.sol` | Unit suite: both propose doors, type pinning, per-type parameters |
| `test/GovernorNexus.lifecycle.t.sol` | Unit suite: full propose → vote → queue → execute lifecycle |
| `test/GovernorNexus.adversarial.t.sol` | Unit suite: malicious/misbehaving ruleset blast-radius containment |
| `test/GovernorNexus.spamlimit.t.sol` | Unit suite: per-proposer live-proposal cap (Nexus 4) |
| `test/GovernorNexusTestBase.sol` | Shared fixture the suites above inherit (deploy wiring + governance-loop helpers) |
| `test/StandardRuleset.t.sol` | Unit suite for the bootstrap ruleset |
| `test/ENSGovernor.t.sol` | Unit suite for the Nexus 0 baseline (mock token, ENS-scale params) |
| `test/Deploy.t.sol` | Unit suite for the deploy script |
| `test/mocks/` | `MockENSToken`, `MockGovernor`, `MaliciousRulesets`, `Box` test target |
| `test/fork/` | Mainnet-fork suites: behavioral parity (live governor vs GovernorNexus) + A/B gas benchmark |

## Build & test

```bash
forge build
forge test --no-match-path "test/fork/*"     # unit suite, no network
forge test --match-path "test/fork/*" -vv    # mainnet-fork parity + gas bench
forge coverage --no-match-path "test/fork/*" --report summary
```

Fork tests pin block 25,445,220 and default to a public archive RPC; set
`MAINNET_RPC_URL` for a dedicated endpoint (also the name of the CI secret).
