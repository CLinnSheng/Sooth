# AI audit log: Lin

AI mistakes from Lin's sessions with Claude Code. Rules and format: `docs/ai/README.md`.

Entries 1 to 7 were back-filled on 2026-11-04 (task P0-2) from:

- the change log `actions.md` (entry IDs such as S3-7), kept outside this repo in the project folder
- the Claude Code session transcripts (the source of the quoted prompts)
- git history in this repo

Times are local time (UTC+8) unless marked UTC. The tool was Claude Code. Session transcripts show both Claude Opus and Claude Sonnet models; the Session 6 orchestrator rounds ran almost entirely on Sonnet (see `docs/ai-audit-report.md`, issue 13).

| # | Title | Type | Status |
|---|---|---|---|
| 1 | `vm.prank` used up by a view call in a redeem test | Test bug | Fixed |
| 2 | `forge fmt` on the whole repo rewrote 7 teammate files | Tool misuse | Fixed (reverted, spec updated) |
| 3 | Slither `reentrancy-no-eth` in `Market.sell` judged not exploitable | Evaluation | Judged false positive, no unit test yet |
| 4 | Change log claimed a "read back" that was never done | Honesty / process | Corrected |
| 5 | Resolution (E3) built twice, with clashing interfaces | Process | Process fixed; work lost |
| 6 | Gaps found in review of the merged resolution code | Review findings | Open |
| 7 | Orchestrator slips in Session 6 | Process | Partly fixed |
| 8 | Invariant tests merged without running CI's build step; CI broke | Process / verification | Fixed |

---

## 1. `vm.prank` used up by a view call in a redeem test

| Field | Value |
|---|---|
| Date | 2026-10-24 |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | "i answered the quesstins alr. build phase 1, and as usual, log to actions.md". The AI could see `resolution_plan.md` (with the user's answers to Q1-Q4 and Q10) and the trading branch code. |
| Commit | Fix is in `1c7ad9e` on branch `lin/feat/resolution`, the only commit of PR #20. The buggy version was never committed. PR #20 was not merged (see entry 5). |
| Files affected | `contracts/test/MarketResolution.t.sol` (on `lin/feat/resolution` only) |
| Severity | Low (test only) |

### Summary

The AI wrote `test_RevertWhen_RedeemingMoreThanBalance`. It called `market.yesTokenId()` after `vm.prank(alice)` and before `market.redeem(...)`. The view call used up the prank. `redeem` then ran as the test contract, not as Alice, so the test failed with the wrong revert data.

### Why the AI made the mistake

Wrong assumption. In Foundry, `vm.prank` applies only to the next external call, and a view call counts. The AI treated the view call as free. It had made the same mistake before: in Session 1 it fixed two `MarketFactory.t.sol` tests where a read used up `vm.prank` or `vm.expectRevert` (`actions.md` D2). So this is a repeated mistake, not new knowledge.

### Why it is problematic

`redeem` pays out collateral, so its revert tests guard real money. Here the test failed loudly, which is the good case. If the expected revert data had matched by chance, the test would pass while checking the wrong thing: "an address with no tokens cannot redeem" instead of "Alice cannot redeem more than she holds". That is false assurance on the payout path.

### How we fixed it

Manual code fix: read the token ID before the prank. In `1c7ad9e`:

```solidity
uint256 yesId = market.yesTokenId(); // read before vm.prank, which applies to the next call
vm.prank(alice);
```

Spec update (2026-11-03, `actions.md` S5-4): the `contracts-engineer` agent spec now says "Remember `vm.prank` is consumed by the next call, including view calls."

Note: PR #20 was replaced by the teammate's PR #21 (merged as `e349b76`). This test is not on `main` or `lin/integration`. The `MarketResolution.t.sol` there is the teammate's file. The evidence below is the log entry and the transcript.

### Evidence the fix works

- First run (`actions.md` S3-7): 27 of 28 passed. Real output from the transcript: `Suite result: FAILED. 27 passed; 1 failed`. The failure line shows `ERC1155InsufficientBalance(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, 0, ...)`, which is Foundry's default test contract with balance 0, not Alice.
- After the fix: `90 tests passed, 0 failed, 0 skipped (90 total tests)` (36 factory, 26 trading, 28 resolution).
- After the rebase onto `main` (S3-13): 89/89 pass.
- The fixed test is in `git show 1c7ad9e:contracts/test/MarketResolution.t.sol`, lines 242-253.

---

## 2. `forge fmt` on the whole repo rewrote 7 teammate files

| Field | Value |
|---|---|
| Date | 2026-10-24 |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | Same task as entry 1: "build phase 1, and as usual, log to actions.md". The AI ran `forge fmt` to format its new files. |
| Commit | No fix commit; the changes were reverted before commit. Clean result: `1c7ad9e`. |
| Files affected | `IOutcomeToken.sol`, `OutcomeToken.sol`, `MarketFactory.sol`, `IMarketFactory.sol`, `MarketFactory.t.sol`, `MarketTrading.t.sol`, `DeployMarketFactory.s.sol` (all reverted) |
| Severity | Low |

### Summary

The AI ran `forge fmt` without file paths, so it formatted the whole repo. It rewrote 7 files owned by teammates. The changes were line endings only (`actions.md` S3-8).

### Why the AI made the mistake

Tool misuse plus missing context. With no paths, `forge fmt` formats every file. On this Windows copy git uses `core.autocrlf=true`, so the working files have CRLF while the repo stores LF. The formatter rewrote their line endings. The AI did not know about the line-ending setup and did not limit the command to its own files. Later (S5-8) we found that `forge fmt --check` on this working copy reports 24 files, all line endings only, while `git ls-files --eol` shows `i/lf w/crlf`.

### Why it is problematic

- The PR diff would include 7 files the task did not touch. That hides the real change from reviewers.
- It changes teammates' files for no reason, which invites merge conflicts with their open work.
- Nobody notices it if the diff is not read before committing.

### How we fixed it

- Manual: restored the 7 files with `git checkout --`.
- Spec update (2026-11-03, S5-4): `contracts-engineer` says "Run `forge fmt` only on files you changed (`forge fmt <paths>`), never on the whole repo." `test-security` has the same rule. The orchestrator says "Never edit teammates' files just to reformat them" and checks `git diff --stat` for stray formatter changes.
- Team note (S5-8): teammates on Windows must not commit fmt's CRLF rewrite.

### Evidence the fix works

- S3-8: `git diff --stat` showed only the intended files; `forge fmt --check` passed on them.
- `git show --stat 1c7ad9e` lists only 5 files: `Market.sol`, `IMarket.sol`, `MarketResolution.t.sol`, `docs/market-creation-explained.md`, `docs/resolution.md`. None of the 7 teammate files.
- S5-8: `forge fmt --check` passes on an LF export of the branch (CI-5).

---

## 3. Slither `reentrancy-no-eth` in `Market.sell` judged not exploitable

This is an evaluation, not a fixed bug. The AI made a judgement about a Slither finding. We record the reasoning and how far the evidence goes.

| Field | Value |
|---|---|
| Date | 2026-10-24 (first triage); re-checked 2026-11-03 |
| Tool | Claude Code (Claude Opus); Slither 0.11.3 (first run), Slither 0.11.6 (re-run) |
| Prompt / context given | Same task as entry 1; Slither was run as a check before finishing (S3-9). The re-run was task P1-4 ("Issue #7: security and coverage evidence"). |
| Commit | No code change. Triage written in `docs/security-analysis.md` (`b525c2f`). |
| Files affected | `contracts/src/Market.sol` (`sell`, teammate's code, unchanged) |
| Severity | Medium (Slither's rating); judged not exploitable |

### Summary

Slither reports `reentrancy-no-eth` (Medium) in `Market.sell`: `yesPool`/`noPool` are written after calls to `outcomeToken.safeTransferFrom` and `outcomeToken.burnBatch`. The AI judged it not exploitable and left the code unchanged.

### Why the AI made the mistake

This entry is about the risk of a wrong judgement, not a confirmed mistake. The AI's reasons (S3-9, then `docs/security-analysis.md` section 1.1, checked against the current code):

1. `outcomeToken` is `immutable` and deployed by the factory. Users cannot supply it.
2. `safeTransferFrom(msg.sender, address(this), ...)` calls `onERC1155Received` on the receiver, which is the market itself (`ERC1155Holder`). The seller is never called back. `burnBatch` makes no receiver call.
3. `sell` is `nonReentrant` (`ReentrancyGuardTransient`), and so are `buy`, `redeem`, `withdrawFees` and `withdrawLiquidity`.
4. The only payment, `collateral.safeTransfer(msg.sender, collateralOut)`, comes after the state updates.

Where the AI was weaker:

- In Session 3 it gave the conclusion in one line ("not exploitable") with no test behind it.
- The Session 3 run (Slither 0.11.3, "12 results overall") could not be reproduced later. The re-run with 0.11.6 on the current code gives 21 results. `docs/security-analysis.md` says so and does not explain the cause.

### Why it is problematic

If the judgement were wrong, reentrancy into `sell` could change the pools mid-trade. That leads to wrong prices or draining the market's collateral. A false-positive label also stops anyone from looking again. That is why the reasoning needs a test, not only an argument.

### How we fixed it

No code change, on purpose: the order of calls is safe for the reasons above. What we did:

- Re-ran Slither on the current code and wrote the full triage (row 1 "FP", section 1.1) in `docs/security-analysis.md` (P1-4, S6-13).
- The invariants doc (P1-1, S6-6) found that reentrancy is only tested for `buy` and `withdrawFees`. P1-6 then added `test_SellCollateralCallbackCannotReenterSell` (`MarketReentrancy.t.sol`, commit `77fe8e6`), which re-enters `sell` through a collateral-transfer callback.

### Evidence the fix works

- Slither 0.11.6 output line (S6-13, re-run by the orchestrator): `21 result(s) found`; row 1 is `reentrancy-no-eth` in `Market.sell`, decision FP.
- Code check: `Market.sell` is `external nonReentrant`, and `_setPools` and `accruedFees` come after `safeTransferFrom`/`burnBatch` (as Slither says).
- Related test: `test_BuyerReceiverCannotReenterMarket` (`MarketTrading.t.sol`) shows the lock blocks reentry from the `buy` callback.
- `test_SellCollateralCallbackCannotReenterSell`: passes; the inner `sell` reverts with `ReentrancyGuardReentrantCall` (`0x3ee5aeb5`). Full suite after P1-6: `156 tests passed, 0 failed, 0 skipped` (`actions.md` S7-15).
- Mutation check (S7-14): with `nonReentrant` removed from `sell`, that test fails because the nested sell succeeds. So the guard, not luck, blocks the reentry.

---

## 4. Change log claimed a "read back" that was never done

| Field | Value |
|---|---|
| Date | 2026-10-24 (07:50) |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | "write the order in the resolution_plan.md". `CLAUDE.md` tells the AI to log every change with the validation it ran. |
| Commit | None. `actions.md` is outside this repo. |
| Files affected | `actions.md` entry S3-3 |
| Severity | Medium (process / honesty) |

### Summary

The AI edited `resolution_plan.md` and wrote the log entry in the same batch of tool calls. The entry said the validation was "Read back the edited section". The AI never read the section back. It had not yet seen the result of the edit.

### Why the AI made the mistake

Wrong assumption, and a habit. The AI filled the Validation column with what a careful person would normally do, not with what it did. The transcript shows the edit sent at 23:50:17 UTC and the log entry at 23:50:20 UTC, before either tool result came back.

### Why it is problematic

The change log is the main evidence for this report and for teammates. One made-up validation weakens trust in every other row. The rules forbid invented evidence (`docs/ai/README.md`, `CLAUDE.md`). In a security context, the same habit could produce "tests pass" or "Slither clean" claims that nobody checked.

### How we fixed it

The AI caught it itself about 5 seconds later, without a prompt from the user. It ran a `sed` command ("Correct the validation note in the log entry") that replaced the text with "Edit applied successfully; docs only, no tests needed". That is true, but weaker: it rests on the tool's success message. Nobody read the section back.

The later orchestrator rule (S5-3) asks for independent checks ("you never accept their report without checking it yourself").

### Evidence the fix works

- `actions.md` S3-3 now reads "Edit applied successfully; docs only, no tests needed".
- The transcript has both commands: "Log the plan update in actions.md" and, 5 seconds later, "Correct the validation note in the log entry".
- Not checked: later rows that only say "Read back" (for example S6-2, S6-10) were not audited for the same problem. TODO: evidence.

---

## 5. Resolution (E3) built twice, with clashing interfaces

| Field | Value |
|---|---|
| Date | 2026-10-24 to 2026-10-25 |
| Tool | Claude Code (Claude Opus) |
| Prompt / context given | Build: "i answered the quesstins alr. build phase 1, and as usual, log to actions.md". The AI had been shown the E3 backlog table, where E3 tasks have owner `M2` (resolution and security). Lin's earlier work was E1 (owner `M1`). Discovery: "someoen alr created the resolution task due to miscoms. help me check the new resolution code and what should be the next few items to do". |
| Commit | Lin's work: `1c7ad9e` (PR #20, not merged). Teammate's work: PR #21, merged as `e349b76`. Fix is in the orchestrator spec (outside this repo). |
| Files affected | `contracts/src/Market.sol`, `contracts/src/interfaces/IMarket.sol`, resolution tests and docs |
| Severity | Medium (process; no funds at risk, but duplicate work) |

### Summary

The AI built E3 phase 1 (resolve, redeem, cancel/refund) for Lin on `lin/feat/resolution`. A teammate built E3 in parallel (PR #21), with a different interface and design. PR #21 was merged. Lin's PR #20 was replaced (S4-1, S4-2).

### Why the AI made the mistake

Missing context and a missing step. The AI never asked whether Lin owned E3 or had claimed it. The backlog table it was given lists E3 under `M2`. Starting the work was the user's call, but the AI did not raise the question.

A remote-branch check alone would probably not have caught it. In git history the teammate's first resolution commit (`435e90a`) is dated 2026-10-25 14:54, after Lin's build on 2026-10-24. The real cause was team communication ("miscoms"). The AI's part is that it did not ask.

### Why it is problematic

- Lin's E3 work (S3-4 to S3-15) was replaced, including a 28-test suite and `docs/resolution.md`.
- Two clashing interfaces for the same contract. Lin's PR #20 added a `Resolution { Yes, No, Invalid }` enum and `claimLiquidity`. The merged code uses `Outcome { Yes, No }` and `withdrawLiquidity`. Merging both would have broken the frontend and bot.
- It also cost a merge-conflict session (S3-13) on code that was later thrown away.

### How we fixed it

Prompt/spec update. The orchestrator (`.claude/skills/orchestrate/SKILL.md`, written 2026-11-03, S5-3) now does this before any work:

- Step 1: fetch, then "Check whether any candidate task already landed on `main` or a remote branch ... Someone else built resolution in parallel once; catch that early." If the working tree has uncommitted changes, stop and ask.
- Step 3: a `CLAIM` gate asks "Have you claimed issue #N on GitHub and told the team?" before any task.

### Evidence the fix works

- S6-1: the user confirmed they had claimed issues #15 and #1 and told the team before round 1.
- S6-3: the uncommitted-changes check found that P0-3 (CI) was already built by another session, and the round paused. The log says this "avoids building P0-3 twice".
- Limit: this caught a duplicate between two of Lin's own sessions. It has not yet been tested against a teammate's work. The first status check also missed it (entry 7).
- PR #20 state on GitHub (closed or still open): TODO: evidence.

---

## 6. Gaps found in review of the merged resolution code

| Field | Value |
|---|---|
| Date | 2026-10-25 (22:18) |
| Tool | Claude Code (Claude Opus), review only |
| Prompt / context given | "someoen alr created the resolution task due to miscoms. help me check the new resolution code and what should be the next few items to do". The AI read the `Market.sol`/`IMarket.sol` diff `f54dc85..main`, `OptimisticResolver.sol` and `ChainlinkResolver.sol` (S4-2). |
| Commit | Reviewed code: PR #21 (`e349b76`). No fix commits yet. |
| Files affected | `contracts/src/Market.sol`, `contracts/src/OptimisticResolver.sol`, `contracts/src/ChainlinkResolver.sol` |
| Severity | Low to Medium per item (table below) |

### Summary

An AI-assisted review of the teammate's resolution code found 5 gaps. The teammate's code may itself be AI-generated; we have not confirmed which tool, if any, was used (TODO: evidence). In our reading, none of the gaps lets an outsider steal funds. All 5 are still open. They were re-checked against the current code on 2026-11-04.

| # | Finding | Where (current code) | Impact | Status |
|---|---|---|---|---|
| 6a | No INVALID result | `IMarket.Outcome` has only `Yes`, `No` | An ambiguous market can only end by waiting out the 7-day window (`RESOLUTION_WINDOW`), after which `state()` reports `Cancelled` | Open: P2-1 (`todo`, optional, first in the cut order). E3-3 left unticked (S4-4) |
| 6b | A late dispute leaves the judge almost no time | `propose` only needs `windowEnd < deadline`; `dispute` is allowed until `windowEnd` | A dispute near the deadline can leave the owner almost no time to `rule`. The market then cancels (50/50) instead of getting its true result. Bonds are freed by `refund` | Open: P2-2 `skipped`; to be listed as a known limitation in the threat model (P3-2) |
| 6c | Bonds are pushed, not pulled | `finalize`, `rule` and `refund` call `bondToken.safeTransfer` to the recipient; code comment marks it a shortcut | With real USDC, a blacklisted recipient makes settlement revert. A `refund` that reverts can leave both bonds stuck | Open: P2-2 `skipped`; known limitation. Testnet MockUSDC has no blacklist |
| 6d | Chainlink tie resolves NO | `ChainlinkResolver._isYes` uses strict `<` and `>` | A price exactly at the threshold pays NO for both `Below` and `Above` markets | Accepted design: documented ("Ties resolve NO", `docs/chainlink-resolver.md`) and tested |
| 6e | Donated outcome tokens stay stuck | `withdrawLiquidity` burns only `yesPool`/`noPool` | Tokens sent to the market directly can never leave it. Only the donor loses | Open: known limitation; no plan item yet |

### Why the AI made the mistake

For the generated code: wrong assumptions in favour of a simple design. It assumes every market has a clear YES/NO answer (6a), that the judge acts at once (6b), and that the bond token never blocks transfers (6c). 6c is a known shortcut that the code itself documents. 6d and 6e are edge cases the design does not cover.

For the review itself: it found gaps but did not rank them by severity. It also did not write a failing test for any of them. These are claims from reading the code, not proven bugs.

### Why it is problematic

- 6a and 6b: wrong or late results. Traders who were right get 50/50 instead of a full payout.
- 6c: stuck bonds and a market that cannot be settled through the resolver, if real USDC is used.
- 6d: a wrong price outcome for anyone who expected "at or below" wording.
- 6e: stuck tokens (small, self-inflicted).

### How we fixed it

Not fixed yet. User decision on 2026-11-04 (S7-5, `work_plan.md` schedule): resolver hardening (P2-2) is skipped as code and written up as known limitations in the threat model. P2-1 (INVALID) is optional and the first item to cut.

### Evidence the fix works

- 6a: TODO: evidence (P2-1 not built).
- 6b, 6c: TODO: evidence (threat model P3-2 not written).
- 6d: `test_BelowResolvesNoOnTie` and `test_AboveResolvesNoOnTie` (`ChainlinkResolver.t.sol`) show the tie rule; part of the 146 passing tests (2026-11-04).
- 6e: `test_DonationsDoNotChangeRecordedReserves` shows donations do not change the pools. No test shows the stuck balance after `withdrawLiquidity`. TODO: evidence.
- Review baseline (S4-2): `forge test` on `main` 137/137 pass.

---

## 7. Orchestrator slips in Session 6

| Field | Value |
|---|---|
| Date | 2026-11-03 |
| Tool | Claude Code (Claude Opus) running the `/orchestrate` skill and its worker agents |
| Prompt / context given | `/orchestrate`; later "did u log the changes alr?" and "did u log these?"; for the CI change, "for the issue of not being able to merge to main, how about i merge to lin branch first". Context: `work_plan.md`, `actions.md`, `CLAUDE.md`, the skill file. |
| Commit | `f8fcadc` (CI trigger change). Other items: no commit (log and workflow only). |
| Files affected | `actions.md`, `work_plan.md`, `.github/workflows/ci.yml` |
| Severity | Low to Medium (process) |

### Summary

Five slips in one orchestrator session:

| # | Slip | Source |
|---|---|---|
| 7a | The first status check said P0-3 (CI) was not built anywhere. It was taken before `.github/` appeared. A second Claude session was building P0-3 in the same folder at the same time | S6-1 (correction), S6-3 |
| 7b | Automatic agent worktrees failed. Tool error: "Cannot create agent worktree: not in a git repository and no WorktreeCreate hooks are configured." `blockchain/` is not a git repo; only `Sooth/` is | S6-7 |
| 7c | The manual `git worktree add` commands were not logged until the user asked "did u log the changes alr?" | S6-7 |
| 7d | Status changes and scratchpad files (Slither venv, `model.py`) were not logged until the user asked "did u log these?" | S6-14 |
| 7e | After adding `lin/integration` to the CI triggers, the YAML was not parsed: Python had no `yaml` module. The commit was made anyway | S6-17 |

There was also an agent counting slip caught by the orchestrator: the P1-1 agent reported 51 invariant rows; the real count was 50 (S6-6).

### Why the AI made the mistake

- 7a: wrong assumption. The skill assumes one session works on the repo. It checked `main` and remote branches, not another live session's untracked files.
- 7b: missing context. The skill (step 5) tells the orchestrator to use `isolation: "worktree"`. That needs the session folder to be a git repo, and it is not.
- 7c, 7d: process slip. Under time pressure the AI did the work first and logged later. `CLAUDE.md` asks for a log entry right after each change.
- 7e: tool limit, accepted too easily. Instead of finding another parser, it relied on GitHub to validate the file later.

### Why it is problematic

- 7a: risk of building the same task twice in one evening (as in entry 5).
- 7b: without isolation, parallel agents could edit the same checkout and mix their changes.
- 7c, 7d: the log is the audit trail for this report. Missing rows mean missing evidence, and they are only found if someone asks.
- 7e: a broken workflow file disables all PR checks silently, or fails every run on the integration branch.

### How we fixed it

- 7a: the round paused when the second check showed `?? .github/` (S6-3). The user had P0-3 committed first (`e731316`, S6-4).
- 7b: worktrees made by hand with `git worktree add` in the scratchpad, one per agent (S6-7, S6-11). The skill file still says `isolation: "worktree"`; not updated yet.
- 7c, 7d: late rows added and marked "logged late" (S6-7, S6-14). No rule change.
- 7e: parsed afterwards. On 2026-11-04 (this task) I ran actionlint v1.7.7, a GitHub Actions linter that parses the YAML, on `.github/workflows/ci.yml` in `lin/integration` (last changed by `f8fcadc`).

### Evidence the fix works

- 7a: S6-3 records the pause. `git log` shows `e731316 ci: add contracts and bot test workflow` and PR #23 merged (`f4ae558`).
- 7b: S6-7: `git worktree list` showed both worktrees; `forge test` ran in each (137 pass).
- 7c, 7d: rows S6-7 and S6-14 exist with the late note. Nothing stops a repeat: TODO: evidence (no rule or check added).
- 7e: `actionlint .github/workflows/ci.yml`: no output, exit code 0 (run 2026-11-04). A GitHub Actions run for `f8fcadc` on `lin/integration`: TODO: evidence (run link).
- 7b fix in the skill file: step 5 of `.claude/skills/orchestrate/SKILL.md` now says to create worktrees by hand with `git worktree add` in the scratchpad instead of `isolation: "worktree"` (2026-11-04, `actions.md` S7-21). Used for P0-2 and P1-6 (S7-8): both agents ran in parallel without errors.

---

## 8. Invariant tests merged without running CI's build step; CI broke

| Field | Value |
|---|---|
| Date | 2026-11-04 |
| Tool | Claude Code (Claude Opus), main session acting as orchestrator, plus the `test-security` agent |
| Prompt / context given | User: "since you are very fast and efficient, can we not finish all today?" The orchestrator merged agent work into `lin/integration` after its own checks. |
| Commit | Bug: merge `3159dec` (P1-2, test `e6485bd`). Fix: branch `lin/fix/ci-size-check` (this entry's commit) |
| Files affected | `.github/workflows/ci.yml`, `contracts/test/invariant/MarketHandler.sol` |
| Severity | Medium |

### Summary

The P1-2 invariant handler `MarketHandler` compiles to 34,326 bytes, over the EIP-170 limit of 24,576. CI's step `forge build --sizes` fails on any contract over the limit, including test contracts, so every CI run on `lin/integration` after `3159dec` would fail at "Build". The orchestrator merged and pushed without noticing.

### Why the AI made the mistake

Tool misuse in verification: the orchestrator's checks were `forge test` and `forge fmt --check` (`actions.md` S7-71), not the exact commands in `ci.yml`. `forge test` does not enforce the size limit, so it passed. The orchestrator also had no way to see GitHub Actions results (no `gh` CLI), and did not ask the user to check. Speed was being optimised ("finish all today").

### Why it is problematic

A red CI on the integration branch hides real failures in later pushes, and the reviewed PR to `main` could not be merged with a required check failing. It also broke a claim already in our docs (CI-4 "build succeeds").

### How we fixed it

- Found by the next agent (P2-7, `actions.md` S7-74..S7-89), which ran every command listed in `testing.md`.
- `ci.yml`: the size check now covers deployable contracts only: `forge build --sizes --skip './test/**' --skip './script/**'`; `forge test` still compiles and runs every test.
- Process: verify agent work with the exact CI commands, not a subset.

### Evidence the fix works

- Before: `forge build --sizes` exit 1, `MarketHandler | 34,326 | ... | -9,750`, `Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)`.
- After (F1): new step exit 0 on the same commit.
- Still protective (F2): a temporary 26,308-byte contract in `src/` makes the new step exit 1; file removed afterwards.
- F3: `forge test` 195 passed, 0 failed. F4: actionlint exit 0.
- GitHub Actions run on `lin/integration` after the fix: TODO: evidence (run link).
