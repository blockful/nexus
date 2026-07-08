# nexus

Production implementation of **Governor Nexus** — blockful's modular security upgrade
for ENS governance ([RFC](https://discuss.ens.domains/t/rfc-governor-nexus-modular-security-upgrade-for-ens-governance/21942)).

This repo starts from a **stock OZ v5.6.1 governor scaffold with fork-proven parity
against the live ENS governor**, and grows the Nexus mechanisms milestone by milestone
under a risk-calibrated clean-room method. The exploratory draft
([`governor-nexus`](https://github.com/blockful/governor-nexus)) is vendored as a
pinned reference (`lib/governor-nexus-draft`, vendored from commit `87d659b` — see its
`PROVENANCE.md`) and is compared against — never
copied from — via the differential harness.

The frozen spec, method, parameters, and open decisions live in
[`docs/spec/v1.md`](docs/spec/v1.md).

## Layout

| Path | What |
|---|---|
| `src/ENSGovernor.sol` | Stock OZ v5.6.1 composition, zero custom logic — the milestone-0 baseline |
| `src/ENSParams.sol` | Live ENS addresses + current governor parameters (single source of truth) |
| `test/ENSGovernor.t.sol` | Unit suite for the scaffold (mock token, ENS-scale params) |
| `test/fork/ForkParity.t.sol` | Behavioral parity vs the live governor on a mainnet fork, incl. pinned v4→v5 divergences |
| `test/fork/GasBenchFork.t.sol` | A/B gas benchmark: live governor vs scaffold, same fork/whale as the draft's bench |
| `test/differential/` | The draft's 46 tests as implementation-neutral shared vectors + the draft binding |
| `docs/spec/v1.md` | Spec freeze v1: scope, architecture, parameters, method, open decisions (owned) |

## Running

```bash
forge build
forge test --no-match-path "test/fork/*"     # unit + 46 differential vectors, no network
forge test --match-path "test/fork/*" -vv    # mainnet-fork parity + gas bench
forge coverage --no-match-path "test/fork/*" --report summary
```

Fork tests pin block 25,445,220 and default to a public archive RPC; set
`MAINNET_RPC_URL` for a dedicated endpoint (also the name of the CI secret).

## Differential harness

`test/differential/ISystemUnderTest.sol` freezes the ABI surface the vectors exercise.
`VectorsFixture` injects the implementation under test through `_deploySystem()`;
`bindings/DraftBinding.sol` binds the draft. When production milestones land, a
`ProductionBinding` runs the exact same 46 vectors against the new code — "matches the
draft" is a test run, not an opinion.

## Milestone 0 status

- Scaffold parity on fork: **proven** (`ForkParityTest`, 7 tests + 3 pinned divergences)
- A/B gas baseline (live → scaffold): propose 115k → 93k · castVote 107k → 102k ·
  queue 102k → 120k · execute 79k → 57k
- Differential vectors vs draft: **46/46 green**
- Spec v1: committed (`docs/spec/v1.md`)
