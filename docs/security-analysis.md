# Security analysis: Slither and coverage (tasks P1-4, P2-7)

First written for P1-4 on branch `lin/docs/security-analysis` (cut from origin/main). Re-run for P2-7 on 2026-11-04 on branch `lin/docs/testing`, cut from `origin/lin/integration` at `3159dec`. That code adds `OutcomeOrderBook` (P2-5), the re-entrancy tests in `test/MarketReentrancy.t.sol` (P1-6) and the stateful invariant suite in `test/invariant/` (P1-2). All numbers below are copied from real runs of the commands in "Reproduce" on that commit. No file in `contracts/src` was changed for this re-run.

## 1. Slither

- Tool: Slither **0.11.6** (`slither-analyzer`, installed with pip in a throwaway venv outside the repo; `slither --version` printed `0.11.6`).
- Compiler: solc 0.8.28 via `forge build` (Foundry forge 1.8.5), Slither uses the Foundry build-info.
- Command (run from `contracts/`), the same as for P1-4:

```
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
```

- Excluded: `lib/` (OpenZeppelin, forge-std), `test/`, `script/`. `--exclude-dependencies` drops findings located in dependencies. `src/mocks/` was left in. In the P1-4 run, a second run with `src/mocks` also filtered gave the same count, so the mocks have no findings. None of the 23 results below is in `src/mocks/`.
- Scope: every file in `contracts/src`: `ChainlinkResolver`, `Market`, `MarketFactory`, `OptimisticResolver`, `OutcomeOrderBook`, `OutcomeToken`, `libraries/`, `interfaces/` and `mocks/`.
- Output line (P2-7 run, 2026-11-04): `. analyzed (52 contracts with 102 detectors), 23 result(s) found`. The P1-4 run printed `50 contracts`, `21 result(s)`. The two extra contracts are `OutcomeOrderBook` and `IOutcomeOrderBook`.
- The JSON report (`--json`) agrees: `success: true`, 23 entries (6 Medium, 12 Low, 5 Informational; see table).
- Exit code: the shell got a non-zero code (127 in Git Bash) although the run succeeded. Slither 0.11.6 defaults to `--fail-pedantic` and calls `sys.exit(-1)` when there is any finding. A CI step would need `--fail-none` or a higher `--fail-*` level to pass with these accepted findings.

### Note on the Session 3 run (12 results)

An earlier run reported 12 results. The P1-4 run reported 21 on the code at that time. I could not reproduce the 12, so I do not know the cause (different Slither version, detector set or filters are possible, but I did not check). The count differs because each timestamp and unused-return location is a separate result here. All 21 were triaged against the code at the time. Their locations are unchanged in the P2-7 run.

### What changed since P1-4

- **New results (2)**, both in the order book code. Both are false positives or justified naming (rows 22 and 23):
  - `uninitialized-local`: `OutcomeOrderBook.listingsOf`, local `n` (Medium/Medium).
  - `naming-convention`: `IOutcomeOrderBook.PRICE_SCALE()` (Informational/High).
- **Old results (21)**: all present again at the same file and line numbers (the code of these contracts did not change). Row numbers 1-21 are kept from P1-4. The decisions are the same. Rows 1, 9 and 21 now point to tests that were merged after P1-4.
- No finding from Slither is a real, exploitable issue.

### Findings table

Impact/confidence and line numbers are Slither's. For the two order book files Slither's line numbers are a few lines before the source line, so rows 22-23 give both. Decision: fix / justify / false positive (FP). "NEW" marks results that were not in the P1-4 run.

| # | Detector | Location | Severity | Decision | Reason (checked against current code) |
|---|----------|----------|----------|----------|--------------------------------------|
| 1 | reentrancy-no-eth | `Market.sell` (Market.sol 99-123): `yesPool`/`noPool` written via `_setPools` after `outcomeToken.safeTransferFrom` / `burnBatch` | Medium | FP | See section 1.1. Both calls go to the immutable, factory-deployed `OutcomeToken`. `safeTransferFrom(msg.sender -> Market)` only calls the `onERC1155Received` hook on the receiver, which is `Market` itself (`ERC1155Holder`, returns the selector, no state change). The `from` address is never called, and OZ `_burn` has no receiver hook. `sell` is `nonReentrant` (transient lock) and so are `buy`, `redeem`, `withdrawFees`, `withdrawLiquidity`. No attacker-controlled code runs in the window. Since P1-6: `test_SellCollateralCallbackCannotReenterSell` (`test/MarketReentrancy.t.sol`) uses a collateral token that calls the seller back and asserts the re-entry reverts with `ReentrancyGuardReentrantCall`. |
| 2 | unused-return | `ChainlinkResolver._priceAtClose`, `config.feed.getRoundData(roundId)` (ChainlinkResolver.sol 45-46) | Medium | FP | Only `answer` and `updatedAt` are needed; `roundId`, `startedAt`, `answeredInRound` are intentionally dropped. Returned values are validated right after (`updatedAt == 0`, `> closeTime`, staleness, `answer <= 0`). |
| 3 | unused-return | `ChainlinkResolver._priceAtClose`, `config.feed.latestRoundData()` (50-52) | Medium | FP | Only `latestRoundId` is used (compared with `roundId` to detect a later round). Other fields are not needed for that check. |
| 4 | unused-return | `ChainlinkResolver._nextRoundUpdatedAt`, `feed.getRoundData(roundId + 1)` (62-68) | Medium | FP | Only `updatedAt` is read; zero means "no such round" (documented in the NatSpec for OCR aggregators), and the code then tries the next phase. |
| 5 | unused-return | `ChainlinkResolver._nextRoundUpdatedAt`, `feed.getRoundData(nextPhaseFirstRound)` (67) | Medium | FP | Same as 4. `updatedAt == 0` is returned to the caller, where `nextUpdatedAt <= closeTime` is false, so "no next round" correctly means the roundId is not superseded. |
| 6 | events-maths | `Market.initialize` (Market.sol 51-76) writes `marketId`, `closeTime`, `yesPool`, `noPool` without an event | Low | Justify | `initialize` runs once, in the same transaction as `MarketFactory.createMarket`, which emits `MarketCreated` with `marketId`, `closeTime`, `initialLiquidity`. An event in the clone would duplicate it. |
| 7 | missing-zero-check | `Market.constructor`, `factory_` (Market.sol 47-48) | Low | Justify | Constructor is only called by `MarketFactory` with `address(this)` (MarketFactory.sol, `new Market(address(this), token, collateral)`). The factory itself rejects a zero collateral. A zero check would be harmless hardening but guards nothing reachable. |
| 8 | missing-zero-check | `OutcomeToken.constructor`, `factory_` (OutcomeToken.sol 21-24) | Low | Justify | Same: only deployed by the factory with `address(this)`. |
| 9 | reentrancy-benign | `Market.sell`: `accruedFees += fee` after the external calls (Market.sol 99-123) | Low | FP | Same call analysis as row 1: no reentrant entry point exists, and `nonReentrant` is on every state-changing trade/settlement function. Covered by the same P1-6 test as row 1. |
| 10 | reentrancy-events | `MarketFactory.createMarket` (MarketFactory.sol 46-84): `MarketCreated` emitted after `registerMarket` and `initialize` | Low | FP | Both external calls go to the factory's own `OutcomeToken` and to the clone it just created. Function is admin-only (`DEFAULT_ADMIN_ROLE`). Only an event follows the calls, so a reentrant call could at worst reorder events, and none can reenter. |
| 11 | timestamp | `ChainlinkResolver.configure`, `block.timestamp >= market.closeTime()` (24-25) | Low | Justify | Intended: configuration is refused once trading has closed. Validator timestamp drift (seconds) cannot matter against a market-level close time, and the check is owner-only. |
| 12 | timestamp | `Market.state` (Market.sol 189-195) | Low | Justify | The state machine is time-based by design. Boundaries are exact and disjoint: Open while `t < closeTime`, Closed for `closeTime <= t < closeTime + 7 days`, Cancelled from `closeTime + 7 days`. The invariant suite (P1-2) lands the clock exactly on these edges (`warpToEdge`) and checks `invariant_TIME_2_tradingOnlyWhileOpen`. |
| 13 | timestamp | `Market._requireTradable`, `deadline < block.timestamp` (275-281) | Low | Justify | User-supplied slippage deadline; `deadline == block.timestamp` is accepted, later reverts. Standard pattern. |
| 14 | timestamp | `MarketFactory._validate`, `p.closeTime <= block.timestamp` (84-99) | Low | Justify | Rejects a market that would start Closed. Owner/admin-only path. |
| 15 | timestamp | `OptimisticResolver.propose`, `windowEnd >= deadline` (36-58) | Low | Justify | Deliberately strict: at the deadline the market is already Cancelled, so a proposal whose window ends at the deadline could never finalize. (OptimisticResolver.sol has 100% branch coverage.) |
| 16 | timestamp | `OptimisticResolver.dispute`, `block.timestamp >= windowEnd` (58-69) | Low | Justify | Dispute only while `t < windowEnd`; `finalize` only at `t >= windowEnd`, so the two never overlap at the boundary. |
| 17 | timestamp | `OptimisticResolver.finalize`, `block.timestamp < windowEnd` (69-81) | Low | Justify | See 16. The window is hours/days long; seconds of drift are irrelevant. |
| 18 | naming-convention | `IMarket.FEE_BPS()` (IMarket.sol 108-109) | Informational | Justify | Interface mirrors the public `constant` getter in `Market`; constants are UPPER_CASE by convention, and renaming would change the public interface (tests, bot, web use it). |
| 19 | naming-convention | `IMarket.RESOLUTION_WINDOW()` (109-110) | Informational | Justify | Same as 18. |
| 20 | naming-convention | `IMarketFactory.MIN_LIQUIDITY()` (IMarketFactory.sol 51-52) | Informational | Justify | Same as 18. |
| 21 | unimplemented-functions | `OutcomeToken` does not implement `IOutcomeToken.totalSupply(uint256)` (OutcomeToken.sol 12-67) | Informational | FP | `OutcomeToken` does implement it: `totalSupply(uint256 id) public view override(ERC1155Supply, IOutcomeToken)` calls `super.totalSupply(id)`. Slither is confused by the double override. Confirmed in P1-4 with `forge inspect OutcomeToken methodIdentifiers`: `totalSupply(uint256)` -> `bd85b039`. It is also called on every run of the invariant suite (`invariant_COL_1_yesSupplyEqualsNoSupplyBeforeExits` compares the YES and NO supplies), and the contract is deployed in all 195 tests. |
| 22 | uninitialized-local (NEW) | `OutcomeOrderBook.listingsOf`, local `uint256 n;` (Slither: OutcomeOrderBook.sol 144-145; the declaration is on line 149) | Medium | FP | A Solidity local of a value type is always zero when declared; there is no "uninitialised" value to read. `n` is a counter that starts at 0 by intent, the same style as `uint256 touched;` and `uint256 i;` in the same file (Slither does not flag those because they are declared in a `for` header). The function is a `view` and holds no funds. `test_ListingsOfPagesInOrder` checks pages from the head and from a `startAfter` id, an empty page after the last listing and for `count` 0, and the `ListingNotFound` revert for an id that is not an open listing of the book. Writing `uint256 n = 0;` would silence the detector with no change in behaviour. |
| 23 | naming-convention (NEW) | `IOutcomeOrderBook.PRICE_SCALE()` (Slither: IOutcomeOrderBook.sol 83; the declaration is on line 85) | Informational | Justify | Same as 18: the getter mirrors `uint256 public constant PRICE_SCALE = 1e6` in `OutcomeOrderBook`. Renaming would change the order book's public interface. |

Totals: Medium 6 (rows 1-5, 22), Low 12 (rows 6-17), Informational 5 (rows 18-21, 23) = 23. Decisions: fix 0, justify 14 (rows 6-8, 11-20, 23), false positive 9 (rows 1-5, 9, 10, 21, 22).

### 1.1 The `Market.sell` finding, checked against the current code

Slither reports state writes after external calls in `sell` (current order: quote, `outcomeToken.safeTransferFrom(msg.sender, this, ...)`, `outcomeToken.burnBatch(this, ...)`, then `_setPools`, `accruedFees += fee`, `collateral.safeTransfer(msg.sender, collateralOut)`, event).

1. Who is called: `outcomeToken` is `immutable`, set in the `Market` constructor by `MarketFactory`, which deployed it. It is not user-supplied.
2. What hooks run: ERC-1155 `safeTransferFrom` invokes `onERC1155Received` on `to`, which is `address(this)` (inherits OZ `ERC1155Holder`, no state change). `from` is never called back. `burnBatch` makes no receiver call.
3. Reentry guard: `sell` has `nonReentrant` (`ReentrancyGuardTransient`). Every function that moves collateral or changes pools (`buy`, `sell`, `redeem`, `withdrawFees`, `withdrawLiquidity`) shares the same lock. The unguarded external functions are `initialize` (locked by `initializer`, factory only), `resolve` (arbitrator only, requires state Closed while `sell` requires Open, so they cannot both run) and views.
4. The last transfer, `collateral.safeTransfer`, happens after the state updates (checks-effects-interactions) and the collateral is the fixed 6-decimals token validated by the factory.

Conclusion: false positive. The finding is a "state written after call" pattern, not an exploitable path. One related note: in `buy`, `outcomeToken.safeTransferFrom(this, msg.sender, ...)` does call an attacker-controlled `onERC1155Received` on the buyer. Slither does not flag it because pools and fees are written before the call; the lock blocks reentry into all trade and settlement functions. The test helper `CallbackBuyer` in `test/MarketTrading.t.sol` tries to call `buy` again from its `onERC1155Received` hook and records that it was blocked.

Tests merged since P1-4 (P1-6, `test/MarketReentrancy.t.sol`) cover the collateral-callback paths too: a `HookToken` collateral calls the recipient after `transfer`, and the tests show that `sell` cannot re-enter `sell`, `redeem` cannot re-enter `redeem`, and `withdrawLiquidity` cannot re-enter itself or `redeem` (each asserts `ReentrancyGuardReentrantCall` and a single payout). The P1-6 mutation check removed `nonReentrant` from `redeem`, `sell` and `withdrawLiquidity` one at a time: 2, 1 and 2 tests failed (recorded in the project log, `actions.md` row S7-14).

### 1.2 `OutcomeOrderBook`: what Slither did not flag, checked by hand

Slither reported only rows 22 and 23 for the order book. I also read the external calls in `OutcomeOrderBook.sol` myself:

- **User-supplied `market`.** `list`, `buy` and `quoteBuy` call `market.marketId()` and `market.state()` on the address the caller passes, before they know it is a real market. Both are declared `view` in `IMarket`, so Solidity uses `STATICCALL` and a fake market cannot change state during them. `_requireFactoryMarket` then requires `factory.markets(market.marketId()) == address(market)`, so only a factory market gets past it. Tests: `test_RevertWhen_MarketFromAnotherFactory`, `test_RevertWhen_MarketImpersonatesFactoryId`.
- **Seller payments in a loop.** `buy` calls `collateral.safeTransferFrom(buyer, seller, cost)` once per listing it fills (`_take`). `collateral` is `market.collateral()` of a checked factory market, so it is the factory's 6-decimal token, not a user token. Each listing is updated (`remaining -= fill`, unlinked when empty) before its payment. `maxListings` caps the number of calls. The contract notes the residual risk: a seller blocked by the collateral (USDC blacklist) makes fills that reach that listing revert until the seller cancels (threat B-3 in `docs/threat-model.md`).
- **ERC-1155 hooks.** `list` pulls shares into the book (`to` is the book, an `ERC1155Holder`, so no outside hook runs). `buy` and `cancel` send shares to the caller, which runs the caller's `onERC1155Received`. Both send at the end, after all state changes, and all three functions share one `nonReentrant` lock. Tests: `test_RevertWhen_ReenteringBuyFromReceiver`, `test_RevertWhen_ReenteringCancelFromReceiver`, `test_RevertWhen_ReenteringListFromReceiver`. The P2-5 mutation check removed `nonReentrant` from `buy` (3 tests failed) and `_requireOpen(market)` from `buy` (3 tests failed) (`actions.md` row S7-45).
- **Escrow accounting.** Checked over random call sequences by `invariant_OB_1_escrowEqualsOpenListings`, `invariant_OB_3_bookHoldsNoCollateral` and `invariant_OB_4_buyersPayExactlyWhatSellersReceive` (P1-2). The P1-2 mutation that skipped `listing.remaining -= fill` failed OB-1 and OB-4 (`actions.md` row S7-65).

I found no exploitable issue in the order book.

## 2. Candidates for P1-5

No finding from Slither is a real, exploitable issue, so nothing here is a must-fix in `src/`. P1-5 is still `todo` in `work_plan.md`. Status of each item after the P2-7 re-run:

1. (Test gap, no code change) **Partly resolved.** P1-4 found three revert branches in `Market.sol` that no test took. After P1-2, the invariant suite covers one of them: `_quoteSell` line 238 `collateralOut == 0`. A coverage run without `test/invariant/` still misses it, so only the stateful suite reaches it. Still uncovered:
   - `_quoteBuy` line 218 `sharesOut == 0`. My reading of the code, not tested: this branch cannot be reached. `outcomePoolAfter = ceil(outcomePool * oppositePool / (oppositePool + net))`. With `net >= 1` the exact quotient is below `outcomePool`, so its ceiling is at most `outcomePool`, and `sharesOut = outcomePool + net - outcomePoolAfter >= net >= 1`. The line is a defensive check.
   - `_quoteSell` line 224 `oppositePool <= 1`. A sell can leave the opposite pool at exactly 1 (it removes at most `oppositePool - 1`), so a following sell would take this branch. No test builds that state. It needs a sell of a very large share amount against a small pool.
2. (Optional hardening) **Open.** Zero-address checks in `Market` and `OutcomeToken` constructors (rows 7-8). Not reachable today; cheap and silences the detector. Constructor change only, no interface change.
3. (Optional) **Open.** Suppress documented false positives in CI with `// slither-disable-next-line` comments, or a `slither.config.json`, so a future run shows only new findings. Rows 1, 9, 10, 21 and 22 are the candidates. Slither would also need `--fail-none` (or a level above the accepted findings) to exit 0 in CI.
4. (Design note, already documented) **Open, needs a team decision.** `withdrawFees` is allowed in a Cancelled market, so the creator keeps fees even when traders are settled at 50/50 (documented in `docs/market-creation-explained.md`, around line 411). I list it only so the team confirms it is intended. Other documented shortcuts also stay open: no L2 sequencer check in `ChainlinkResolver`, pushed bonds in `OptimisticResolver`.
5. (New, CI, not in `src/`) **Fixed 2026-11-04** on branch `lin/fix/ci-size-check`: CI now size-checks only deployable contracts (`forge build --sizes --skip './test/**' --skip './script/**'`); see AI log entry 8. Original finding: `forge build --sizes` exits 1 on this commit with `Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)`. The contract over the limit is the test handler `MarketHandler` (`test/invariant/MarketHandler.sol`, runtime 34,326 B, margin -9,750 B), added by P1-2. Every `src/` contract is under the limit: `forge build --sizes --skip './test/**' --skip './script/**'` exits 0, and the largest is `Market` at 13,677 B. The CI workflow runs `forge build --sizes` before `forge test`, so the contracts job should fail at "Build" on `lin/integration`. I did not check this on GitHub. Possible fixes: build sizes only for `src/` in CI, or split `MarketHandler` into smaller handlers. The size limit does not matter for a test contract that is never deployed to a real chain, and `forge test` still runs it locally.

The P1-6 re-entrancy tests (`test/MarketReentrancy.t.sol`) did not close a numbered item above. They back the false-positive reasoning for rows 1 and 9 with tests (section 1.1).

## 3. Coverage

Command: `forge coverage --report summary` (from `contracts/`), run with `--report lcov --report-file <scratchpad>/p27_lcov.info` in the same call to find uncovered lines. No `--ir-minimum` was needed (no stack-too-deep). The run includes the invariant suite and took 49.8 s wall time. It ends with `Ran 9 test suites in 42.84s (54.43s CPU time): 195 tests passed, 0 failed, 0 skipped (195 total tests)`. Table as printed (percent with covered/total):

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
| test/invariant/ResolverHandler.sol | 97.56% (120/123) | 90.96% (171/188) | 56.10% (23/41) | 100.00% (13/13) |
| **Total** | **88.26% (970/1099)** | **86.66% (1254/1447)** | **71.84% (199/277)** | **90.17% (156/173)** |

The Total row includes scripts and test helper files (handlers, malicious tokens), so it is not a measure of the production code. For the six production files in `src/` (five contracts plus the library, now also `OutcomeOrderBook`), lines and functions are 100%. Branches are 100% except `Market.sol` (30/32).

Compared with P1-4 (`137 tests`): `src/Market.sol` statements went from 98.39% (183/186) to 98.92% (184/186) and branches from 90.62% (29/32) to 93.75% (30/32). `src/OutcomeOrderBook.sol` is new and fully covered. The other `src/` rows are unchanged.

A second run without the invariant suite (`forge coverage --no-match-path 'test/invariant/*' --report summary`, 194 tests) gives the same `src/` numbers except `src/Market.sol` statements 98.39% (183/186) and branches 90.62% (29/32). `src/OutcomeOrderBook.sol` stays at 100% on all four from its unit tests alone.

### Uncovered branches and code

Found from the lcov report (entries with zero hits):

- `src/Market.sol`: 2 of 32 branches uncovered, both revert branches never taken:
  - line 218, `_quoteBuy`: `if (sharesOut == 0) revert ZeroOutput();` (unreachable by my reading, see section 2 item 1)
  - line 224, `_quoteSell`: `if (oppositePool <= 1) revert ZeroOutput();`
  - The 2 uncovered statements in Market.sol are these same reverts.
  - Line 238, `_quoteSell` `if (collateralOut == 0) revert ZeroOutput();`, was uncovered in P1-4 and is now covered by the invariant suite only.
- `src/mocks/MockAggregator.sol`: `decimals()`, `description()`, `version()` never called (lines 23-32); they are interface filler for the test mock.
- `script/*.s.sol`: no tests; deployment scripts, not run by `forge test`. This now includes `DeployOrderBook.s.sol`.
- Test helper files (`test/MarketTrading.t.sol`, `test/MarketReentrancy.t.sol`, `test/invariant/*`): their uncovered lines are helper code, for example `CallbackBuyer.onERC1155BatchReceived` and `supportsInterface`, and handler branches that only run for some random sequences. They are not production code.
- All other `src/` contracts have 100% branch coverage.

## 4. Reproduce

Venv outside the repo (scratchpad), Slither version printed by `slither --version` was `0.11.6`:

```
python -m venv <scratchpad>/slither-venv
<scratchpad>/slither-venv/Scripts/python -m pip install slither-analyzer solc-select
cd contracts
export PATH="$HOME/.foundry/bin:$PATH"          # forge on PATH (Slither calls it)
<scratchpad>/slither-venv/Scripts/slither --version
<scratchpad>/slither-venv/Scripts/slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
# JSON report: add  --json <scratchpad>/slither.json
~/.foundry/bin/forge build                       # Slither leaves only a src/ build behind, see below
~/.foundry/bin/forge test
~/.foundry/bin/forge coverage --report summary
~/.foundry/bin/forge coverage --report lcov --report-file <scratchpad>/lcov.info   # for uncovered branches (BRDA lines ending ,0)
~/.foundry/bin/forge coverage --no-match-path 'test/invariant/*' --report summary  # unit and fuzz tests only
```

Slither runs `forge clean` and `forge build --build-info --skip ./test/** ./script/** --force`, so `contracts/out` and `cache` are rebuilt without the tests; both are git-ignored. Run `forge build` or `forge test` afterwards. On Linux/macOS use `bin/slither` instead of `Scripts/slither`. For P2-7 the venv from the P1-4 session was reused (still Slither 0.11.6).
