# nexus

Production implementation of **Governor Nexus** — blockful's modular security upgrade
for ENS governance ([RFC](https://discuss.ens.domains/t/rfc-governor-nexus-modular-security-upgrade-for-ens-governance/21942)).

Current baseline: a stock OpenZeppelin v5.6.1 governor composition wired with the live
ENS parameters, with behavioral parity against the deployed governor proven on a
mainnet fork. Nexus mechanisms land on top of this baseline milestone by milestone.

## Layout

| Path | What |
|---|---|
| `src/ENSGovernor.sol` | Stock OZ v5.6.1 composition, zero custom logic — the production baseline |
| `src/ENSParams.sol` | Live ENS addresses + current governor parameters (single source of truth) |
| `script/Deploy.s.sol` | Deploys the governor against the real ENS token + timelock |
| `test/ENSGovernor.t.sol` | Unit suite (mock token, ENS-scale params) |
| `test/fork/` | Mainnet-fork suites: behavioral parity vs the live governor + A/B gas benchmark |

## Build & test

```bash
forge build
forge test --no-match-path "test/fork/*"     # unit suite, no network
forge test --match-path "test/fork/*" -vv    # mainnet-fork parity + gas bench
forge coverage --no-match-path "test/fork/*" --report summary
```

Fork tests pin block 25,445,220 and default to a public archive RPC; set
`MAINNET_RPC_URL` for a dedicated endpoint (also the name of the CI secret).
