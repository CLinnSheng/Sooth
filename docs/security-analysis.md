# Security analysis: Slither and coverage (task P1-4)

Branch `lin/docs/security-analysis`, cut from origin/main. All numbers below are copied from real runs of the commands in "Reproduce". Code was checked as it is on this branch (`contracts/src/*.sol`).

## 1. Slither

- Tool: Slither **0.11.6** (`slither-analyzer`, installed with pip in a throwaway venv outside the repo).
- Compiler: solc 0.8.28 via `forge build` (Foundry forge 1.8.5), Slither uses the Foundry build-info.
- Command (run from `contracts/`):

```
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
```

- Excluded: `lib/` (OpenZeppelin, forge-std), `test/`, `script/`. `--exclude-dependencies` drops findings located in dependencies. `src/mocks/` was left in; a second run with `src/mocks` also filtered gave the same result count, so the mocks have no findings.
- Output line: `INFO:Slither:. analyzed (50 contracts with 102 detectors), 21 result(s) found`.
- The JSON report agrees: 21 entries (5 Medium, 12 Low, 4 Informational; see table).

### Note on the Session 3 run (12 results)

An earlier run reported 12 results. This run reports 21 on the current code. I could not reproduce the 12, so I do not know the cause (different Slither version, detector set or filters are possible, but I did not check). The count differs because each timestamp and unused-return location is a separate result here. All 21 are triaged below against the current code.

### Findings table

Impact/confidence are Slither's. Decision: fix / justify / false positive (FP).

| # | Detector | Location | Severity | Decision | Reason (checked against current code) |
|---|----------|----------|----------|----------|--------------------------------------|
| 1 | reentrancy-no-eth | `Market.sell` (Market.sol 99-123): `yesPool`/`noPool` written via `_setPools` after `outcomeToken.safeTransferFrom` / `burnBatch` | Medium | FP | See section 1.1. Both calls go to the immutable, factory-deployed `OutcomeToken`. `safeTransferFrom(msg.sender -> Market)` only calls the `onERC1155Received` hook on the receiver, which is `Market` itself (`ERC1155Holder`, returns the selector, no state change). The `from` address is never called, and OZ `_burn` has no receiver hook. `sell` is `nonReentrant` (transient lock) and so are `buy`, `redeem`, `withdrawFees`, `withdrawLiquidity`. No attacker-controlled code runs in the window. |
| 2 | unused-return | `ChainlinkResolver._priceAtClose`, `config.feed.getRoundData(roundId)` (ChainlinkResolver.sol 45-46) | Medium | FP | Only `answer` and `updatedAt` are needed; `roundId`, `startedAt`, `answeredInRound` are intentionally dropped. Returned values are validated right after (`updatedAt == 0`, `> closeTime`, staleness, `answer <= 0`). |
| 3 | unused-return | `ChainlinkResolver._priceAtClose`, `config.feed.latestRoundData()` (50-52) | Medium | FP | Only `latestRoundId` is used (compared with `roundId` to detect a later round). Other fields are not needed for that check. |
| 4 | unused-return | `ChainlinkResolver._nextRoundUpdatedAt`, `feed.getRoundData(roundId + 1)` (62-68) | Medium | FP | Only `updatedAt` is read; zero means "no such round" (documented in the NatSpec for OCR aggregators), and the code then tries the next phase. |
| 5 | unused-return | `ChainlinkResolver._nextRoundUpdatedAt`, `feed.getRoundData(nextPhaseFirstRound)` (67) | Medium | FP | Same as 4. `updatedAt == 0` is returned to the caller, where `nextUpdatedAt <= closeTime` is false, so "no next round" correctly means the roundId is not superseded. |
| 6 | events-maths | `Market.initialize` (Market.sol 51-76) writes `marketId`, `closeTime`, `yesPool`, `noPool` without an event | Low | Justify | `initialize` runs once, in the same transaction as `MarketFactory.createMarket`, which emits `MarketCreated` with `marketId`, `closeTime`, `initialLiquidity`. An event in the clone would duplicate it. |
| 7 | missing-zero-check | `Market.constructor`, `factory_` (Market.sol 47-48) | Low | Justify | Constructor is only called by `MarketFactory` with `address(this)` (MarketFactory.sol, `new Market(address(this), token, collateral)`). The factory itself rejects a zero collateral. A zero check would be harmless hardening but guards nothing reachable. |
| 8 | missing-zero-check | `OutcomeToken.constructor`, `factory_` (OutcomeToken.sol 21-24) | Low | Justify | Same: only deployed by the factory with `address(this)`. |
| 9 | reentrancy-benign | `Market.sell`: `accruedFees += fee` after the external calls (Market.sol 99-123) | Low | FP | Same call analysis as row 1: no reentrant entry point exists, and `nonReentrant` is on every state-changing trade/settlement function. |
| 10 | reentrancy-events | `MarketFactory.createMarket` (MarketFactory.sol 46-84): `MarketCreated` emitted after `registerMarket` and `initialize` | Low | FP | Both external calls go to the factory's own `OutcomeToken` and to the clone it just created. Function is admin-only (`DEFAULT_ADMIN_ROLE`). Only an event follows the calls, so a reentrant call could at worst reorder events, and none can reenter. |
| 11 | timestamp | `ChainlinkResolver.configure`, `block.timestamp >= market.closeTime()` (24-25) | Low | Justify | Intended: configuration is refused once trading has closed. Validator timestamp drift (seconds) cannot matter against a market-level close time, and the check is owner-only. |
| 12 | timestamp | `Market.state` (Market.sol 189-195) | Low | Justify | The state machine is time-based by design. Boundaries are exact and disjoint: Open while `t < closeTime`, Closed for `closeTime <= t < closeTime + 7 days`, Cancelled from `closeTime + 7 days`. |
| 13 | timestamp | `Market._requireTradable`, `deadline < block.timestamp` (275-281) | Low | Justify | User-supplied slippage deadline; `deadline == block.timestamp` is accepted, later reverts. Standard pattern. |
| 14 | timestamp | `MarketFactory._validate`, `p.closeTime <= block.timestamp` (84-99) | Low | Justify | Rejects a market that would start Closed. Owner/admin-only path. |
| 15 | timestamp | `OptimisticResolver.propose`, `windowEnd >= deadline` (36-58) | Low | Justify | Deliberately strict: at the deadline the market is already Cancelled, so a proposal whose window ends at the deadline could never finalize. (OptimisticResolver.sol has 100% branch coverage.) |
| 16 | timestamp | `OptimisticResolver.dispute`, `block.timestamp >= windowEnd` (58-69) | Low | Justify | Dispute only while `t < windowEnd`; `finalize` only at `t >= windowEnd`, so the two never overlap at the boundary. |
| 17 | timestamp | `OptimisticResolver.finalize`, `block.timestamp < windowEnd` (69-81) | Low | Justify | See 16. The window is hours/days long; seconds of drift are irrelevant. |
| 18 | naming-convention | `IMarket.FEE_BPS()` (IMarket.sol 108-109) | Informational | Justify | Interface mirrors the public `constant` getter in `Market`; constants are UPPER_CASE by convention, and renaming would change the public interface (tests, bot, web use it). |
| 19 | naming-convention | `IMarket.RESOLUTION_WINDOW()` (109-110) | Informational | Justify | Same as 18. |
| 20 | naming-convention | `IMarketFactory.MIN_LIQUIDITY()` (IMarketFactory.sol 51-52) | Informational | Justify | Same as 18. |
| 21 | unimplemented-functions | `OutcomeToken` does not implement `IOutcomeToken.totalSupply(uint256)` (OutcomeToken.sol 12-67) | Informational | FP | `OutcomeToken` does implement it: `totalSupply(uint256 id) public view override(ERC1155Supply, IOutcomeToken)` calls `super.totalSupply(id)`. Slither is confused by the double override. Confirmed with `forge inspect OutcomeToken methodIdentifiers`: `totalSupply(uint256)` -> `bd85b039`. The contract is also deployed in all 137 tests. |

Totals: Medium 5 (rows 1-5), Low 12 (rows 6-17), Informational 4 (rows 18-21) = 21. Decisions: fix 0, justify 13 (rows 6-8, 11-20), false positive 8 (rows 1-5, 9, 10, 21).

### 1.1 The `Market.sell` finding, checked against the current code

Slither reports state writes after external calls in `sell` (current order: quote, `outcomeToken.safeTransferFrom(msg.sender, this, ...)`, `outcomeToken.burnBatch(this, ...)`, then `_setPools`, `accruedFees += fee`, `collateral.safeTransfer(msg.sender, collateralOut)`, event).

1. Who is called: `outcomeToken` is `immutable`, set in the `Market` constructor by `MarketFactory`, which deployed it. It is not user-supplied.
2. What hooks run: ERC-1155 `safeTransferFrom` invokes `onERC1155Received` on `to`, which is `address(this)` (inherits OZ `ERC1155Holder`, no state change). `from` is never called back. `burnBatch` makes no receiver call.
3. Reentry guard: `sell` has `nonReentrant` (`ReentrancyGuardTransient`). Every function that moves collateral or changes pools (`buy`, `sell`, `redeem`, `withdrawFees`, `withdrawLiquidity`) shares the same lock. The unguarded external functions are `initialize` (locked by `initializer`, factory only), `resolve` (arbitrator only, requires state Closed while `sell` requires Open, so they cannot both run) and views.
4. The last transfer, `collateral.safeTransfer`, happens after the state updates (checks-effects-interactions) and the collateral is the fixed 6-decimals token validated by the factory.

Conclusion: false positive. The finding is a "state written after call" pattern, not an exploitable path. One related note: in `buy`, `outcomeToken.safeTransferFrom(this, msg.sender, ...)` does call an attacker-controlled `onERC1155Received` on the buyer. Slither does not flag it because pools and fees are written before the call; the lock blocks reentry into all trade and settlement functions. The test helper `CallbackBuyer` in `test/MarketTrading.t.sol` tries to call `buy` again from its `onERC1155Received` hook and records that it was blocked.

## 2. Candidates for P1-5

No finding from Slither is a real, exploitable issue, so nothing here is a must-fix. Items I judge worth doing, in priority order:

1. (Test gap, no code change) Three revert branches in `Market.sol` are never taken by any test; see section 3. Add a test for each: `_quoteBuy` line 218 `sharesOut == 0`, `_quoteSell` line 224 `oppositePool <= 1`, `_quoteSell` line 238 `collateralOut == 0`. The user-facing error `ZeroOutput` is only tested once (test/MarketTrading.t.sol line 303), which exercises the `net == 0` check at line 213.
2. (Optional hardening) Zero-address checks in `Market` and `OutcomeToken` constructors (rows 7-8). Not reachable today; cheap and silences the detector. Constructor change only, no interface change.
3. (Optional) Suppress documented false positives in CI with `// slither-disable-next-line` comments, or a `slither.config.json`, so a future run shows only new findings. Rows 1, 9, 10, 21 are the candidates.
4. (Design note, already documented) `withdrawFees` is allowed in a Cancelled market, so the creator keeps fees even when traders are settled at 50/50 (documented in `docs/market-creation-explained.md`, around line 411). I list it only so the team confirms it is intended. Other documented shortcuts also stay open: no L2 sequencer check in `ChainlinkResolver`, pushed bonds in `OptimisticResolver`.

## 3. Coverage

Command: `forge coverage --report summary` (from `contracts/`). Run ends with `Ran 5 test suites ...: 137 tests passed, 0 failed, 0 skipped (137 total tests)`. Table as printed (percent with covered/total):

| File | % Lines | % Statements | % Branches | % Funcs |
|------|---------|--------------|------------|---------|
| script/CreateMarket.s.sol | 0.00% (0/23) | 0.00% (0/31) | 0.00% (0/7) | 0.00% (0/3) |
| script/DeployChainlinkResolver.s.sol | 0.00% (0/8) | 0.00% (0/8) | 0.00% (0/2) | 0.00% (0/1) |
| script/DeployMarketFactory.s.sol | 0.00% (0/16) | 0.00% (0/23) | 0.00% (0/5) | 0.00% (0/2) |
| script/DeployOptimisticResolver.s.sol | 0.00% (0/13) | 0.00% (0/15) | 0.00% (0/2) | 0.00% (0/1) |
| script/ResolveChainlinkMarket.s.sol | 0.00% (0/25) | 0.00% (0/36) | 0.00% (0/10) | 0.00% (0/2) |
| src/ChainlinkResolver.sol | 100.00% (36/36) | 100.00% (55/55) | 100.00% (15/15) | 100.00% (7/7) |
| src/Market.sol | 100.00% (152/152) | 98.39% (183/186) | 90.62% (29/32) | 100.00% (27/27) |
| src/MarketFactory.sol | 100.00% (26/26) | 100.00% (34/34) | 100.00% (7/7) | 100.00% (3/3) |
| src/OptimisticResolver.sol | 100.00% (62/62) | 100.00% (85/85) | 100.00% (17/17) | 100.00% (9/9) |
| src/OutcomeToken.sol | 100.00% (28/28) | 100.00% (29/29) | 100.00% (3/3) | 100.00% (9/9) |
| src/libraries/OutcomeTokenId.sol | 100.00% (2/2) | 100.00% (1/1) | N/A (0/0) | 100.00% (1/1) |
| src/mocks/MockAggregator.sol | 57.14% (8/14) | 70.00% (7/10) | 100.00% (1/1) | 50.00% (3/6) |
| src/mocks/MockUSDC.sol | 100.00% (5/5) | 100.00% (2/2) | N/A (0/0) | 100.00% (3/3) |
| test/MarketFactory.t.sol | 100.00% (3/3) | 100.00% (1/1) | N/A (0/0) | 100.00% (2/2) |
| test/MarketTrading.t.sol | 76.92% (20/26) | 66.67% (14/21) | 100.00% (5/5) | 71.43% (5/7) |
| **Total** | **77.90% (342/439)** | **76.54% (411/537)** | **72.64% (77/106)** | **83.13% (69/83)** |

The Total row includes scripts and test files. For `src/` production contracts (the five contracts plus the library), lines and functions are 100%.

### Uncovered branches and code

Found from an lcov report (`forge coverage --report lcov`, entries with zero hits):

- `src/Market.sol` 3 of 32 branches uncovered, all revert branches never taken:
  - line 218, `_quoteBuy`: `if (sharesOut == 0) revert ZeroOutput();`
  - line 224, `_quoteSell`: `if (oppositePool <= 1) revert ZeroOutput();`
  - line 238, `_quoteSell`: `if (collateralOut == 0) revert ZeroOutput();`
  - The 3 uncovered statements in Market.sol are these same reverts.
- `src/mocks/MockAggregator.sol`: `decimals()`, `description()`, `version()` never called (lines 23-32); they are interface filler for the test mock.
- `script/*.s.sol`: no tests; deployment scripts, not run by `forge test`.
- `test/MarketTrading.t.sol`: helper `CallbackBuyer.onERC1155BatchReceived` and `supportsInterface` never called (test helper code).
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
~/.foundry/bin/forge test
~/.foundry/bin/forge coverage --report summary
~/.foundry/bin/forge coverage --report lcov --report-file <scratchpad>/lcov.info   # for uncovered branches (BRDA lines ending ,0)
```

Slither runs `forge clean` and `forge build --force`, so `contracts/out` and `cache` are rebuilt; both are git-ignored. On Linux/macOS use `bin/slither` instead of `Scripts/slither`.
