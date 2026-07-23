# nexus

Production implementation of **Governor Nexus** — blockful's modular security upgrade
for ENS governance ([RFC](https://discuss.ens.domains/t/rfc-governor-nexus-modular-security-upgrade-for-ens-governance/21942)).

`GovernorNexus` is a modular governor core: it replaces a stock governor's baked-in
settings/counting/quorum with a vote-governed registry of proposal types, each dispatching
vote-counting to a pluggable external `IRuleset`. On top of the core sit two behavioral
mechanisms: **mutable votes** (casting again replaces your standing vote) and the
**anti-snipe late-vote extension** (a proposal that flips from failing to passing inside
the final 24h has its voting extended once, by 48h past the original deadline). Behavioral
parity against the live deployed ENS governor is proven on a mainnet fork, both for the
bootstrap ruleset's counting semantics and for the governor's day-to-day surface —
deliberate divergences are pinned as such by the fork suite.

## Architecture

`GovernorNexus` generalizes the single hard-coded configuration of a stock governor into
a vote-governed, append-only registry of proposal types: each type pins an external
`IRuleset` plus its own voting delay, voting period, and proposal threshold, and once
registered a type's ruleset and parameters never change — only its `active` flag and the
registry's default pointer can move, both gated behind governance. Every proposal is
pinned to exactly one type at creation, for its lifetime; the pin is looked up
transiently (EIP-1153) only while the stock proposal-creation body runs, so the
type-scoped delay/period never leak into externally observable state — safe because that
body makes no state-committing external call while the context is set (its only external
dispatch, the duplicate-proposal check, reverts unconditionally), so no reentrant reader
can ever observe the typed values. Counting itself is
never done by the core — `countVote`, `quorumReached`, `voteSucceeded`, and `hasVoted`
all dispatch to the proposal's pinned ruleset, an immutable, single-purpose contract the
DAO can swap per type without touching the governor. `StandardRuleset` is the bootstrap
ruleset (registered as type 0, the initial default): it reproduces the live ENS
governor's Bravo-style vote buckets (Against/For/Abstain) and fractional quorum exactly.
Untyped surface — `votingDelay()`, `votingPeriod()`, `quorum()`, `COUNTING_MODE()` — reads
the current default type's row, so the governor stays a drop-in `IGovernor` even though its
real behavior is per-type.

## Mutable votes

While a proposal is open, casting again replaces your standing vote. This is a deliberate
behavioral divergence from the live ENS governor, which rejects a second vote; the fork
suite pins it as such.

Counting mechanics live in `RulesetCounting`, the abstract base every ruleset inherits: it
owns the vote buckets and a per-voter receipt (`hasVoted`, `support`, `weight`), and it makes
re-voting a **replace** — `countVote` debits the receipt's recorded weight from its recorded
bucket before crediting the new vote, in the same call, so a voter's weight is never
double-counted nor transiently missing. `hasVoted` therefore means "has a standing vote" and
stays true across re-votes.

Two consequences follow for integrators:

- **Indexers:** a re-vote emits another stock `VoteCast` for the same (proposal, voter); the
  **latest one in log order is canonical** — earlier ones are superseded, not additive.
  `voteReceipt(proposalId, voter)` returns the current standing vote directly.
- **Tallies are non-monotonic:** quorum and success can flip in *both* directions while voting
  is open, so no consumer can arm one-shot state on a tally-crossing event — an attacker could
  otherwise cross a threshold early, re-vote back below it, and burn a once-only trigger before
  the crossing that matters. Mechanisms needing finality (e.g. the anti-snipe extension below)
  evaluate the outcome at the deadline, bar re-votes inside their own window, or gate
  early finality.
- **Gasless relayers:** a direct `castVote*` spends the voter's EIP-712 nonce, so voting directly
  invalidates any of that voter's outstanding signed ballots (across all open proposals — the
  nonce is per-account). A stale pre-signed ballot therefore cannot override a later direct vote
  under mutable votes; a relayer needs a fresh signature once the voter acts directly.

## Anti-snipe late-vote extension

If a proposal flips from failing to passing inside the final 24h (`extensionWindow`), voting
is extended once by 48h (`extensionDuration`) — measured from the **original** deadline, so
flip timing buys no extra calendar time. Both params are constructor immutables in clock
units; the mechanism lives in the core and reads the pinned ruleset's
`quorumReached && voteSucceeded`, so every proposal type gets it under its own semantics.

The trigger is a **window low-water mark**, not a one-shot slot: the extension fires iff the
proposal was observed failing at any point inside the window AND would pass at the original
deadline. Nothing is armed on a tally crossing — the pattern the counting layer's
non-monotonicity note forbids — so re-vote oscillation cannot burn the protection; the only
way to avoid the extension is holding the proposal visibly passing for the entire final
window, which is itself the intended response time. Voting stays free in both directions
during the extension; the tally at the extended deadline decides.

Integrator notes:

- **`proposalDeadline` is authoritative** and grows lazily: it returns the original deadline
  until that deadline passes, then the extended one if the extension holds. No tentative
  extension is ever shown mid-window (a flip can still revert before the deadline).
- **`ProposalExtended(proposalId, extendedDeadline)`** (OZ `GovernorPreventLateQuorum` ABI)
  is emitted by the first cast after the original deadline. If nobody votes during the
  extension the event never fires — the views (or replaying `VoteCast` tallies against the
  immutable params) remain the source of truth.


## Batch voting 
(`castVoteWithReasonAndParamsBatch`) casts votes on several proposals in one transaction,
all-or-nothing. A batch is a direct cast: it spends the voter's nonce once, so — like any
direct vote — it invalidates the voter's outstanding signed ballots across all open
proposals. Duplicate ids inside a batch are ordinary re-votes, last-wins. Empty
`reasons[i]`/`params[i]` entries mean "none" — OZ emits `VoteCast` for empty params and
`VoteCastWithParams` otherwise.

Batching is an explicit function rather than OZ's `Multicall` mixin: the governor's payable
surface (`execute`/`relay`/`receive`) is exactly what makes Multicall the msg.value-reuse
bug class, and an explicit signature keeps the batch semantics (single nonce spend,
all-or-nothing) auditable in one place.

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

## Optimistic ruleset

`OptimisticRuleset` is a second production ruleset: proposals under its type **pass by
default** — there is no quorum, and the vote fails only if the Against bucket reaches an
absolute veto threshold (500k ENS at the intended ENS registration) by the deadline. A
proposal nobody voted on executes. Because the "voters judge the content" filter is gone,
safety moves to propose time: the validator enforces that the **proposer is allowlisted**,
every **`(target, selector)` action is allowlisted**, no action carries **ETH value**, and
every action has at least a 4-byte selector — checking the three array lengths itself,
before any indexing, with no reliance on downstream validation. The ruleset deploys with
**empty allowlists**: day one the optimistic path can do nothing, and the DAO votes
entries in through standard full-quorum governance (the setters answer only to the
timelock). The action setter permanently refuses the governance core as a target — the
governor, the timelock, and the ruleset itself — so a zero-vote proposal can never
reconfigure the system that created it.

The propose-time hook is the core's one addition: a ruleset advertising
`IProposalValidator` via ERC165 has `validateProposal(proposer, targets, values,
calldatas)` called before the proposal is created, and a revert blocks creation.
Detection happens once, at `registerType`, pinned as `hasProposalValidation` on the content-immutable
type line and never re-queried — types whose rulesets don't opt in keep a byte-identical
propose path. A misbehaving validator can only brick proposing its own type (a revert
*is* the gate's behavior); other types and the default path never reach it.

Two properties are deliberate and documented rather than solved in code:

- **Selector allowlisting bounds *which function* a proposal may call, never what that
  call semantically does** — allowlisting a token's `approve` is allowlisting the spend.
  Curating entries down to genuinely low-risk operations is the DAO's responsibility.
- **The veto is withdrawable** — under mutable votes, a vetoer re-voting For/Abstain
  drains the Against bucket, so the outcome is non-monotonic in both directions. The
  snipe this enables (withdraw a standing veto at the last block) is exactly the
  failing→passing flip the anti-snipe extension fires on: the community gets the full
  extension window to re-assemble the veto.

`COUNTING_MODE` is `"support=bravo&quorum=against,for,abstain"`, verbatim the string
Optimism's audited optimistic module advertises, so existing indexer support carries over.

## Cancellation

Stock OZ lets only the proposer cancel, and only before voting starts. `GovernorNexus`
replaces that (via the `_validateCancel` hook — no fork): **cancellation is possible only
while the proposal is `Pending` or `Active`** — once the voting process finishes, no one
can cancel, in any state — and within that window two rules apply:

- **Self-cancel:** the proposer can always cancel their own proposal, recovering from
  mistakes without burning a full voting cycle.
- **Continuous threshold:** the propose-time threshold is a standing obligation. If the
  proposer's voting power drops below the **pinned type's** `proposalThreshold`, `cancel()`
  becomes permissionless — anyone can kill the proposal while it is still votable. Types
  registered with a zero threshold (future bond-style or allowlisted paths) never expose
  this rule.

The voting-power read is `getVotes(proposer, clock() - 1)` — byte-for-byte the propose-time
check, so "cancellable by anyone" is exactly "could not create this proposal now". The
clause structure and the prior-block read follow Compound Governor Bravo's production
semantics (shipped since 2021); the window is deliberately narrower than Bravo's, which
keeps below-threshold cancel open through `Succeeded`/`Queued` — here a proposal that
survived its vote is settled, and post-vote outcomes (including a proposer who dips after
voting ends) belong to execution or to a fresh governance action, not to `cancel()`.
Design consequences, accepted deliberately:

- **Single-block dips count.** A proposer below threshold for one block (a re-delegation in
  transit, a transfer-and-return) leaves the proposal cancellable at the next block, even
  if their power is already back. Griefing-only (nothing is stolen; the proposer can
  re-propose) and proposer-controlled (keeping the threshold backed is their obligation).
  No hysteresis and no guardian-exemption role, matching the no-privileged-actors design.
- **No post-vote backstop.** Bravo's wide window lets anyone cancel a queued proposal whose
  proposer drained their power during the timelock delay; this design trades that backstop
  away for the guarantee that a passed proposal cannot be griefed out of the queue. The
  timelock delay remains the DAO's reaction window through its own governance paths.
- **The threshold is the pinned one.** The check reads the proposal's registered type row —
  content-immutable — never live config and never the ruleset, so a later governance change
  (new types, moved default) cannot retroactively change any live proposal's cancel
  exposure, and a malicious ruleset has no say in cancel authorization.

## Layout

| Path | What |
|---|---|
| `src/GovernorNexus.sol` | Governor core — proposal-type registry, per-proposal pin, ruleset dispatch |
| `src/GovernorPreventLateFlip.sol` | **Anti-snipe extension**, an abstract Governor module (window low-water mark, lazy deadline extension) — reusable by any OZ v5 governor, hardened for mutable votes |
| `src/IRuleset.sol` | Interface a pluggable ruleset implements (counting, quorum, vote success) |
| `src/RulesetCounting.sol` | Counting base every ruleset inherits — Bravo buckets, per-voter receipts, **mutable votes** (a re-vote replaces the standing vote) |
| `src/StandardRuleset.sol` | Bootstrap ruleset — live-ENS-parity quorum/success rules on top of the counting base |
| `src/IProposalValidator.sol` | Optional ruleset extension — propose-time content validation hook, ERC165-detected at registration |
| `src/OptimisticRuleset.sol` | Optimistic ruleset — pass-unless-vetoed outcome + propose-time proposer/action allowlists |
| `src/ENSGovernor.sol` | Stock OZ v5.6.1 baseline composition, zero custom logic — kept for reference and parity testing |
| `src/ENSParams.sol` | Live ENS addresses + current governor parameters (single source of truth) |
| `script/Deploy.s.sol` | Deploys `StandardRuleset` + `GovernorNexus` (two-contract, CREATE-address-precompute deploy) against the real ENS token + timelock |
| `test/GovernorNexus.registry.t.sol` | Unit suite: type registration, activation, default-pointer moves |
| `test/GovernorNexus.propose.t.sol` | Unit suite: both propose doors, type pinning, per-type parameters |
| `test/GovernorNexus.lifecycle.t.sol` | Unit suite: full propose → vote → queue → execute lifecycle |
| `test/GovernorNexus.adversarial.t.sol` | Unit suite: malicious/misbehaving ruleset blast-radius containment |
| `test/GovernorNexus.spamlimit.t.sol` | Unit suite: per-proposer live-proposal cap (Nexus 4) |
| `test/GovernorNexus.cancel.t.sol` | Unit suite: cancellation policy — self-cancel + continuous-threshold permissionless cancel (Nexus 5) |
| `test/GovernorNexusTestBase.sol` | Shared fixture the suites above inherit (deploy wiring + governance-loop helpers) |
| `test/GovernorNexus.lateFlip.t.sol` | Unit + fuzz suite for the late-flip extension: trigger matrix, oscillation/burn attempts, lazy materialization, model-checked fuzz |
| `test/RulesetCounting.t.sol` | Unit + fuzz suite for the counting base: re-vote replace mechanics, tally conservation, receipt width guard |
| `test/StandardRuleset.t.sol` | Unit suite for the bootstrap ruleset |
| `test/OptimisticRuleset.t.sol` | Unit + fuzz suite for the optimistic ruleset: veto boundary, validator rules, allowlist setters |
| `test/GovernorNexus.proposalValidation.t.sol` | Integration suite for the propose-time validation gate (mock validators only): detection/pinning, revert propagation, misbehaving-validator containment |
| `test/GovernorNexus.optimistic.t.sol` | Integration suite for the optimistic type: validation rules through the gate, allowlist governance loop, e2e lifecycle, veto-withdrawal × anti-snipe |
| `test/ENSGovernor.t.sol` | Unit suite for the stock baseline (mock token, ENS-scale params) |
| `test/Deploy.t.sol` | Unit suite for the deploy script |
| `test/mocks/` | `MockENSToken`, `MockGovernor`, `MaliciousRulesets`, `ValidatorRulesets`, `Box` test target |
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

## Milestones

Branches, PR titles, and spec docs are named by milestone ("Nexus N"); the sections above
describe each mechanism without that vocabulary. The decoder:

| Milestone | What landed |
|---|---|
| Nexus 0 | Stock OZ baseline (`ENSGovernor.sol`) reproducing the live ENS governor |
| Nexus 1 | Modular governor core — proposal-type registry + pluggable rulesets |
| Nexus 2 | Mutable votes — a re-vote replaces the standing vote |
| Nexus 3 | Anti-snipe late-vote extension ([spec](docs/specs/2026-07-17-nexus3-late-vote-extension.md)) |
| Nexus 4 | Spam limit — per-proposer cap on concurrently live proposals |
| Nexus 5 | Cancellation — proposer self-cancel + continuous-threshold permissionless cancel |
| Nexus 6 | Batch voting — `castVoteWithReasonAndParamsBatch` |
| Nexus 7 | Optimistic ruleset — pass-unless-vetoed + the propose-time validation gate ([spec](docs/specs/2026-07-22-nexus7-optimistic-ruleset.md)) |
