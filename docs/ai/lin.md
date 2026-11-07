# AI audit log: Lin

AI mistakes from Lin's sessions with Claude Code. Rules and format: [`README.md`](README.md).

Sources: the AI's change log (kept outside this repo), the Claude Code session transcripts (the source of the quoted prompts) and git history. Times are local (UTC+8) unless marked UTC. Transcripts show both Claude Opus and Claude Sonnet models; the 2026-11-03 orchestrator rounds ran almost entirely on Sonnet ([`ai-audit-report.md`](../ai-audit-report.md), issue 13).

| # | Title | Type | Status |
|---|---|---|---|
| 1 | `vm.prank` used up by a view call in a redeem test | Test bug | Fixed |
| 2 | `forge fmt` on the whole repo rewrote 7 teammate files | Tool misuse | Fixed (reverted, spec updated) |
| 3 | Slither `reentrancy-no-eth` in `Market.sell` judged not exploitable | Evaluation | Judged false positive; test added |
| 4 | Change log claimed a "read back" that was never done | Honesty / process | Corrected |
| 5 | Resolution built twice, with clashing interfaces | Process | Process fixed; work lost |
| 6 | Gaps found in review of the merged resolution code | Review findings | Open |
| 7 | Orchestrator slips on 2026-11-03 | Process | Partly fixed |
| 8 | Invariant tests merged without running CI's build step; CI broke | Process / verification | Fixed |
| 9 | Tests that passed but missed bugs, found by an independent review | Test quality | Fixed |
| 10 | Order-book panel: wrong "Not enough mUSDC" while loading, and trades missing from history | UI bug / missing feature | Fixed |

---

## 1. `vm.prank` used up by a view call in a redeem test

| Field | Value |
|---|---|
| Date | 2026-10-24 |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | "i answered the quesstins alr. build phase 1, and as usual, log to actions.md". The AI could see the resolution plan with the user's answers and the trading branch code. |
| Commit | Fix in `1c7ad9e`, the only commit of PR #20 (not merged, entry 5). The buggy version was never committed. |
| Files affected | `contracts/test/MarketResolution.t.sol` (in `1c7ad9e` only) |
| Severity | Low (test only) |

### Summary

In `test_RevertWhen_RedeemingMoreThanBalance` the AI called `market.yesTokenId()` between `vm.prank(alice)` and `market.redeem(...)`. The view call used up the prank, so `redeem` ran as the test contract and the test failed with the wrong revert data.

### Why the AI made the mistake

Wrong assumption, repeated. In Foundry `vm.prank` applies only to the next external call, and a view call counts. In its first session (market creation) the AI had already fixed two `MarketFactory.t.sol` tests where a read used up `vm.prank` or `vm.expectRevert`.

### Why it is problematic

`redeem` pays out collateral. Here the test failed loudly. If the revert data had matched by chance, it would pass while checking "an address with no tokens cannot redeem" instead of "Alice cannot redeem more than she holds": false assurance on the payout path.

### How we fixed it

Read the token ID before the prank (`1c7ad9e`):

```solidity
uint256 yesId = market.yesTokenId(); // read before vm.prank, which applies to the next call
vm.prank(alice);
```

Spec update (2026-11-03): the `contracts-engineer` agent prompt says "Remember `vm.prank` is consumed by the next call, including view calls." PR #21 (`e349b76`) replaced PR #20, so this test is not on `main` or `lin/integration`.

### Evidence the fix works

- First run: `Suite result: FAILED. 27 passed; 1 failed`, with `ERC1155InsufficientBalance(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 0, ...)`: Foundry's default test contract, not Alice.
- After the fix: `90 tests passed, 0 failed, 0 skipped (90 total tests)` (36 factory, 26 trading, 28 resolution); 89/89 after the rebase onto `main`.
- Fixed test: `git show 1c7ad9e:contracts/test/MarketResolution.t.sol`, lines 242-253.

---

## 2. `forge fmt` on the whole repo rewrote 7 teammate files

| Field | Value |
|---|---|
| Date | 2026-10-24 |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | Same task as entry 1. The AI ran `forge fmt` to format its new files. |
| Commit | No fix commit; reverted before commit. Clean result: `1c7ad9e`. |
| Files affected | `IOutcomeToken.sol`, `OutcomeToken.sol`, `MarketFactory.sol`, `IMarketFactory.sol`, `MarketFactory.t.sol`, `MarketTrading.t.sol`, `DeployMarketFactory.s.sol` (all reverted) |
| Severity | Low |

### Summary

The AI ran `forge fmt` without paths, so it rewrote the line endings of 7 teammate files.

### Why the AI made the mistake

Tool misuse plus missing context. With no paths, `forge fmt` formats every file. This Windows copy uses `core.autocrlf=true` (working files CRLF, repo LF), which the AI did not know. Later checks showed `forge fmt --check` here reports 24 files, all line endings only, while `git ls-files --eol` shows `i/lf w/crlf`.

### Why it is problematic

The PR diff would include 7 untouched files, hiding the real change from reviewers and inviting merge conflicts with teammates' open work. Nobody notices unless the diff is read before committing.

### How we fixed it

- Restored the 7 files with `git checkout --`.
- Spec update (2026-11-03): `contracts-engineer` and `test-security` say "Run `forge fmt` only on files you changed (`forge fmt <paths>`), never on the whole repo." The orchestrator says "Never edit teammates' files just to reformat them" and checks `git diff --stat` for stray formatter changes.
- Team note: teammates on Windows must not commit fmt's CRLF rewrite.

### Evidence the fix works

- `git diff --stat` showed only the intended files; `forge fmt --check` passed on them.
- `git show --stat 1c7ad9e` lists only 5 files (`Market.sol`, `IMarket.sol`, `MarketResolution.t.sol`, `docs/market-creation-explained.md`, `docs/resolution.md`).
- `forge fmt --check` passes on an LF export of the branch.

---

## 3. Slither `reentrancy-no-eth` in `Market.sell` judged not exploitable

An evaluation, not a fixed bug: we record the AI's judgement and how far the evidence goes.

| Field | Value |
|---|---|
| Date | 2026-10-24 (first triage); re-checked 2026-11-03 |
| Tool | Claude Code (Claude Opus); Slither 0.11.3 (first run), 0.11.6 (re-run) |
| Prompt / context given | Same task as entry 1; Slither was run before finishing. The re-run was the task for GitHub issue #7 ("security and coverage evidence"). |
| Commit | No code change. Triage first written in `b525c2f`, now in [`testing.md`](../testing.md#security-analysis). |
| Files affected | `contracts/src/Market.sol` (`sell`, teammate's code, unchanged) |
| Severity | Medium (Slither's rating); judged not exploitable |

### Summary

Slither reports `reentrancy-no-eth` (Medium) in `Market.sell`: `yesPool`/`noPool` are written after `outcomeToken.safeTransferFrom` and `outcomeToken.burnBatch`. The AI judged it not exploitable.

### Why the AI made the mistake

A risk of a wrong judgement, not a confirmed mistake. The AI's reasons, checked against the current code:

1. `outcomeToken` is `immutable` and deployed by the factory; users cannot supply it.
2. `safeTransferFrom(msg.sender, address(this), ...)` calls `onERC1155Received` on the market itself (`ERC1155Holder`), never the seller. `burnBatch` makes no receiver call.
3. `sell` is `nonReentrant` (`ReentrancyGuardTransient`), as are `buy`, `redeem`, `withdrawFees` and `withdrawLiquidity`.
4. The only payment, `collateral.safeTransfer(msg.sender, collateralOut)`, comes after the state updates.

Where it was weaker: the first verdict was one line ("not exploitable") with no test, and that run (Slither 0.11.3, "12 results overall") could not be reproduced; the 0.11.6 re-run gave 21, unexplained.

### Why it is problematic

If wrong, re-entry into `sell` could change the pools mid-trade: wrong prices or drained collateral. A false-positive label also stops anyone from looking again.

### How we fixed it

No code change, on purpose. We re-ran Slither and wrote the full triage ([`testing.md`](../testing.md#the-marketsell-finding)). The invariants doc found re-entrancy tested only for `buy` and `withdrawFees`, so `test_SellCollateralCallbackCannotReenterSell` (`MarketReentrancy.t.sol`, `77fe8e6`) now re-enters `sell` through a collateral-transfer callback.

### Evidence the fix works

- Slither 0.11.6 re-run: `21 result(s) found`; row 1 `reentrancy-no-eth` in `Market.sell`, decision FP. Current counts: [`testing.md`](../testing.md#security-analysis).
- `test_BuyerReceiverCannotReenterMarket` (`MarketTrading.t.sol`) shows the lock blocks re-entry from the `buy` callback.
- `test_SellCollateralCallbackCannotReenterSell` passes; the inner `sell` reverts with `ReentrancyGuardReentrantCall` (`0x3ee5aeb5`). Full suite then: `156 tests passed, 0 failed, 0 skipped`.
- Mutation check: with `nonReentrant` removed from `sell`, that test fails. So the guard, not luck, blocks the re-entry.

---

## 4. Change log claimed a "read back" that was never done

| Field | Value |
|---|---|
| Date | 2026-10-24 (07:50) |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | "write the order in the resolution_plan.md". The project instructions tell the AI to log every change with the validation it ran. |
| Commit | None. The change log is outside this repo. |
| Files affected | One row of the AI's change log |
| Severity | Medium (process / honesty) |

### Summary

The AI edited the resolution plan and logged it in the same batch of tool calls, with the validation "Read back the edited section". It never read it back.

### Why the AI made the mistake

Wrong assumption, and a habit: it wrote what a careful person would do, not what it did. The transcript shows the edit sent at 23:50:17 UTC and the log row at 23:50:20 UTC, before either result came back.

### Why it is problematic

The change log is the main evidence for this report. One made-up validation weakens trust in every row, and the rules forbid invented evidence ([`README.md`](README.md)). The same habit could produce unchecked "tests pass" or "Slither clean" claims.

### How we fixed it

The AI caught it about 5 seconds later, unprompted, with a `sed` command ("Correct the validation note in the log entry") that changed the text to "Edit applied successfully; docs only, no tests needed". True, but weaker: it rests on the tool's success message. The later orchestrator rule asks for independent checks ("you never accept their report without checking it yourself").

### Evidence the fix works

- The row now reads "Edit applied successfully; docs only, no tests needed".
- The transcript has both commands: "Log the plan update in actions.md" and, 5 seconds later, "Correct the validation note in the log entry".
- Later rows that only say "Read back" were not audited: TODO: evidence.

---

## 5. Resolution built twice, with clashing interfaces

| Field | Value |
|---|---|
| Date | 2026-10-24 to 2026-10-25 |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | Build: the prompt in entry 1. The AI had been shown the backlog, where resolution tasks have owner `M2` (resolution and security); Lin's earlier work was market creation (`M1`). Discovery: "someoen alr created the resolution task due to miscoms. help me check the new resolution code and what should be the next few items to do". |
| Commit | Lin's: `1c7ad9e` (PR #20, not merged). Teammate's: PR #21, merged as `e349b76`. Fix is in the orchestrator prompt (outside this repo). |
| Files affected | `contracts/src/Market.sol`, `contracts/src/interfaces/IMarket.sol`, resolution tests and docs |
| Severity | Medium (process; no funds at risk, but duplicate work) |

### Summary

The AI built resolution phase 1 (resolve, redeem, cancel/refund) for Lin on `lin/feat/resolution` while a teammate built it with a different design (PR #21). PR #21 was merged; PR #20 was replaced.

### Why the AI made the mistake

Missing context and a missing step: the AI never asked whether Lin had claimed the work, though the backlog lists it under `M2`. A remote-branch check alone would probably not have caught it: the teammate's first resolution commit (`435e90a`) is dated 2026-10-25 14:54, after Lin's build. The real cause was team communication ("miscoms"); the AI's part is that it did not ask.

### Why it is problematic

- Lin's work was replaced, including a 28-test suite and `docs/resolution.md`.
- Two clashing interfaces: PR #20 had `Resolution { Yes, No, Invalid }` and `claimLiquidity`; the merged code has `Outcome { Yes, No }` and `withdrawLiquidity`. Merging both would have broken the frontend and bot.
- A merge-conflict session was spent on code later thrown away.

### How we fixed it

Prompt/spec update. The orchestrator skill (2026-11-03) now, before any work:

- Step 1: fetches, then "Check whether any candidate task already landed on `main` or a remote branch ... Someone else built resolution in parallel once; catch that early." It stops and asks if the working tree has uncommitted changes.
- Step 3: a `CLAIM` gate asks "Have you claimed issue #N on GitHub and told the team?"

### Evidence the fix works

- The user confirmed they had claimed issues #15 and #1 and told the team before the first round.
- The uncommitted-changes check found the CI task already built by another session; the round paused instead of building it twice.
- Limit: that was a duplicate between two of Lin's own sessions, not a teammate's work, and the first status check missed it (entry 7).
- PR #20 state on GitHub: TODO: evidence.

---

## 6. Gaps found in review of the merged resolution code

| Field | Value |
|---|---|
| Date | 2026-10-25 (22:18) |
| Tool | Claude Code (Claude Opus), review only |
| Prompt / context given | The discovery prompt in entry 5. The AI read the `Market.sol`/`IMarket.sol` diff `f54dc85..main`, `OptimisticResolver.sol` and `ChainlinkResolver.sol`. |
| Commit | Reviewed code: PR #21 (`e349b76`). No fix commits yet. |
| Files affected | `contracts/src/Market.sol`, `contracts/src/OptimisticResolver.sol`, `contracts/src/ChainlinkResolver.sol` |
| Severity | Low to Medium per item |

### Summary

An AI-assisted review of the teammate's code found 5 gaps. Whether that code was AI-generated is not confirmed (TODO: evidence). In our reading none lets an outsider steal funds. All 5 are open (re-checked 2026-11-04).

| # | Finding | Where (current code) | Impact | Status |
|---|---|---|---|---|
| 6a | No INVALID result | `IMarket.Outcome` has only `Yes`, `No` | An ambiguous market can only end by waiting out the 7-day `RESOLUTION_WINDOW`, after which `state()` reports `Cancelled` | Open: optional, first to cut |
| 6b | A late dispute leaves the judge almost no time | `propose` only needs `windowEnd < deadline`; `dispute` is allowed until `windowEnd` | The owner may have no time to `rule`; the market cancels (50/50) instead of getting its true result. Bonds are freed by `refund` | Open: hardening skipped; known limitation |
| 6c | Bonds are pushed, not pulled | `finalize`, `rule` and `refund` call `bondToken.safeTransfer`; a code comment marks it a shortcut | With real USDC, a blacklisted recipient makes settlement revert; a reverting `refund` can leave both bonds stuck | Open: hardening skipped; known limitation. Testnet MockUSDC has no blacklist |
| 6d | Chainlink tie resolves NO | `ChainlinkResolver._isYes` uses strict `<` and `>` | A price exactly at the threshold pays NO for both `Below` and `Above` | Accepted design: documented ("Ties resolve NO", `docs/chainlink-resolver.md`) and tested |
| 6e | Donated outcome tokens stay stuck | `withdrawLiquidity` burns only `yesPool`/`noPool` | Tokens sent to the market directly never leave; only the donor loses | Open: known limitation |

### Why the AI made the mistake

For the code: simplifying assumptions. Every market has a clear YES/NO answer (6a), the judge acts at once (6b), the bond token never blocks transfers (6c, a documented shortcut). 6d and 6e are uncovered edge cases. For the review: it did not rank the gaps or write a failing test for any, so these are claims from reading, not proven bugs.

### Why it is problematic

- 6a, 6b: wrong or late results; traders who were right get 50/50.
- 6c: stuck bonds and a market that cannot settle through the resolver, with real USDC.
- 6d: a wrong outcome for anyone expecting "at or below" wording.
- 6e: stuck tokens (small, self-inflicted).

### How we fixed it

Not fixed. User decision on 2026-11-04: resolver hardening (6b, 6c) is skipped as code and written up as known limitations in [`threat-model.md`](../threat-model.md) §5. INVALID (6a) is optional and the first item to cut.

### Evidence the fix works

- 6a: TODO: evidence (not built).
- 6b, 6c: no code fix; listed as K-1 and K-2 in `docs/threat-model.md` §5. No test: TODO: evidence.
- 6d: `test_BelowResolvesNoOnTie` and `test_AboveResolvesNoOnTie` (`ChainlinkResolver.t.sol`); part of the 146 passing tests (2026-11-04).
- 6e: `test_DonationsDoNotChangeRecordedReserves` shows donations do not change the pools. No test shows the stuck balance after `withdrawLiquidity`: TODO: evidence.
- Review baseline: `forge test` on `main` 137/137 pass.

---

## 7. Orchestrator slips on 2026-11-03

| Field | Value |
|---|---|
| Date | 2026-11-03 |
| Tool | Claude Code (Claude Opus) running the `/orchestrate` skill and its worker agents |
| Prompt / context given | `/orchestrate`; later "did u log the changes alr?" and "did u log these?"; for the CI change, "for the issue of not being able to merge to main, how about i merge to lin branch first". Context: the work plan, the change log, the project instructions and the skill file. |
| Commit | `f8fcadc` (CI trigger change). Other items: no commit. |
| Files affected | The change log and work plan (outside this repo), `.github/workflows/ci.yml` |
| Severity | Low to Medium (process) |

### Summary

| # | Slip |
|---|---|
| 7a | The first status check said the CI task was not built anywhere. A second Claude session was building it in the same folder at the same time, and `.github/` had not appeared yet |
| 7b | Automatic agent worktrees failed: "Cannot create agent worktree: not in a git repository and no WorktreeCreate hooks are configured." Only `Sooth/` is a git repo, not the session folder |
| 7c | The manual `git worktree add` commands were not logged until the user asked "did u log the changes alr?" |
| 7d | Status changes and scratchpad files (Slither venv, `model.py`) were not logged until the user asked "did u log these?" |
| 7e | After adding `lin/integration` to the CI triggers, the YAML was not parsed (Python had no `yaml` module). The commit was made anyway |

The orchestrator also caught an agent reporting 51 invariant rows; there were 50.

### Why the AI made the mistake

- 7a: wrong assumption. The skill assumes one session per repo and checked `main` and remote branches, not another live session's untracked files.
- 7b: missing context. `isolation: "worktree"` needs the session folder to be a git repo.
- 7c, 7d: under time pressure the AI worked first and logged later, against the rule to log right after each change.
- 7e: a tool limit accepted too easily; it relied on GitHub to validate the file later.

### Why it is problematic

- 7a: risk of building the same task twice (as in entry 5).
- 7b: without isolation, parallel agents could mix their changes in one checkout.
- 7c, 7d: missing log rows mean missing evidence, found only if someone asks.
- 7e: a broken workflow file silently disables PR checks, or fails every run on the integration branch.

### How we fixed it

- 7a: the round paused when the second check showed `?? .github/`; the user had the CI task committed first (`e731316`).
- 7b: worktrees made by hand with `git worktree add` in the scratchpad, one per agent. On 2026-11-04 the skill's step 5 was changed to say this.
- 7c, 7d: late rows added and marked as late. No rule change.
- 7e: parsed afterwards with actionlint v1.7.7 (a GitHub Actions linter) on `.github/workflows/ci.yml` (last changed by `f8fcadc`).

### Evidence the fix works

- 7a: `git log` shows `e731316 ci: add contracts and bot test workflow` and PR #23 merged (`f4ae558`).
- 7b: `git worktree list` showed both worktrees; `forge test` ran in each (137 pass). After the skill change, two agents ran in parallel in hand-made worktrees without errors.
- 7c, 7d: the late rows exist. Nothing stops a repeat: TODO: evidence (no rule or check added).
- 7e: `actionlint .github/workflows/ci.yml`: no output, exit code 0 (2026-11-04). GitHub Actions run for `f8fcadc`: TODO: evidence (run link).

---

## 8. Invariant tests merged without running CI's build step; CI broke

| Field | Value |
|---|---|
| Date | 2026-11-04 |
| Tool | Claude Code (Claude Opus), main session as orchestrator, plus the `test-security` agent |
| Prompt / context given | User: "since you are very fast and efficient, can we not finish all today?" The orchestrator merged agent work into `lin/integration` after its own checks. |
| Commit | Bug: merge `3159dec` (test commit `e6485bd`). Fix: `2699509` (merged as `9c8bf44`) |
| Files affected | `.github/workflows/ci.yml`, `contracts/test/invariant/MarketHandler.sol` |
| Severity | Medium |

### Summary

The invariant handler `MarketHandler` compiles to 34,326 bytes, over the EIP-170 limit of 24,576. CI's `forge build --sizes` fails on any oversized contract, tests included, so every CI run on `lin/integration` after `3159dec` would fail at "Build". The orchestrator merged and pushed without noticing.

### Why the AI made the mistake

Tool misuse in verification: the orchestrator ran `forge test` and `forge fmt --check`, not the exact `ci.yml` commands, and `forge test` does not enforce the size limit. It could not see GitHub Actions (no `gh` CLI) and did not ask the user to check. Speed was being optimised ("finish all today").

### Why it is problematic

A red CI hides real failures in later pushes, and the reviewed PR to `main` cannot merge with a required check failing. It also broke a claim in our docs ("build succeeds").

### How we fixed it

- Found by the next agent (the Slither/coverage re-run), which ran every command in `testing.md`.
- `ci.yml` now checks sizes of deployable contracts only: `forge build --sizes --skip './test/**' --skip './script/**'`. `forge test` still compiles and runs every test.
- Process: verify agent work with the exact CI commands.

### Evidence the fix works

- Before: `forge build --sizes` exit 1, `MarketHandler | 34,326 | ... | -9,750`, `Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)`.
- After: the new step exits 0 on the same commit. A temporary 26,308-byte contract in `src/` makes it exit 1 (file removed afterwards), so it still protects.
- `forge test` 195 passed, 0 failed; actionlint exit 0.
- GitHub Actions run on `lin/integration` after the fix: TODO: evidence (run link).

---

## 9. Tests that passed but missed bugs, found by an independent review

| Field | Value |
|---|---|
| Date | 2026-11-05 |
| Tool | Claude Code: `contracts-engineer` (order book) and `test-security` (invariants) wrote the tests; two fresh `test-security` agents reviewed them read-only |
| Prompt / context given | User: "please make sure all the unit tests and e2e test you added make sense, theres too much i wont review it." Reviewers got a checklist and could plant bugs if they restored the code byte for byte |
| Commit | Bugs: `99bcf7a` (order book tests), `e6485bd` (invariants). Fixes: `2cae6a8` (PR 2), `bbfc986` (PR 3) |
| Files affected | `contracts/test/OutcomeOrderBook.t.sol`, `contracts/test/invariant/SoothInvariants.t.sol`, `contracts/test/invariant/ResolverHandler.sol`, `docs/invariants.md` |
| Severity | Medium |

### Summary

Three AI-written tests did not check what they claimed. `test_Buy_PartialLastListingCountsAsTouched` never reached the `maxListings` limit. `invariant_BND_4_refundMakesEveryoneWhole` missed a refund paid to the wrong person. A `bondNet` check in `ResolverHandler` could never fail.

### Why the AI made the mistake

Wrong assumption: a passing test whose name describes a property was taken to prove it. Nobody planted the bug each test should catch. The refund path was reached once per 64-run campaign; the reach summary showed this but nobody checked. The `bondNet` check compared numbers the handler had just set, so it was true by construction.

### Why it is problematic

False assurance on fund-moving code: a `maxListings` off-by-one or a refund to the wrong address would have shipped with every test green. The team was about to merge without reading the tests.

### How we fixed it

- Order book (`2cae6a8`): a second buy must stop after the half-filled listing.
- Invariants (`bbfc986`): `afterInvariant` checks each refund recipient's balance; the handler refunds disputed requests and hits the deadline edge; the `bondNet` mapping and check were removed and the INV-BND-4 note in `docs/invariants.md` corrected.
- Process: test reviews plant the bug each test claims to catch, and check reach counts for rare paths.

### Evidence the fix works

- Planted `touched < maxListings` → `<=`: before, only `test_Buy_StopsAtMaxListings` failed; after, `[FAIL: stops after the one listing it may touch: 15000000 != 5000000] test_Buy_PartialLastListingCountsAsTouched()`.
- Planted "refund pays the disputer's bond to the proposer": before, all 20 invariants passed; after, `refund paid wrong amounts or someone gained or lost: 2 != 0` (`invariant_BND_4`) and `refund: proposer gets one bond: 20000000 != 10000000` (`afterInvariant`).
- Refund reach per campaign: 1 → 11. After the fixes: PR 2 175 passed, PR 3 176 passed; fmt and size checks exit 0.
- Not changed: two constant-only asserts in `EndToEnd._simpleTrades` (PR 1, merged); the order-book fuzz test does not check cost rounding, which four unit tests do.

---

## 10. Order-book panel: wrong "Not enough mUSDC" while loading, and trades missing from history

| Field | Value |
|---|---|
| Date | 2026-11-05 |
| Tool | Claude Code (`general-purpose` agent wrote the panel; the main session ran the UI test) |
| Prompt / context given | User: "Ok please make sure you tested it locally and e2e test with the UI instead of just relying on the CI unit test". Lin, after testing in MetaMask: "the only complaint is that the trading with others actiosn is not logged in the history." |
| Commit | Bug: `36687d6` (panel). Fixes: `af913e4` (loading), `e03cc6d` (trades in history), `5baba74` (listings in history, listed shares in positions) |
| Files affected | `web/src/orderbook.tsx`, `web/src/chain.ts`, `web/src/mock.ts`, `web/src/pages/Market.tsx`, `web/src/pages/Portfolio.tsx` |
| Severity | Low (UX); Medium for wrong average price and PnL |

### Summary

Two problems that build, lint and contract tests could not see. Right after a quote appeared, the buy button said "Not enough mUSDC" to a buyer holding 100 mUSDC. And order-book trades never appeared in history, so a book-only buyer had no average price and a wrong PnL.

### Why the AI made the mistake

Missing context: the panel was checked statically (build, lint, ABI match) but never used in a browser before review. It defaulted not-yet-loaded wallet reads to zero (`reads ?? [0n, ...]`). History scanned only the markets' `Bought`/`Sold` events, and the agent was not asked to add the order book.

### Why it is problematic

Users see a false error and may give up on a valid trade. Positions bought on the book showed an average price of 0, and listed shares disappeared from positions while waiting.

### How we fixed it

- `af913e4`: buttons say "Loading balances…" until the reads arrive.
- `e03cc6d`: the site scans the book's `Filled` events; each fill is a Buy row for the buyer and a Sell row for the seller, tagged "book", counted in average price and PnL. The chart and volume stay AMM-only.
- `5baba74`: `Listed` and `Cancelled` become List and Cancel rows in the seller's history; open listings count in positions as "N listed"; the redeem amount uses wallet shares only.

### Evidence the fix works

- UI test before the fix: the first buyer run found only a disabled "Not enough mUSDC" button; waiting for the reads gave "Approve mUSDC, then buy".
- After `e03cc6d`, on the local fork: Recent activity shows Lin's manual fills as Buy/Sell rows tagged "book"; the buyer's position is 20 YES at a 70¢ average, 14.00 USDC in; volume stays 35 USDC (AMM only).
- After `5baba74`: the seller's history shows List and Cancel rows; the position shows "30.38 YES, 5.00 listed"; with every share listed the position still shows; PnL +3.58 matches the hand calculation 25.50 + 19.58 − 41.50.
- The loading fix was checked by code review and build/lint only; a browser run with slowed balance reads could not be completed. TODO: evidence (browser check of the loading state).
