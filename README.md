# nexus

Production implementation of **Governor Nexus** — blockful's modular security upgrade
for ENS governance ([RFC](https://discuss.ens.domains/t/rfc-governor-nexus-modular-security-upgrade-for-ens-governance/21942)).

This repo starts from a **stock OZ v5.6.1 governor scaffold with fork-proven parity
against the live ENS governor**, and grows the Nexus mechanisms milestone by milestone
under a risk-calibrated clean-room method. **This repo has no contact with the
exploratory draft** ([`governor-nexus`](https://github.com/blockful/governor-nexus)):
the comparison happens in a separate instrument repo,
[`nexus-harness`](https://github.com/blockful/nexus-harness), where the draft's 46
tests run as shared vectors against both implementations after each feature.

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
| `docs/spec/v1.md` | Spec freeze v1: scope, architecture, parameters, method, open decisions (owned) |

## Running

```bash
forge build
forge test --no-match-path "test/fork/*"     # unit suite, no network
forge test --match-path "test/fork/*" -vv    # mainnet-fork parity + gas bench
forge coverage --no-match-path "test/fork/*" --report summary
```

Fork tests pin block 25,445,220 and default to a public archive RPC; set
`MAINNET_RPC_URL` for a dedicated endpoint (also the name of the CI secret).

## Differential harness (external, by design)

The differential comparison against the draft lives in
[`blockful/nexus-harness`](https://github.com/blockful/nexus-harness) — the draft's 46
tests as implementation-neutral vectors, one binding per implementation. It is a
separate repo so this one stays fully draft-free (clean-room isolation): after each
feature, the intermediary step pins this repo's candidate commit there, runs the
vectors against both bindings, and records a written verdict. The ABI surface those
vectors exercise is frozen by `docs/spec/v1.md` §4 — renaming any part of it is a spec
amendment, not a harness edit.

## Milestone 0 status

- Scaffold parity on fork: **proven** (`ForkParityTest`, 7 tests + 3 pinned divergences)
- A/B gas baseline (live → scaffold): propose 115k → 93k · castVote 107k → 102k ·
  queue 102k → 120k · execute 79k → 57k
- Differential vectors vs draft: **46/46 green** (baseline verdict in
  `nexus-harness/docs/verdicts/`)
- Spec v1: committed (`docs/spec/v1.md`)
