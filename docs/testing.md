# Testing (task P3-6)

How to run every test, what each test file covers, how we test and what is still missing. Written for P3-6 on branch `lin/docs/testing`, cut from `origin/lin/integration` at `3159dec`, on 2026-11-04. Every command below was run on that commit on Windows 11 (Git Bash), except creating the Slither venv and installing Slither: the venv made for P1-4 was reused (Slither 0.11.6). Every number is copied from those runs unless the text names another source. Security tooling details are in [`security-analysis.md`](security-analysis.md). The properties the tests check are listed in [`invariants.md`](invariants.md).

## 1. How to run

### Contracts (`contracts/`, Foundry)

Tools: Foundry forge 1.8.5 (the version CI pins), solc 0.8.28 (set in `foundry.toml`). Clone with submodules (`git submodule update --init --recursive`), because OpenZeppelin and forge-std live in `contracts/lib/`.

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

Invariant tests (`test/invariant/`) run in every `forge test`. The settings are in `foundry.toml`:

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

`--ir-minimum` is not needed: there is no stack-too-deep error. The full coverage run took 49.8 s here. The deep invariant profile took about 7.5 minutes.

Slither (not in CI; install it in a virtual environment outside the repo):

```
python -m venv <dir>/slither-venv
<dir>/slither-venv/Scripts/python -m pip install slither-analyzer solc-select   # bin/ instead of Scripts/ on Linux/macOS
export PATH="$HOME/.foundry/bin:$PATH"          # Slither calls forge
cd contracts
<dir>/slither-venv/Scripts/slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
forge build                                     # Slither ran forge clean and built only src/
```

Slither exits non-zero whenever it has findings (its default is `--fail-pedantic`), so a non-zero exit code alone does not mean it failed. Check the line `analyzed (... contracts with 102 detectors), N result(s) found`.

Two warnings for this commit:

- **`forge build --sizes` exits 1.** It prints `Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)` because the test handler `MarketHandler` (`test/invariant/MarketHandler.sol`) is 34,326 bytes. All `src/` contracts are under the limit, and `forge build --sizes --skip './test/**' --skip './script/**'` exits 0. Fixed on 2026-11-04 (branch `lin/fix/ci-size-check`, AI log entry 8): CI now runs the `--skip` form, so only deployable contracts are size-checked; `forge test` still builds and runs every test.
- **`forge fmt --check` on a Windows checkout.** With `core.autocrlf=true`, Git writes files with CRLF line endings and `forge fmt --check` reports every file (exit 1), although the committed files are formatted. Check the committed content instead: `git show HEAD:contracts/<file> | forge fmt --check -`. That passed for all 34 tracked `.sol` files. CI checks out with LF and is not affected.

### Bot (`bot/`, Python)

Tools: [uv](https://docs.astral.sh/uv/) (0.13.7 was used here). The test suite needs no network, no API keys and no RPC.

```
cd bot
uv sync --locked                       # create .venv from uv.lock
uv run playwright install chromium     # browser for tests/test_browser.py
uv run pytest -rs                      # all tests, print the reason for each skip
uv run pytest -q tests/test_agent.py   # one file
```

`tests/test_browser.py` skips itself when Chromium is missing. CI treats that skip as a failure (see below).

### CI (`.github/workflows/ci.yml`)

Runs on pull requests and pushes to `main`, and by hand (`workflow_dispatch`). Read-only permissions, no secrets. A newer push to the same branch cancels the older run.

| Job | Steps |
|---|---|
| Contracts (fmt, build, test) | `actions/checkout@v5` with submodules (recursive); `foundry-rs/foundry-toolchain@v1` pinned to forge v1.8.5; `forge fmt --check`; `forge build --sizes --skip './test/**' --skip './script/**'`; `forge test -vvv` |
| Bot (pytest) | `actions/checkout@v5`; `astral-sh/setup-uv@v6` (cache keyed on `bot/uv.lock`); `uv sync --locked`; `uv run playwright install --with-deps chromium`; `uv run pytest -rs`, then fails the job if the log contains "Chromium not installed" |

CI does not run Slither, coverage or the deep invariant profile. Those are run by hand and recorded in `security-analysis.md` and the project log.

## 2. Test files

Counts are from `forge test --summary` and `uv run pytest --collect-only -q` on `3159dec`.

### Contracts: `contracts/test/*.t.sol`

| File | Tests | What it covers |
|---|---|---|
| `ChainlinkResolver.t.sol` | 28 | Owner-only `configure` and its checks (zero feed, zero staleness, wrong arbitrator, twice, after close). Price rules `Below`/`Above` including ties. Picking the round live at `closeTime`: exact-at-close, latest round, last round before a phase upgrade, superseded rounds (same and next phase), missing rounds. Staleness edge, non-positive price, resolving before close, after the deadline, twice. A winner redeems after resolution. Uses `MockAggregator`. |
| `EndToEnd.t.sol` | 9 | Full lifecycle with the real factory, `MockUSDC`, both resolvers and `MockAggregator`, one test per resolution route: direct YES and NO (E2E-1, E2E-2), Chainlink above/below/tie (E2E-3), optimistic undisputed (E2E-4), disputed with the judge upholding (E2E-5) or overturning (E2E-6), timeout cancel and refund (E2E-7), disputed or proposed-only requests left open and refunded (E2E-8, E2E-8b). Every test asserts every actor's final balance, against values computed beforehand with a separate Python model, and calls `_assertConserved()`: USDC summed over 11 actors and contracts plus all markets equals what was minted. |
| `MarketFactory.t.sol` | 37 | `createMarket`: stored parameters, event, ids from 1, collateral moved and pools seeded at 50/50, unique token ids, exact minimums. Admin role, collateral approval, every validation revert (zero arbitrator, close time in the past or now, not 50/50, low liquidity, empty spec, bad config, collateral without 6 decimals). Clone and implementation cannot be initialised again. `OutcomeToken` access control: only the factory registers, only a market mints or burns its own ids, including in batches. Redeeming shares of another market reverts. Fuzz: a new market is fully collateralised (1000 runs). |
| `MarketReentrancy.t.sol` | 4 | Re-entry through a collateral token that calls the recipient after `transfer` (`HookToken`, `ReentrantActor`): `sell` into `sell`, `redeem` into `redeem`, `withdrawLiquidity` into itself and into `redeem`. Each asserts `ReentrancyGuardReentrantCall` and that only one payout happened (task P1-6). |
| `MarketResolution.t.sol` | 21 | State machine by time alone (Open, Closed, Cancelled) and after `resolve`; only the arbitrator resolves, only while Closed, not at the deadline, not twice; the outcome never changes later. `redeem`: 1 USDC per winning share, losing shares burned, loser and double redeem revert, Cancelled pays half per share and rounds down. `withdrawLiquidity`: winning pool or half the pool to the creator, once, only after settlement. Fuzz: everyone exits and only dust remains (1000 runs). |
| `MarketTrading.t.sol` | 25 | Buy and sell quotes match execution, fee accounting, events, price moves for YES and NO. Slippage (`minShares`, `minOut`), deadline, approvals and balances, trading after close, zero amounts, a buy too small to cover the fee. Re-entry from the buyer's ERC-1155 hook (`CallbackBuyer`) and from a fee-token callback (`FeeCallbackToken`). Donated tokens do not change the pools. `withdrawFees`: only after close, only to each market's creator, fails cleanly and restores `accruedFees`. Fuzz: buy then sell cannot profit (1000 runs). |
| `OptimisticResolver.t.sol` | 32 | Constructor checks (zero bond, window not shorter than the resolution window). `propose`: pulls the bond, records the request, factory market only, this resolver must be the arbitrator, not while Open, not twice, not too late, needs approval. `dispute`: pulls the bond, only inside the window, needs a proposal, once, needs approval. `finalize` after an undisputed window; `rule` by the judge pays both bonds to the side it backs; `refund` after the market is cancelled returns the bonds. Every repeat or wrong-order call reverts. Two-step judge handover. A winner redeems after an undisputed proposal. |
| `OutcomeOrderBook.t.sol` | 38 | Secondary market for outcome shares (task P2-5, plan tests OB-1 to OB-18). `list` escrows shares; `buy` fills cheapest first, oldest first at equal price, stops at `maxPrice` and `maxListings`, keeps partial fills in place, rounds each cost up, pays every seller exactly. `cancel` from the head, middle and tail, by the seller only, once. Price range and zero-argument reverts. `list` and `buy` only while Open, including one second before close, at close, after resolve and at the cancel deadline, while `cancel` always works. Markets from another factory or impersonating an id are refused. No over-fill or double sale. Re-entry from the buyer's ERC-1155 hook into `buy`, `cancel` and `list` is blocked. `quoteBuy` matches `buy`; `listingsOf` pages in order. A gas test (1 vs 10 listings), an AMM plus book plus resolve plus redeem flow, and a fuzz test of random actions that conserves shares and USDC (256 runs). |

### Contracts: `contracts/test/invariant/`

| File | Tests | What it covers |
|---|---|---|
| `SoothInvariants.t.sol` | 1 (forge counts the suite as 1 test) with 20 `invariant_*` functions | Stateful invariant suite (task P1-2). Setup: one factory, 4 real markets (2 with an EOA arbitrator, 2 with the `OptimisticResolver`), the order book, 5 traders, a whale, a donor and the judge. Invariants: collateral and supply (INV-COL-1, -2, -3, -5, -6), trading only while Open (INV-TIME-2), resolution (INV-RES-1, -2), redemption (INV-RED-1 to -4), bonds (INV-BND-1, -4, -5, -7) and the order book (INV-OB-1 to -4). `afterInvariant` ends each run by moving past every deadline, refunding open requests, cancelling every listing and letting every holder and the creator exit. It asserts that the resolver holds no bond after the refunds and that each exit pays its settlement value. |
| `HandlerBase.sol` | 0 (helper) | Wiring shared by both handlers: the forward-only `Clock` (one monotonic clock for handlers and invariant checks), the actor list and helpers that pick an actor or outcome from a fuzzed seed. Its NatSpec sets the rule that handler checks never assert but bump a ghost counter. |
| `MarketHandler.sol` | 0 (helper) | Actions on markets and the order book: `buy`, `sell`, `roundTrip`, `list`, `bookBuy`, `cancel`, `transferShares`, `donateCollateral`, `donateShares`, `bulkDonateShares`, `warp`, `warpToEdge` (lands exactly on close and deadline), `resolve`, `redeem`, `withdrawLiquidity`, `withdrawFees`. Records deposits, payouts, fees and fills in ghost variables, and models each order-book fill before the call. |
| `ResolverHandler.sol` | 0 (helper) | Actions on the `OptimisticResolver`: `propose`, `dispute`, `finalize`, `rule`, `refund`, `donate`, `warpInWindow`, `warpToEdge` (lands on challenge-window edges). Tries payouts in every status and counts any success on the wrong one. |

### Bot: `bot/tests/`

| File | Tests | What it covers |
|---|---|---|
| `test_agent.py` | 20 (15 functions, some parametrised) | `ResolverAgent` with a scripted chat model and an in-memory site, no network and no tokens: YES with a verified quote; repeated runs must agree and each uses its own session; disagreement and the first `UNRESOLVABLE` stop the rest; invented and too-short quotes are rejected; whitespace in quotes is normalised; invalid tool arguments; the model stops without submitting; LLM errors; a spec without a source or with a dead source costs no tokens; the source is fetched once for all runs; same-site checks; the evidence URI round-trips. |
| `test_browser.py` | 5 | `BrowserPageFetcher` with real Chromium against pages served from localhost: inline tags stay in their sentence, hidden text and scripts are left out, text rendered by JavaScript is read, an off-site redirect is refused, an HTTP error is a `FetchError`. Skips itself when Chromium is missing. |
| `test_chainlink.py` | 163 (6 functions, parametrised; 15 skipped) | `round_at_close` (the bot's search for the Chainlink round live at a market's close) against an in-memory feed: latest round when nothing is later, a round updated exactly at close, the first round of a phase, close before the current phase, agreement with a linear scan for every close time, and a logarithmic number of reads. The 15 skips are parameter cases that `test_raises_when_close_is_before_current_phase` covers instead (skip reason printed by `-rs`). |

## 3. Testing strategy

- **Unit tests.** One behaviour per test, named `test_<Behaviour>` or `test_RevertWhen_<Condition>`. Reverts are checked with `vm.expectRevert` and the expected custom error. Time edges are tested at the exact second (`closeTime - 1`, `closeTime`, the deadline), because the market's state is derived from the clock.
- **Fuzz tests.** Single-sequence properties with fuzzed amounts: a buy then a sell cannot profit, a new market is fully collateralised, everyone can exit and only dust remains, and random order-book actions conserve shares and USDC.
- **Stateful invariant tests.** A handler contract per area (`MarketHandler`, `ResolverHandler`) with bounded inputs and several actors. Ghost variables track deposits, payouts, fees, bonds and order-book fills. Each `invariant_*` function checks one property from `invariants.md`. Handlers record violations in ghost counters instead of asserting, because with `fail_on_revert = false` a failed assert inside a handler would be swallowed as a revert. The clock only moves forward and lands exactly on close, deadline and challenge-window edges.
- **End-to-end tests.** Real contracts only (factory, `MockUSDC`, both resolvers, `MockAggregator`) through every resolution route. Expected balances come from a separate Python model, and every actor's final balance is asserted.
- **Re-entrancy tests.** Malicious receivers and tokens try to re-enter: ERC-1155 receive hooks on buyers (`CallbackBuyer`, `ReentrantBuyer`), and collateral tokens that call back after `transfer` (`FeeCallbackToken`, `HookToken` with `ReentrantActor`). Each test asserts the re-entry reverts and only one payout happens.
- **Mutation checks.** Done by hand: change one line of `src/`, run the tests, confirm they fail, then restore the file byte for byte. Results recorded in the project log (`actions.md`):

| Task | Mutation | Result | Log row |
|---|---|---|---|
| P1-3 (end-to-end) | `Market.FEE_BPS` 100 changed to 101 | All 9 end-to-end tests failed | S6-12 |
| P1-6 (re-entrancy) | `nonReentrant` removed from `redeem`, then `sell`, then `withdrawLiquidity` | 2, 1 and 2 tests failed | S7-14 |
| P2-5 (order book) | `nonReentrant` removed from `OutcomeOrderBook.buy`; `_requireOpen(market)` removed from `buy` | 3 re-entry tests failed; 3 open-state tests failed | S7-45 |
| P1-2 (invariants) | `_fee` returns 0 | `invariant_COL_3_feesAccountedApartFromBacking` failed | S7-62 |
| P1-2 | `liquidityWithdrawn` check removed | Failed `invariant_RED_4_noDoubleClaims` and `invariant_COL_5_inventoryMatchesPools`, but only because the handler can donate pool-sized share amounts. Without the bulk-donation action the mutant survived (the pool burn already blocks a second withdrawal) | S7-63 |
| P1-2 | `rule` pays `bond` instead of `2 * bond` | `invariant_BND_5_eachBondPaidOnce` and `invariant_BND_1_resolverHoldsExactlyOpenBonds` failed | S7-64 |
| P1-2 | `_take` skips `listing.remaining -= fill` | `invariant_OB_1_escrowEqualsOpenListings` and `invariant_OB_4_...` failed | S7-65 |
| Review (order book) | `touched < maxListings` changed to `<=` | Before the fix only `test_Buy_StopsAtMaxListings` failed; `test_Buy_PartialLastListingCountsAsTouched` passed although named for this. After the fix it fails: `stops after the one listing it may touch: 15000000 != 5000000` | S7-119, S7-124 |
| Review (invariants) | `OptimisticResolver.refund` pays the disputer's bond to the proposer | Before the fix all 20 invariants passed (refund reached once per campaign). After the fix: `refund paid wrong amounts or someone gained or lost: 2 != 0` (`invariant_BND_4`) and `refund: proposer gets one bond: 20000000 != 10000000` (`afterInvariant`) | S7-122, S7-125 |

- **Independent test reviews (2026-11-05).** Two fresh reviewer agents read every test added in PRs 1–3 against a checklist (name matches behaviour, real assertions, independent expected values, specific errors, nothing passes vacuously) and planted bugs to prove weak spots. No test was wrong; three were weak and are fixed (see the last two mutation rows, and `ai/lin.md` entry 9). Not changed: two constant-only asserts in `EndToEnd._simpleTrades` (PR 1, already merged) and the order-book fuzz test not checking cost rounding (four unit tests do).
- **UI end-to-end test (local fork).** Base Sepolia forked with Anvil (as chain 31337, so MetaMask does not relay it to the real network), the order book deployed next to the real factory and mUSDC, and the website run locally against it. A Playwright script with a test-only injected wallet clicked through: connect, AMM buy, two listings (cheapest first), quote 7 YES for 4.40 USDC, buy, cancel, and the after-close view (U1–U8, all pass, `actions.md` S7-121). The order-book history and listed positions were checked the same way (H1–H5, L1–L7; S7-124, S7-128), and Lin repeated the flow by hand in MetaMask. The script and patched site copy live outside the repo, so this is not part of CI.
- **Final mutation battery (2026-11-06).** A script planted 24 bugs one at a time in the exact code to be merged (`main` + PR 2 + PR 3, on a clean LF copy), checked each edit applied, ran the full suite, and restored the file byte for byte. **24/24 were caught.** Bugs covered: refund to the wrong person, judge pays the wrong side, finalize during the challenge window, resolver or order book accepting fake markets, anyone resolving, resolving outside `Closed`, missing reentrancy guards on `sell`, `redeem`, `list`, `buy` and `cancel`, double liquidity withdrawal, cancelled payout rounding up, no fee, a resolved market later reading as cancelled, AMM or order-book trading after close, touching one listing too many, cost rounding down, equal prices not oldest-first, escrow not reduced, filled listings left in the book, and anyone cancelling a listing. The fewest catches were 1 test (e.g. the guard on `sell`); the most were 17 (no fee). Log row S7-131.
- **Static analysis.** Slither 0.11.6 on all of `src/`, every result triaged (`security-analysis.md`). Run by hand, not in CI.
- **CI.** Formatting, build and the full test suite (contracts and bot) on every pull request and push to `main`.

## 4. Results (2026-11-04, commit `3159dec`)

| Check | Result |
|---|---|
| `forge test` | `Ran 9 test suites in 26.85s (43.14s CPU time): 195 tests passed, 0 failed, 0 skipped (195 total tests)` |
| Invariant suite, default profile (inside `forge test`) | `SoothInvariantsTest invariants (runs: 64, calls: 4096, reverts: 0)`, passed |
| Invariant suite, `FOUNDRY_PROFILE=deep` | `SoothInvariantsTest invariants (runs: 512, calls: 65536, reverts: 0)`; `1 tests passed, 0 failed`; 461.05 s (7 min 43 s wall). Run in parallel with other forge and pytest commands, so the time is an upper bound |
| `forge coverage --report summary` | 195 passed. Lines and functions 100% for every production file in `src/` (`ChainlinkResolver`, `Market`, `MarketFactory`, `OptimisticResolver`, `OutcomeOrderBook`, `OutcomeToken`, `OutcomeTokenId`). Branches 100% except `Market.sol` 93.75% (30/32). Total row including scripts and test helpers: lines 88.26% (970/1099), branches 71.84% (199/277). Full table in `security-analysis.md`, section 3 |
| Slither 0.11.6 | `. analyzed (52 contracts with 102 detectors), 23 result(s) found`; 0 real issues (14 justified, 9 false positives), 2 new since P1-4 (both in the order book) |
| `forge build --sizes` | Exit 1: test helper `MarketHandler` is over the EIP-170 size limit; all `src/` contracts are under it. Fixed since: CI runs `forge build --sizes --skip './test/**' --skip './script/**'` (exit 0) |
| `forge fmt --check` | All 34 tracked `.sol` files formatted (checked on the committed LF content; a CRLF checkout fails, see section 1) |
| `uv run pytest -q -rs` (bot) | `173 passed, 15 skipped in 23.59s` |

## 5. Known gaps

From [`invariants.md`](invariants.md) (rows or notes that say a part is not tested):

- INV-COL-8: cross-function re-entry pairs other than those listed in the row are not tested.
- INV-RED-5: `redeem` and `withdrawLiquidity` before settlement are tested in state `Closed` only; `Open` is not tested.
- INV-BND-5: a re-entrant bond-token callback is not tested.
- `OptimisticResolver` pushes bonds; a bond token that blocks a recipient makes that settlement revert. Not tested ("Known gaps in the documented behaviour").
- The document's "Rows task P1-2 must cover" are all done; any other row marked "not tested yet" needs a single-call unit test.

From [`threat-model.md`](threat-model.md), section 8 "Missing evidence", and the order book section:

- Prompt-injection test against a real LLM (O-2).
- Test of a last-second proposal plus dispute, showing how little time the judge has (R-5, K-2).
- Re-entrant bond-token test for `OptimisticResolver` (C-4, INV-BND-5).
- Test showing donated outcome tokens stay after `withdrawLiquidity` (K-6). The invariant suite now checks that only donated shares remain after `withdrawLiquidity` (`invariant_COL_5_inventoryMatchesPools`, see `invariants.md`); the threat model has not been updated to cite it.
- Behaviour of the website's RPC when one `getLogs` range exceeds the provider's log limit (O-6).
- Order-book rows B-1 (gas growth on insert) and B-3 (seller blocked by USDC makes a fill revert) have no test. The threat model's order book section still says the order book is not merged; it has been merged with its tests since (P2-5).

From this run:

- `Market.sol` lines 218 and 224 (`ZeroOutput` reverts) are not covered. Line 218 looks unreachable (`security-analysis.md`, section 2 item 1).
- Deployment scripts (`script/*.s.sol`) have no tests.
- CI does not run Slither, coverage or the deep invariant profile.
- `forge build --sizes` fails on the test handler size (section 1).
- The website (`web/`) has no automated tests: `web/package.json` has no test script (only `dev`, `build`, `lint`, `preview`) and there are no test files in `web/src`.
