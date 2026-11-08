# Testing

How to run every test, what each test file covers, how we test, and what is still missing. Results were measured on 2026-11-08 on the current code, run on Windows 11 (Git Bash), unless a row gives another date. Slither and coverage are in [Security analysis](#security-analysis). The properties the tests check are in [`invariants.md`](invariants.md).

## 1. How to run

### Contracts (`contracts/`, Foundry)

Tools: Foundry forge 1.8.5 (the version CI pins), solc 0.8.28 (set in `foundry.toml`). Clone with submodules (`git submodule update --init --recursive`): OpenZeppelin and forge-std live in `contracts/lib/`.

```
cd contracts
forge build                 # compile
forge build --sizes --skip './test/**' --skip './script/**'   # deployable contract sizes (CI step)
forge test                  # all unit, fuzz, end-to-end and invariant tests
forge test -vvv             # same, with traces for failures (what CI runs)
forge test --summary        # adds a pass/fail table per test suite
forge test --match-path test/OutcomeOrderBook.t.sol      # one file
forge test --match-test test_E2E4_OptimisticUndisputed   # one test
forge fmt --check           # formatting check (CI step)
```

Invariant tests (`test/invariant/`) run in every `forge test`. Settings in `foundry.toml`:

| Profile | Runs | Calls per run (depth) | Command |
|---|---|---|---|
| default | 64 | 64 | `forge test --match-path 'test/invariant/*'` |
| deep | 512 | 128 | `FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'` |

Both use `fail_on_revert = false`. The handlers catch expected reverts and count real violations in ghost counters, which the `invariant_*` functions check. Fuzz tests use 1000 runs (`[fuzz] runs = 1000`), except `testFuzz_ConservationAcrossRandomActions`, which sets 256 runs itself.

Coverage:

```
forge coverage --report summary
forge coverage --report lcov --report-file <dir>/lcov.info          # line and branch detail
forge coverage --no-match-path 'test/invariant/*' --report summary  # without the invariant suite
```

`--ir-minimum` is not needed (no stack-too-deep error). Slither is not in CI; see [Security analysis](#security-analysis) for how to run it.

Two warnings:

- **`forge build --sizes` without `--skip`** exits 1: `Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)`. The contract over the limit is the test handler `MarketHandler` (`test/invariant/MarketHandler.sol`, 34,326 bytes), which is never deployed. All `src/` contracts are under the limit. CI therefore runs the `--skip` form shown above, which exits 0 ([AI log entry 8](ai/lin.md)). `forge test` still builds and runs every test.
- **`forge fmt --check` on a Windows checkout.** With `core.autocrlf=true`, Git writes CRLF line endings and `forge fmt --check` reports every file (exit 1), although the committed files are formatted. Check the committed content instead: `git show HEAD:contracts/<file> | forge fmt --check -`. CI checks out with LF and is not affected.

### Bot (`bot/`, Python)

Tools: [uv](https://docs.astral.sh/uv/) (0.13.7 was used). The tests need no network, API keys or RPC.

```
cd bot
uv sync --locked                       # create .venv from uv.lock
uv run playwright install chromium     # browser for tests/test_browser.py
uv run pytest -rs                      # all tests, print the reason for each skip
uv run pytest -q tests/test_agent.py   # one file
```

`tests/test_browser.py` skips itself when Chromium is missing. CI treats that skip as a failure.

### CI (`.github/workflows/ci.yml`)

Runs on pull requests, pushes to `main`, and by hand (`workflow_dispatch`). Read-only permissions, no secrets. A newer push to the same branch cancels the older run.

| Job | Steps |
|---|---|
| Contracts (fmt, build, test) | `actions/checkout@v5` with submodules (recursive); `foundry-rs/foundry-toolchain@v1` pinned to forge v1.8.5; `forge fmt --check`; `forge build --sizes --skip './test/**' --skip './script/**'`; `forge test -vvv` |
| Bot (pytest) | `actions/checkout@v5`; `astral-sh/setup-uv@v6` (cache keyed on `bot/uv.lock`); `uv sync --locked`; `uv run playwright install --with-deps chromium`; `uv run pytest -rs`, then fails the job if the log contains "Chromium not installed" |

CI does not run Slither, coverage or the deep invariant profile. Those are run by hand.

## 2. Test files

Counts are from `forge test --summary` and `uv run pytest --collect-only -q`.

### Contracts: `contracts/test/*.t.sol`

| File | Tests | What it covers |
|---|---|---|
| `ChainlinkResolver.t.sol` | 28 | Owner-only `configure` and its checks (zero feed, zero staleness, wrong arbitrator, twice, after close). Price rules `Below`/`Above` including ties. Picking the round live at `closeTime`: exact-at-close, latest round, last round before a phase upgrade, superseded rounds (same and next phase), missing rounds. Staleness edge, non-positive price, resolving before close, after the deadline, twice. A winner redeems after resolution. Uses `MockAggregator`. |
| `EndToEnd.t.sol` | 9 | Full lifecycle with the real factory, `MockUSDC`, both resolvers and `MockAggregator`, one test per resolution route: direct YES and NO, Chainlink above/below/tie, optimistic undisputed, disputed with the judge upholding or overturning, timeout cancel and refund, and disputed or proposed-only requests left open and refunded. Every test asserts every actor's final balance against values computed beforehand with a separate Python model, and calls `_assertConserved()`: USDC summed over 11 actors and contracts plus all markets equals what was minted. |
| `MarketFactory.t.sol` | 37 | `createMarket`: stored parameters, event, ids from 1, collateral moved and pools seeded at 50/50, unique token ids, exact minimums. Admin role, collateral approval, every validation revert (zero arbitrator, close time in the past or now, not 50/50, low liquidity, empty spec, bad config, collateral without 6 decimals). Clone and implementation cannot be initialised again. `OutcomeToken` access control: only the factory registers, only a market mints or burns its own ids, including in batches. Redeeming shares of another market reverts. Fuzz: a new market is fully collateralised (1000 runs). |
| `MarketReentrancy.t.sol` | 4 | Re-entry through a collateral token that calls the recipient after `transfer` (`HookToken`, `ReentrantActor`): `sell` into `sell`, `redeem` into `redeem`, `withdrawLiquidity` into itself and into `redeem`. Each asserts `ReentrancyGuardReentrantCall` and a single payout. |
| `MarketResolution.t.sol` | 21 | State machine by time alone (Open, Closed, Cancelled) and after `resolve`; only the arbitrator resolves, only while Closed, not at the deadline, not twice; the outcome never changes later. `redeem`: 1 USDC per winning share, losing shares burned, loser and double redeem revert, Cancelled pays half per share and rounds down. `withdrawLiquidity`: winning pool or half the pool to the creator, once, only after settlement. Fuzz: everyone exits and only dust remains (1000 runs). |
| `MarketTrading.t.sol` | 25 | Buy and sell quotes match execution, fee accounting, events, price moves for YES and NO. Slippage (`minShares`, `minOut`), deadline, approvals and balances, trading after close, zero amounts, a buy too small to cover the fee. Re-entry from the buyer's ERC-1155 hook (`CallbackBuyer`) and from a fee-token callback (`FeeCallbackToken`). Donated tokens do not change the pools. `withdrawFees`: only after close, only to each market's creator, fails cleanly and restores `accruedFees`. Fuzz: buy then sell cannot profit (1000 runs). |
| `OptimisticResolver.t.sol` | 32 | Constructor checks (zero bond, window not shorter than the resolution window). `propose`: pulls the bond, records the request, factory market only, this resolver must be the arbitrator, not while Open, not twice, not too late, needs approval. `dispute`: pulls the bond, only inside the window, needs a proposal, once, needs approval. `finalize` after an undisputed window; `rule` by the judge pays both bonds to the side it backs; `refund` after the market is cancelled returns the bonds. Every repeat or wrong-order call reverts. Two-step judge handover. A winner redeems after an undisputed proposal. |
| `OutcomeOrderBook.t.sol` | 38 | Secondary market for outcome shares. `list` escrows shares; `buy` fills cheapest first, oldest first at equal price, stops at `maxPrice` and `maxListings`, keeps partial fills in place, rounds each cost up, pays every seller exactly. `cancel` from the head, middle and tail, by the seller only, once. Price range and zero-argument reverts. `list` and `buy` only while Open, including one second before close, at close, after resolve and at the cancel deadline, while `cancel` always works. Markets from another factory or impersonating an id are refused. No over-fill or double sale. Re-entry from the buyer's ERC-1155 hook into `buy`, `cancel` and `list` is blocked. `quoteBuy` matches `buy`; `listingsOf` pages in order. A gas test (1 vs 10 listings), an AMM plus book plus resolve plus redeem flow, and a fuzz test of random actions that conserves shares and USDC (256 runs). |

### Contracts: `contracts/test/invariant/`

| File | Tests | What it covers |
|---|---|---|
| `SoothInvariants.t.sol` | 1 (forge counts the suite as 1 test) with 20 `invariant_*` functions | Setup: one factory, 4 real markets (2 with an EOA arbitrator, 2 with the `OptimisticResolver`), the order book, 5 traders, a whale, a donor and the judge. Invariants: collateral and supply (INV-COL-1, -2, -3, -5, -6), trading only while Open (INV-TIME-2), resolution (INV-RES-1, -2), redemption (INV-RED-1 to -4), bonds (INV-BND-1, -4, -5, -7) and the order book (INV-OB-1 to -4). `afterInvariant` ends each run by moving past every deadline, refunding open requests, cancelling every listing and letting every holder and the creator exit. It asserts that the resolver holds no bond after the refunds and that each exit pays its settlement value. |
| `HandlerBase.sol` | 0 (helper) | Wiring shared by both handlers: the forward-only `Clock` (one monotonic clock for handlers and invariant checks), the actor list, and helpers that pick an actor or outcome from a fuzzed seed. Its NatSpec sets the rule that handler checks never assert but bump a ghost counter. |
| `MarketHandler.sol` | 0 (helper) | Actions on markets and the order book: `buy`, `sell`, `roundTrip`, `list`, `bookBuy`, `cancel`, `transferShares`, `donateCollateral`, `donateShares`, `bulkDonateShares`, `warp`, `warpToEdge` (lands exactly on close and deadline), `resolve`, `redeem`, `withdrawLiquidity`, `withdrawFees`. Records deposits, payouts, fees and fills in ghost variables, and models each order-book fill before the call. |
| `ResolverHandler.sol` | 0 (helper) | Actions on the `OptimisticResolver`: `propose`, `dispute`, `finalize`, `rule`, `refund`, `donate`, `warpInWindow`, `warpToEdge` (lands on challenge-window edges). Tries payouts in every status and counts any success on the wrong one. |

### Bot: `bot/tests/`

| File | Tests | What it covers |
|---|---|---|
| `test_agent.py` | 20 (15 functions, some parametrised) | `ResolverAgent` with a scripted chat model and an in-memory site, no network and no tokens: YES with a verified quote; repeated runs must agree and each uses its own session; disagreement and the first `UNRESOLVABLE` stop the rest; invented and too-short quotes are rejected; whitespace in quotes is normalised; invalid tool arguments; the model stops without submitting; LLM errors; a spec without a source or with a dead source costs no tokens; the source is fetched once for all runs; same-site checks; the evidence URI round-trips. |
| `test_browser.py` | 5 | `BrowserPageFetcher` with real Chromium against pages served from localhost: inline tags stay in their sentence, hidden text and scripts are left out, text rendered by JavaScript is read, an off-site redirect is refused, an HTTP error is a `FetchError`. Skips itself when Chromium is missing. |
| `test_chainlink.py` | 163 (6 functions, parametrised; 15 skipped) | `round_at_close` (the bot's search for the Chainlink round live at a market's close) against an in-memory feed: latest round when nothing is later, a round updated exactly at close, the first round of a phase, close before the current phase, agreement with a linear scan for every close time, and a logarithmic number of reads. The 15 skips are parameter cases that `test_raises_when_close_is_before_current_phase` covers instead (reason printed by `-rs`). |

## 3. Testing strategy

- **Unit tests.** One behaviour per test, named `test_<Behaviour>` or `test_RevertWhen_<Condition>`. Reverts are checked with `vm.expectRevert` and the expected custom error. Time edges are tested at the exact second (`closeTime - 1`, `closeTime`, the deadline), because the market's state is derived from the clock.
- **Fuzz tests.** Single-sequence properties with fuzzed amounts: a buy then a sell cannot profit, a new market is fully collateralised, everyone can exit and only dust remains, and random order-book actions conserve shares and USDC.
- **Stateful invariant tests.** A handler contract per area (`MarketHandler`, `ResolverHandler`) with bounded inputs and several actors. Ghost variables track deposits, payouts, fees, bonds and order-book fills. Each `invariant_*` function checks one property from `invariants.md`. Handlers record violations in ghost counters instead of asserting, because with `fail_on_revert = false` a failed assert inside a handler would be swallowed as a revert. The clock only moves forward and lands exactly on close, deadline and challenge-window edges.
- **End-to-end tests.** Real contracts only (factory, `MockUSDC`, both resolvers, `MockAggregator`) through every resolution route, with expected balances from a separate Python model.
- **Re-entrancy tests.** Malicious receivers and tokens try to re-enter: ERC-1155 receive hooks on buyers (`CallbackBuyer`, `ReentrantBuyer`), and collateral tokens that call back after `transfer` (`FeeCallbackToken`, `HookToken` with `ReentrantActor`). Each test asserts the re-entry reverts and only one payout happens.
- **Mutation checks.** Done by hand: change one line of `src/`, run the tests, confirm they fail, then restore the file byte for byte.

| Area | Mutation | Result |
|---|---|---|
| End-to-end | `Market.FEE_BPS` 100 changed to 101 | All 9 end-to-end tests failed |
| Re-entrancy | `nonReentrant` removed from `redeem`, then `sell`, then `withdrawLiquidity` | 2, 1 and 2 tests failed |
| Order book | `nonReentrant` removed from `OutcomeOrderBook.buy`; `_requireOpen(market)` removed from `buy` | 3 re-entry tests failed; 3 open-state tests failed |
| Invariants | `_fee` returns 0 | `invariant_COL_3_feesAccountedApartFromBacking` failed |
| Invariants | `liquidityWithdrawn` check removed | Failed `invariant_RED_4_noDoubleClaims` and `invariant_COL_5_inventoryMatchesPools`, but only because the handler can donate pool-sized share amounts. Without the bulk-donation action the mutant survived (the pool burn already blocks a second withdrawal) |
| Invariants | `rule` pays `bond` instead of `2 * bond` | `invariant_BND_5_eachBondPaidOnce` and `invariant_BND_1_resolverHoldsExactlyOpenBonds` failed |
| Invariants | `_take` skips `listing.remaining -= fill` | `invariant_OB_1_escrowEqualsOpenListings` and `invariant_OB_4_buyersPayExactlyWhatSellersReceive` failed |
| Review (order book) | `touched < maxListings` changed to `<=` | Before the fix only `test_Buy_StopsAtMaxListings` failed; `test_Buy_PartialLastListingCountsAsTouched` passed although named for this. After the fix it fails: `stops after the one listing it may touch: 15000000 != 5000000` |
| Review (invariants) | `OptimisticResolver.refund` pays the disputer's bond to the proposer | Before the fix all 20 invariants passed (refund reached once per campaign). After the fix: `refund paid wrong amounts or someone gained or lost: 2 != 0` (`invariant_BND_4_refundMakesEveryoneWhole`) and `refund: proposer gets one bond: 20000000 != 10000000` (`afterInvariant`) |

- **Independent test reviews (2026-11-05).** Two fresh reviewer agents read every test added in PRs 1–3 against a checklist (name matches behaviour, real assertions, independent expected values, specific errors, nothing passes vacuously) and planted bugs to prove weak spots. No test was wrong; three were weak and are fixed (the last two mutation rows, and [AI log entry 9](ai/lin.md)). Not changed: two constant-only asserts in `EndToEnd._simpleTrades` (PR 1, already merged), and the order-book fuzz test does not check cost rounding (four unit tests do).
- **UI end-to-end test (local fork).** Base Sepolia forked with Anvil (as chain 31337, so MetaMask does not relay it to the real network), the order book deployed next to the real factory and mUSDC, and the website run locally against it. A Playwright script with a test-only injected wallet clicked through: connect, AMM buy, two listings (cheapest first), quote 7 YES for 4.40 USDC, buy, cancel, and the after-close view; all steps passed. The order-book history and listed positions were checked the same way, and Lin repeated the flow by hand in MetaMask. The script and patched site copy live outside the repo, so this is not part of CI.
- **Final mutation battery (2026-11-06).** A script planted 24 bugs one at a time in the exact code to be merged (`main` + PR 2 + PR 3, on a clean LF copy), checked each edit applied, ran the full suite, and restored the file byte for byte. **24/24 were caught.** Bugs covered: refund to the wrong person, judge pays the wrong side, finalize during the challenge window, resolver or order book accepting fake markets, anyone resolving, resolving outside `Closed`, missing reentrancy guards on `sell`, `redeem`, `list`, `buy` and `cancel`, double liquidity withdrawal, cancelled payout rounding up, no fee, a resolved market later reading as cancelled, AMM or order-book trading after close, touching one listing too many, cost rounding down, equal prices not oldest-first, escrow not reduced, filled listings left in the book, and anyone cancelling a listing. The fewest catches were 1 test (e.g. the guard on `sell`); the most were 17 (no fee).
- **Static analysis.** Slither on all of `src/`, every result triaged ([Security analysis](#security-analysis)).

## 4. Results (2026-11-08)

| Check | Result |
|---|---|
| `forge test` | `Ran 9 test suites in 25.46s (46.14s CPU time): 195 tests passed, 0 failed, 0 skipped (195 total tests)` |
| Invariant suite, default profile (inside `forge test`) | `SoothInvariantsTest invariants (runs: 64, calls: 4096, reverts: 0)`, passed |
| Invariant suite, `FOUNDRY_PROFILE=deep` (2026-11-04) | `SoothInvariantsTest invariants (runs: 512, calls: 65536, reverts: 0)`; `1 tests passed, 0 failed`; 461.05 s (7 min 43 s wall). Run in parallel with other forge and pytest commands, so the time is an upper bound |
| `forge coverage --report summary` | 195 passed. Lines and functions 100% for every production file in `src/`; branches 100% except `Market.sol` 93.75% (30/32). [Full table](#coverage) |
| Slither 0.11.6 (2026-11-04) | 23 results, 0 real issues (14 justified, 9 false positives). [Details](#security-analysis) |
| `forge build --sizes --skip './test/**' --skip './script/**'` | Exit 0; the largest `src/` contract is `Market` at 13,677 B. Without `--skip`: exit 1 on the test handler (section 1) |
| `forge fmt --check` | All 34 tracked `.sol` files formatted (checked on the committed LF content; a CRLF checkout fails, see section 1) |
| `uv run pytest -q -rs` (bot, 2026-11-04) | `173 passed, 15 skipped in 23.59s` |

## 5. Known gaps

From [`invariants.md`](invariants.md):

- INV-COL-8: cross-function re-entry pairs other than those listed in the row are not tested.
- INV-RED-5: `redeem` and `withdrawLiquidity` before settlement are tested in state `Closed` only; `Open` is not tested.
- INV-BND-5: a re-entrant bond-token callback is not tested.
- `OptimisticResolver` pushes bonds; a bond token that blocks a recipient makes that settlement revert. Not tested.
- Any other row marked "not tested yet" needs a single-call unit test.

From [`threat-model.md`](threat-model.md), section 8 "Missing evidence":

- Prompt-injection test against a real LLM (O-2).
- Test of a last-second proposal plus dispute, showing how little time the judge has (R-5, K-2).
- Re-entrant bond-token test for `OptimisticResolver` (C-4, INV-BND-5).
- Behaviour of the website's RPC when one `getLogs` range exceeds the provider's log limit (O-6).
- Order-book rows B-1 (gas growth on insert) and B-3 (seller blocked by USDC makes a fill revert) have no test.

From this run:

- `Market.sol` lines 218 and 224 (`ZeroOutput` reverts) are not covered. Line 218 looks unreachable ([Open follow-ups](#open-follow-ups), item 1).
- Deployment scripts (`script/*.s.sol`) have no tests.
- CI does not run Slither, coverage or the deep invariant profile.
- The website (`web/`) has no automated tests: `web/package.json` has no test script (only `dev`, `build`, `lint`, `preview`) and there are no test files in `web/src`.

## Security analysis

Coverage re-run on 2026-11-08 on the current code. Slither was run on 2026-11-04 (commit `3159dec`); `contracts/src` has not changed since except one comment in `IMarketFactory.sol`.

### Slither: setup

- Tool: Slither **0.11.6** (`slither-analyzer`, installed with pip in a venv outside the repo; `slither --version` printed `0.11.6`). Slither uses the Foundry build (forge 1.8.5, solc 0.8.28).
- Scope: every file in `contracts/src`, including `libraries/`, `interfaces/` and `mocks/`. Excluded: `lib/` (OpenZeppelin, forge-std), `test/`, `script/`. An earlier run that also filtered `src/mocks` gave the same count, so the mocks have no findings.

```
python -m venv <dir>/slither-venv
<dir>/slither-venv/Scripts/python -m pip install slither-analyzer solc-select   # bin/ instead of Scripts/ on Linux/macOS
export PATH="$HOME/.foundry/bin:$PATH"          # Slither calls forge
cd contracts
<dir>/slither-venv/Scripts/slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
# JSON report: add  --json <dir>/slither.json
forge build                                     # rebuild everything afterwards
```

Slither runs `forge clean` and then builds only `src/` (`--skip ./test/** ./script/**`), so run `forge build` or `forge test` afterwards. `out/` and `cache/` are git-ignored.

Slither exits non-zero whenever it has findings (0.11.6 defaults to `--fail-pedantic` and calls `sys.exit(-1)`), so a non-zero exit alone does not mean it failed. Check the line `analyzed (... contracts with 102 detectors), N result(s) found`. The exact value seen in Git Bash was 127, which there usually means "command not found"; this was not re-checked. A CI step would need `--fail-none` or a higher `--fail-*` level to pass with the accepted findings.

### Slither: result

Output line: `. analyzed (52 contracts with 102 detectors), 23 result(s) found`. The JSON report agrees: `success: true`, 23 entries.

- The first run (before the order book) printed `50 contracts`, `21 result(s)`. The two new contracts are `OutcomeOrderBook` and `IOutcomeOrderBook`, and the two new results are rows 22 and 23. Rows 1–21 are at the same files and lines, with the same decisions.
- An even earlier run reported 12 results. It could not be reproduced and the cause is unknown (a different Slither version, detector set or filters are possible, but none was checked). Here each timestamp and unused-return location is a separate result.
- No finding is a real, exploitable issue.

| Severity | Count | Rows |
|---|---|---|
| Medium | 6 | 1–5, 22 |
| Low | 12 | 6–17 |
| Informational | 5 | 18–21, 23 |

Decisions: fix 0, justify 14 (rows 6–8, 11–20, 23), false positive (FP) 9 (rows 1–5, 9, 10, 21, 22).

### Slither: findings

Severity and line numbers are Slither's. For the two order-book files Slither's line numbers are a few lines before the source line, so rows 22–23 give both.

| # | Detector | Location | Severity | Decision | Reason |
|---|---|---|---|---|---|
| 1 | reentrancy-no-eth | `Market.sell` (Market.sol 99-123): pools written via `_setPools` after `outcomeToken.safeTransferFrom` / `burnBatch` | Medium | FP | No attacker code runs in the window; see [below](#the-marketsell-finding). Test: `test_SellCollateralCallbackCannotReenterSell` |
| 2 | unused-return | `ChainlinkResolver._priceAtClose`, `config.feed.getRoundData(roundId)` (45-46) | Medium | FP | Only `answer` and `updatedAt` are needed; both are validated right after (`updatedAt == 0`, `> closeTime`, staleness, `answer <= 0`) |
| 3 | unused-return | `ChainlinkResolver._priceAtClose`, `config.feed.latestRoundData()` (50-52) | Medium | FP | Only `latestRoundId` is used, to detect a later round |
| 4 | unused-return | `ChainlinkResolver._nextRoundUpdatedAt`, `feed.getRoundData(roundId + 1)` (62-68) | Medium | FP | Only `updatedAt` is read; zero means "no such round" (NatSpec), and the code then tries the next phase |
| 5 | unused-return | `ChainlinkResolver._nextRoundUpdatedAt`, `feed.getRoundData(nextPhaseFirstRound)` (67) | Medium | FP | Same as 4. `updatedAt == 0` makes `nextUpdatedAt <= closeTime` false, so the round is correctly not superseded |
| 6 | events-maths | `Market.initialize` (51-76) writes `marketId`, `closeTime`, pools without an event | Low | Justify | Runs once, in the same transaction as `createMarket`, which emits `MarketCreated` with these values |
| 7 | missing-zero-check | `Market.constructor`, `factory_` (47-48) | Low | Justify | Only called by `MarketFactory` with `address(this)`; the factory rejects a zero collateral. Guards nothing reachable |
| 8 | missing-zero-check | `OutcomeToken.constructor`, `factory_` (21-24) | Low | Justify | Same: only deployed by the factory with `address(this)` |
| 9 | reentrancy-benign | `Market.sell`: `accruedFees += fee` after the external calls (99-123) | Low | FP | Same analysis and test as row 1 |
| 10 | reentrancy-events | `MarketFactory.createMarket` (46-84): `MarketCreated` after `registerMarket` and `initialize` | Low | FP | Both calls go to the factory's own `OutcomeToken` and the clone it just created; admin-only. Only an event follows |
| 11 | timestamp | `ChainlinkResolver.configure`, `block.timestamp >= market.closeTime()` (24-25) | Low | Justify | Intended: no configuration after close. Seconds of drift do not matter; owner-only |
| 12 | timestamp | `Market.state` (189-195) | Low | Justify | Time-based by design. Boundaries are exact and disjoint; the invariant suite lands on them (`warpToEdge`) and checks `invariant_TIME_2_tradingOnlyWhileOpen` |
| 13 | timestamp | `Market._requireTradable`, `deadline < block.timestamp` (275-281) | Low | Justify | User slippage deadline; `deadline == block.timestamp` is accepted. Standard pattern |
| 14 | timestamp | `MarketFactory._validate`, `p.closeTime <= block.timestamp` (84-99) | Low | Justify | Rejects a market that would start Closed. Admin-only |
| 15 | timestamp | `OptimisticResolver.propose`, `windowEnd >= deadline` (36-58) | Low | Justify | Strict on purpose: at the deadline the market is Cancelled, so such a proposal could never finalize |
| 16 | timestamp | `OptimisticResolver.dispute`, `block.timestamp >= windowEnd` (58-69) | Low | Justify | Dispute only while `t < windowEnd`, `finalize` only at `t >= windowEnd`: no overlap |
| 17 | timestamp | `OptimisticResolver.finalize`, `block.timestamp < windowEnd` (69-81) | Low | Justify | See 16. The window is hours or days; seconds of drift are irrelevant |
| 18 | naming-convention | `IMarket.FEE_BPS()` (IMarket.sol 108-109) | Informational | Justify | Mirrors the public `constant` getter in `Market`; renaming changes the public interface (tests, bot, web use it) |
| 19 | naming-convention | `IMarket.RESOLUTION_WINDOW()` (109-110) | Informational | Justify | Same as 18 |
| 20 | naming-convention | `IMarketFactory.MIN_LIQUIDITY()` (IMarketFactory.sol 51-52) | Informational | Justify | Same as 18 |
| 21 | unimplemented-functions | `OutcomeToken` does not implement `IOutcomeToken.totalSupply(uint256)` (12-67) | Informational | FP | It does: `totalSupply(uint256 id) public view override(ERC1155Supply, IOutcomeToken)`. Slither is confused by the double override. `forge inspect OutcomeToken methodIdentifiers` lists `totalSupply(uint256)` -> `bd85b039`, and `invariant_COL_1_yesSupplyEqualsNoSupplyBeforeExits` calls it on every run |
| 22 | uninitialized-local | `OutcomeOrderBook.listingsOf`, local `uint256 n;` (Slither: 144-145; source line 149) | Medium | FP | A value-type local is always zero when declared; `n` is a counter that starts at 0 by intent. View function, holds no funds. `test_ListingsOfPagesInOrder` checks the paging. `uint256 n = 0;` would silence it with no change in behaviour |
| 23 | naming-convention | `IOutcomeOrderBook.PRICE_SCALE()` (Slither: 83; source line 85) | Informational | Justify | Same as 18: mirrors `uint256 public constant PRICE_SCALE = 1e6` in `OutcomeOrderBook` |

### The `Market.sell` finding

Slither reports state writes after external calls in `sell` (order: quote, `outcomeToken.safeTransferFrom(msg.sender, this, ...)`, `outcomeToken.burnBatch(this, ...)`, then `_setPools`, `accruedFees += fee`, `collateral.safeTransfer(msg.sender, collateralOut)`, event). It is a false positive:

1. `outcomeToken` is `immutable`, set in the `Market` constructor by the `MarketFactory` that deployed it. It is not user-supplied.
2. ERC-1155 `safeTransferFrom` calls `onERC1155Received` on `to`, which is the market itself (OZ `ERC1155Holder`, no state change). `from` is never called back. `burnBatch` makes no receiver call.
3. `sell` has `nonReentrant` (`ReentrancyGuardTransient`), shared with `buy`, `redeem`, `withdrawFees` and `withdrawLiquidity`. The unguarded external functions are `initialize` (`initializer`, factory only), `resolve` (arbitrator only, needs Closed while `sell` needs Open) and views.
4. The last transfer, `collateral.safeTransfer`, comes after the state updates, and the collateral is the factory's fixed 6-decimal token.

In `buy`, `outcomeToken.safeTransferFrom(this, msg.sender, ...)` does call the buyer's `onERC1155Received`. Slither does not flag it because pools and fees are written first; the lock blocks re-entry. `CallbackBuyer` in `test/MarketTrading.t.sol` tries this and is blocked. The collateral-callback paths are covered by `test/MarketReentrancy.t.sol` (`HookToken`), and the mutation checks in section 3 show those tests fail without the guards.

### Order book: checked by hand

Slither reported only rows 22 and 23 for `OutcomeOrderBook`. Its external calls were also read by hand. No exploitable issue was found.

- **User-supplied `market`.** `list`, `buy` and `quoteBuy` call `market.marketId()` and `market.state()` before they know the market is real. Both are `view` in `IMarket`, so they use `STATICCALL` and a fake market cannot change state. `_requireFactoryMarket` then requires `factory.markets(market.marketId()) == address(market)`. Tests: `test_RevertWhen_MarketFromAnotherFactory`, `test_RevertWhen_MarketImpersonatesFactoryId`.
- **Seller payments in a loop.** `buy` calls `collateral.safeTransferFrom(buyer, seller, cost)` once per filled listing (`_take`). `collateral` is the checked market's collateral, not a user token. Each listing is updated before its payment, and `maxListings` caps the calls. Residual risk: a seller blocked by USDC makes fills that reach that listing revert until the seller cancels (threat B-3 in [`threat-model.md`](threat-model.md)).
- **ERC-1155 hooks.** `list` pulls shares into the book (an `ERC1155Holder`, so no outside hook runs). `buy` and `cancel` send shares to the caller last, after all state changes. All three share one `nonReentrant` lock. Tests: `test_RevertWhen_ReenteringBuyFromReceiver`, `test_RevertWhen_ReenteringCancelFromReceiver`, `test_RevertWhen_ReenteringListFromReceiver`.
- **Escrow accounting.** Checked over random sequences by `invariant_OB_1_escrowEqualsOpenListings`, `invariant_OB_3_bookHoldsNoCollateral` and `invariant_OB_4_buyersPayExactlyWhatSellersReceive`.

### Coverage

Command: `forge coverage --report summary`, with `--report lcov` in the same call for uncovered lines. The run includes the invariant suite and ends with `Ran 9 test suites in 42.84s (54.43s CPU time): 195 tests passed, 0 failed, 0 skipped (195 total tests)`. Table as printed:

| File | % Lines | % Statements | % Branches | % Funcs |
|------|---------|--------------|------------|---------|
| script/CreateMarket.s.sol | 0.00% (0/23) | 0.00% (0/31) | 0.00% (0/7) | 0.00% (0/3) |
| script/DeployChainlinkResolver.s.sol | 0.00% (0/8) | 0.00% (0/8) | 0.00% (0/2) | 0.00% (0/1) |
| script/DeployMarketFactory.s.sol | 0.00% (0/16) | 0.00% (0/23) | 0.00% (0/5) | 0.00% (0/2) |
| script/DeployOptimisticResolver.s.sol | 0.00% (0/13) | 0.00% (0/15) | 0.00% (0/2) | 0.00% (0/1) |
| script/DeployOrderBook.s.sol | 0.00% (0/8) | 0.00% (0/8) | N/A (0/0) | 0.00% (0/1) |
| script/ResolveChainlinkMarket.s.sol | 0.00% (0/25) | 0.00% (0/36) | 0.00% (0/10) | 0.00% (0/2) |
| src/ChainlinkResolver.sol | 100.00% (36/36) | 100.00% (55/55) | 100.00% (15/15) | 100.00% (7/7) |
| src/Market.sol | 100.00% (152/152) | 98.92% (184/186) | 93.75% (30/32) | 100.00% (27/27) |
| src/MarketFactory.sol | 100.00% (26/26) | 100.00% (34/34) | 100.00% (7/7) | 100.00% (3/3) |
| src/OptimisticResolver.sol | 100.00% (62/62) | 100.00% (85/85) | 100.00% (17/17) | 100.00% (9/9) |
| src/OutcomeOrderBook.sol | 100.00% (118/118) | 100.00% (151/151) | 100.00% (27/27) | 100.00% (17/17) |
| src/OutcomeToken.sol | 100.00% (28/28) | 100.00% (29/29) | 100.00% (3/3) | 100.00% (9/9) |
| src/libraries/OutcomeTokenId.sol | 100.00% (2/2) | 100.00% (1/1) | N/A (0/0) | 100.00% (1/1) |
| src/mocks/MockAggregator.sol | 57.14% (8/14) | 70.00% (7/10) | 100.00% (1/1) | 50.00% (3/6) |
| src/mocks/MockUSDC.sol | 100.00% (5/5) | 100.00% (2/2) | N/A (0/0) | 100.00% (3/3) |
| test/MarketFactory.t.sol | 100.00% (3/3) | 100.00% (1/1) | N/A (0/0) | 100.00% (2/2) |
| test/MarketReentrancy.t.sol | 97.62% (41/42) | 97.50% (39/40) | 90.00% (9/10) | 100.00% (12/12) |
| test/MarketTrading.t.sol | 76.92% (20/26) | 66.67% (14/21) | 100.00% (5/5) | 71.43% (5/7) |
| test/OutcomeOrderBook.t.sol | 100.00% (30/30) | 100.00% (29/29) | 100.00% (5/5) | 100.00% (7/7) |
| test/invariant/HandlerBase.sol | 92.86% (26/28) | 96.30% (26/27) | 100.00% (3/3) | 90.00% (9/10) |
| test/invariant/MarketHandler.sol | 94.21% (293/311) | 91.22% (426/467) | 63.53% (54/85) | 96.67% (29/30) |
| test/invariant/ResolverHandler.sol | 97.44% (114/117) | 91.76% (167/182) | 60.98% (25/41) | 100.00% (13/13) |
| **Total** | **88.20% (964/1093)** | **86.75% (1250/1441)** | **72.56% (201/277)** | **90.17% (156/173)** |

The Total row includes scripts and test helpers, so it does not measure the production code. In the first run (137 tests, before the order book, re-entrancy and invariant tests), `src/Market.sol` had statements 98.39% (183/186) and branches 90.62% (29/32); the other existing `src/` rows are unchanged. Without the invariant suite (`--no-match-path 'test/invariant/*'`, 194 tests) `src/Market.sol` drops back to those numbers, and `src/OutcomeOrderBook.sol` stays at 100% from its unit tests alone.

Uncovered code (lcov entries with zero hits):

- `src/Market.sol`, 2 of 32 branches (also the 2 uncovered statements), both revert branches:
  - line 218, `_quoteBuy`: `if (sharesOut == 0) revert ZeroOutput();`
  - line 224, `_quoteSell`: `if (oppositePool <= 1) revert ZeroOutput();`
  - Line 238, `_quoteSell` `if (collateralOut == 0) revert ZeroOutput();`, is covered by the invariant suite only.
- `src/mocks/MockAggregator.sol`: `decimals()`, `description()`, `version()` (lines 23-32) are interface filler, never called.
- `script/*.s.sol`: deployment scripts, not run by `forge test`.
- Test helper files: uncovered lines are helper code (for example `CallbackBuyer.onERC1155BatchReceived` and `supportsInterface`) and handler branches that only run for some random sequences.

### Open follow-ups

No Slither finding needs a fix in `src/`. Open items:

1. **Two uncovered revert branches in `Market.sol` (test gap, no code change).**
   - Line 218 (`sharesOut == 0`) looks unreachable, by reading the code (not tested): `outcomePoolAfter = ceil(outcomePool * oppositePool / (oppositePool + net))`. With `net >= 1` the exact quotient is below `outcomePool`, so its ceiling is at most `outcomePool`, and `sharesOut = outcomePool + net - outcomePoolAfter >= net >= 1`. It is a defensive check.
   - Line 224 (`oppositePool <= 1`): a sell can leave the opposite pool at exactly 1 (it removes at most `oppositePool - 1`), so a following sell would take this branch. No test builds that state; it needs a very large sell against a small pool.
2. **Optional hardening.** Zero-address checks in the `Market` and `OutcomeToken` constructors (rows 7–8). Not reachable today; constructor change only, no interface change.
3. **Optional, for Slither in CI.** Suppress the documented false positives (rows 1, 9, 10, 21, 22) with `// slither-disable-next-line` or a `slither.config.json`, so a later run shows only new findings, and use `--fail-none` (or a level above the accepted findings).
4. **Needs a team decision.** `withdrawFees` is allowed in a Cancelled market, so the creator keeps fees even when traders are settled at 50/50 (documented in [`market-creation-explained.md`](market-creation-explained.md)). Other documented shortcuts also stay open: no L2 sequencer check in `ChainlinkResolver`, pushed bonds in `OptimisticResolver`.
