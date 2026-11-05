# Cross-explanation notes

One page per component, so any team member can explain the whole system (backlog E10-7). Each page has
a 60-second explanation, likely examiner questions with answers, and the files to open. Written from
`lin/integration` at `7d7b76f` on 2026-11-05. Design reasons are in [final-report.md](final-report.md);
AI use is in [ai-audit-report.md](ai-audit-report.md).

How to use: each member reads all pages, then explains one page they did **not** build to someone else,
who asks the questions below. TODO(team): session date, who explained which page, and gaps found.

| # | Component | Main files |
|---|---|---|
| 1 | Whole system | `docs/architecture.md` |
| 2 | Market creation (factory, clones, outcome token) | `MarketFactory.sol`, `Market.sol`, `OutcomeToken.sol` |
| 3 | Trading engine (AMM) | `Market.sol` |
| 4 | Settlement and payouts | `Market.sol` |
| 5 | Optimistic resolver | `OptimisticResolver.sol` |
| 6 | Chainlink resolver | `ChainlinkResolver.sol` |
| 7 | Order book (Bonus 1) | `OutcomeOrderBook.sol` |
| 8 | Website | `web/src/` |
| 9 | Bot | `bot/sooth_bot/` |
| 10 | Testing and security | `contracts/test/`, `docs/testing.md` |
| 11 | Deployment and CI | `contracts/script/`, `.github/workflows/ci.yml` |

---

## 1. Whole system

**Explain in 60 seconds.** Sooth is a YES/NO prediction market on Base Sepolia. An admin creates a market
with a question, a close time and an arbitrator, and seeds it with mock USDC. Each market is its own
small contract with a constant-product pool, so it always quotes a price, and the YES price is the
crowd's probability. Every YES+NO pair is backed by exactly 1 USDC, so the market can always pay. After
close, the arbitrator reports the outcome: a Chainlink feed for prices, or a bonded proposal that anyone
can dispute, with a judge for disputes. Winners redeem 1 USDC per share. If nobody reports within 7 days,
the market cancels and every share pays half. Holders can also sell to each other on an order book. A
website and a bot sit on top, but neither can move funds by itself.

| Question | Answer |
|---|---|
| What does the blockchain guarantee? | Settlement: custody, exact payouts, once. Not the truth of the outcome (trust statement, `threat-model.md` §3) |
| What is the oracle problem and how do you handle it? | A contract cannot see the world. We make reporting accountable (bonds, challenge window, judge, Chainlink round checks) and add a timeout so funds are never stuck. It is reduced, not solved |
| What is on chain vs off chain? | Funds, prices, states, outcomes, bonds on chain. Spec display, history, charts, the LLM and the bot off chain (`architecture.md` §2) |
| Which requirements and bonuses are met? | All three core features; Bonus 1 built but not deployed yet; Bonus 2 and 3 skipped (`final-report.md` §3) |
| Is there a backend? | No. The website reads the chain directly; the bot is optional |

Files: `docs/architecture.md`, `docs/final-report.md`.

---

## 2. Market creation

**Explain in 60 seconds.** `MarketFactory.createMarket` is admin-only (`DEFAULT_ADMIN_ROLE`). It checks
the inputs (non-zero arbitrator, future `closeTime`, 50/50 start, seed at least `MIN_LIQUIDITY` = 10 USDC,
non-empty spec), then deploys an EIP-1167 clone of the `Market` implementation, registers the market's
two token ids on the shared ERC-1155 `OutcomeToken`, moves the seed collateral from the admin to the
clone and initialises it. The clone mints the same amount of YES and NO into its own pool. The spec JSON
is emitted in `MarketCreated`; only its `keccak256` is stored as `specHash`.

| Question | Answer |
|---|---|
| Why clones instead of one big contract? | Funds are isolated per market, and a clone is cheap (about 45 bytes) |
| What is the classic clone bug and how did you stop it? | Someone calling `initialize` first. Only the factory can initialise (`NotFactory`), `initializer` runs once, and the implementation calls `_disableInitializers()` |
| How are token ids made? | `keccak256(abi.encode(marketId, outcome))` in `OutcomeTokenId`. Only the owning market can mint or burn an id (`_requireMarketOf`) |
| Why `balance >= initialLiquidity`, not `==`? | Clone addresses are predictable; with `==`, anyone could block creation by sending 1 unit first (C-13) |
| Can the creator be the arbitrator? | Yes (`test_CreateMarket_ArbitratorCanBeCreator`). That is a trust risk documented as R-4 |
| Why must the start be 50/50? | `_validate` only accepts `initialYesProbabilityBps = 5000`: equal pools from complete sets give 0.5 |
| Where is the market question? | Full spec in the `MarketCreated` log; hash on chain. Not on IPFS (P3-1 open) |

Files: `contracts/src/MarketFactory.sol`, `contracts/src/Market.sol` (`initialize`),
`contracts/src/OutcomeToken.sol`, `contracts/src/libraries/OutcomeTokenId.sol`,
`contracts/test/MarketFactory.t.sol`, `docs/market-creation-explained.md`.

---

## 3. Trading engine (AMM)

**Explain in 60 seconds.** Each market is a two-outcome constant-product pool. To buy YES with `c` USDC,
the market takes a 1% fee (rounded up), mints `n = c - fee` YES and `n` NO, adds them to the pools and
gives the trader YES out of the pool so that `yesPool × noPool` does not fall. To sell, the market takes
the shares and binary-searches the largest amount of YES+NO pairs it can burn while keeping the product,
then pays that minus the fee. The price is `priceYes = noPool / (yesPool + noPool)`. Every trade has a
minimum output and a deadline. Trading only works while the market is `Open`.

| Question | Answer |
|---|---|
| Buy formula? | `aAfter = ceil(a × b / (b + n))`, `sharesOut = a + n - aAfter` (`_quoteBuy`) |
| Why a binary search for sell? | The exact inverse needs a square root; integer search for the largest `g` with `(a + s - g)(b - g) >= ab` is simple and always rounds for the pool (`_quoteSell`) |
| Who wins on rounding? | The pool. Fee and pool-after round up, sell rounds down. `testFuzz_BuyThenSellCannotProfit`, `invariant_COL_6_...` |
| Why constant product, not LMSR? | No `exp`/`ln`, simple integer maths, always liquid; the seed is the creator's maximum loss (`final-report.md` §4.4) |
| Where do fees go? | `accruedFees`, outside the pools, paid to `creator` by `withdrawFees` after close |
| Can a donation move the price? | No. Pools are stored values, not balances (`test_DonationsDoNotChangeRecordedReserves`) |
| Front-running? | Possible, limited by `minSharesOut` / `minCollateralOut` and `deadline`. Website default slippage 1% (C-15) |
| Reentrancy? | `nonReentrant` (transient) on every money function; state written before transfers. The buyer's ERC-1155 hook cannot re-enter (`test_BuyerReceiverCannotReenterMarket`) |

Files: `contracts/src/Market.sol` (`buy`, `sell`, `_quoteBuy`, `_quoteSell`, `_fee`),
`contracts/test/MarketTrading.t.sol`, `docs/trading-engine.md`, `web/src/mock.ts` (browser quotes).

---

## 4. Settlement and payouts

**Explain in 60 seconds.** A market's state comes from the clock: `Open` before `closeTime`, `Closed`
until `closeTime + 7 days`, then `Cancelled`, unless the arbitrator called `resolve` while `Closed`, which
writes `Resolved`. After settlement, `redeem` burns all of a holder's YES and NO and pays 1 per winning
share, or half per share if cancelled (rounded down). `withdrawLiquidity` pays the creator the value of
the pool's own shares, once. `withdrawFees` pays accrued fees, from close on. Anyone can trigger the
creator's withdrawals, but the money always goes to `creator`.

| Question | Answer |
|---|---|
| Why derive `Closed` and `Cancelled` instead of writing them? | No keeper transaction is needed; the state is always right at the exact second |
| Can a market be resolved twice? | No: `resolve` requires `Closed`, and after it the state is `Resolved` (`test_RevertWhen_ResolvingTwice`, `invariant_RES_1_...`) |
| Can payouts exceed the collateral? | No. Every pair is backed by 1 unit; cancelled rounds down, leaving at most 2 raw units of dust (K-8, `invariant_RED_1_...`) |
| Double redeem? | `redeem` burns the shares first; a second call has nothing to pay (`test_RevertWhen_RedeemingTwice`) |
| Why 50/50 on cancel? | With no outcome there is no fair winner; half per share returns each complete set and never overpays |
| Does the creator keep fees in a cancelled market? | Yes (K-7). Intended, to be confirmed by the team |

Files: `contracts/src/Market.sol` (`state`, `resolve`, `redeem`, `withdrawLiquidity`, `withdrawFees`,
`_settlementValue`), `contracts/test/MarketResolution.t.sol`, `docs/invariants.md` §5.

---

## 5. Optimistic resolver

**Explain in 60 seconds.** For questions without a price feed. After close, anyone can `propose` an
outcome with a bond (10 mUSDC deployed). For 2 hours anyone can `dispute` by posting the same bond. If
nobody disputes, anyone calls `finalize`: the market resolves and the proposer gets the bond back. If
disputed, the judge (the resolver's `owner`) calls `rule`, the market resolves and the side the judge
backs gets both bonds. If the market cancels first, `refund` returns every bond. One request per market.

| Question | Answer |
|---|---|
| Why bonds? | A wrong proposal costs money if disputed; a frivolous dispute costs money too |
| What stops a proposal that cannot finish in time? | `propose` reverts with `ProposalTooLate` if `now + challengeWindow >= resolutionDeadline()` |
| Who is the judge and is that safe? | One key (`Ownable2Step`, can move to a multisig). The judge could dispute and rule itself, so it controls optimistic markets (R-3). Accepted for testnet |
| What if a bond recipient is blacklisted? | Bonds are pushed, so that settlement reverts (K-1). Pull payments were planned (P2-2) and skipped |
| Can the judge run out of time? | Yes: a dispute at the last second leaves seconds before the deadline (K-2, accepted). The market then cancels and `refund` frees bonds |
| Is there a reward for proposing? | No, only the bond back (K-10) |

Files: `contracts/src/OptimisticResolver.sol`, `contracts/test/OptimisticResolver.t.sol`,
`contracts/test/EndToEnd.t.sol` (E2E-4 to E2E-8b), `docs/optimistic-resolver.md`.

---

## 6. Chainlink resolver

**Explain in 60 seconds.** For price questions. Before close, the resolver's owner sets the feed,
threshold, comparison (`Below` or `Above`) and maximum staleness, once. After close, anyone calls
`resolve(market, roundId)`. The contract accepts the round only if it was updated at or before
`closeTime`, is not older than `maxStaleness`, has a positive price, and is the latest round or the next
round started after close. So the caller cannot pick a favourable price. Ties resolve NO.

| Question | Answer |
|---|---|
| Why does the caller pass a round id? | Searching rounds on chain is costly; the caller searches off chain and the contract only verifies |
| How do you know the round was live at close? | The next round (`roundId + 1`, or round 1 of the next phase) must have `updatedAt > closeTime` (`RoundSuperseded` otherwise) |
| Why no `try/catch` on feed reads? | A caught out-of-gas would skip the next-round check and let a caller settle on an old price |
| L2 sequencer risk? | No uptime check (no feed on Base Sepolia); staleness covers it in practice (K-3) |
| What if it is never configured? | `resolve` reverts `NotConfigured`; the market cancels at the deadline (R-11) |

Files: `contracts/src/ChainlinkResolver.sol`, `contracts/test/ChainlinkResolver.t.sol`,
`contracts/script/ResolveChainlinkMarket.s.sol`, `docs/chainlink-resolver.md`.

---

## 7. Order book (Bonus 1)

**Explain in 60 seconds.** A secondary market where holders sell existing shares to other users at a
price they choose. `list` moves the shares into escrow in `OutcomeOrderBook` and inserts the listing in a
price-sorted linked list, oldest first at equal price. `buy` takes a size, a maximum price and a maximum
number of listings, and fills from the cheapest listing, paying each seller `ceil(fill × price / 1e6)`
directly. `cancel` returns unsold shares in any market state. It works only while the market is `Open`,
charges no fee, and needs no change to `Market`.

| Question | Answer |
|---|---|
| Why is this a "secondary derivative market"? | A share is a derivative of the event. The AMM creates shares (primary); the book trades existing ones between users (secondary) |
| Why stop at close, not at resolution? | Fairness (team decision Q2): after close some traders may know the result |
| Why listings only, no bids? | Time (decision Q1). Bids are future work |
| Why round the cost up? | So no fill is ever free (`test_Buy_RoundsCostUpSoNoFillIsFree`) |
| Gas limits? | `maxListings` caps `buy`: 157,339 gas for 1 listing, 657,640 for 10 (`test_Gas_BuyOneVersusTenListings`). Insert gas grows with cheaper listings (B-1) |
| Can shares get stuck? | No, `cancel` works in every state |
| Can a fake market be used? | No: `factory.markets(market.marketId()) == market` (`NotFactoryMarket`) |
| Is it live? | Merged, not deployed. The website panel is hidden while `ORDER_BOOK` is the zero address |

Files: `contracts/src/OutcomeOrderBook.sol`, `contracts/test/OutcomeOrderBook.t.sol`,
`web/src/orderbook.tsx`, `docs/order-book.md`, `secondary_trading_plan.md` (outside the repo, Q1-Q5).

---

## 8. Website

**Explain in 60 seconds.** A React + TypeScript + Vite single-page app with wagmi, viem and RainbowKit,
served by Cloudflare Workers. There is no backend: it reads the factory and every market directly, pins
all reads to one block, and rebuilds trade history from logs scanned from `DEPLOY_BLOCK`. Pages: market
list, market detail (trade panel, resolution card, order book panel, claims), portfolio, admin create and
admin collect. Quotes are computed in the browser with the same maths as the contract; the on-chain
minimum output protects the user.

| Question | Answer |
|---|---|
| What if the RPC lies? | It can show wrong data and weaken slippage limits, but every transaction is signed in the user's wallet and checked on chain (O-5) |
| Why no indexer? | Fewer moving parts for a demo; first load gets slower as history grows. Ponder is the planned fix (O-7) |
| How does creating a market work in the UI? | Approve collateral, `createMarket`, then `ChainlinkResolver.configure` for price markets |
| How are fees collected? | The Collect page batches `withdrawFees` / `withdrawLiquidity` in one Multicall3 `aggregate3` call |
| Is the web tested? | No automated tests and no CI job (`testing.md` §5) |

Files: `web/src/chain.ts`, `web/src/contracts.ts`, `web/src/components.tsx`, `web/src/resolution.tsx`,
`web/src/orderbook.tsx`, `web/src/pages/*.tsx`, `docs/architecture.md` §9.
TODO(team): the web owner should check these answers.

---

## 9. Bot

**Explain in 60 seconds.** A stateless Python worker that polls every 300 s by default. For Chainlink
markets that are closed, it finds the round live at close and calls `resolve`. For optimistic markets
with no request, it opens the spec's source URL in headless Chromium and asks an LLM, and proposes only
if the page stayed on the source site, every quote is on the page, and all runs agree. It finalizes
undisputed requests, refunds cancelled ones, and alerts once per dispute. It never disputes and must use
its own wallet, never the admin or judge key.

| Question | Answer |
|---|---|
| Can the bot steal funds or force an outcome? | No. It is just another proposer; wrong proposals can be disputed |
| Prompt injection? | The page is treated as data, quotes must be verbatim, runs must agree. A page the attacker can write to can still steer it; the dispute window is the backstop. No test against a real model yet (O-2) |
| What if it crashes? | Stateless: the next poll re-reads the chain. Duplicate attempts fail in gas estimation |
| Is the AI on chain? | No. It only produces a proposal and evidence URI |

Files: `bot/sooth_bot/__main__.py`, `agent.py`, `optimistic.py`, `chainlink.py`, `config.py`,
`bot/tests/`, `bot/README.md`. TODO(team): the bot owner should check these answers.

---

## 10. Testing and security

**Explain in 60 seconds.** Foundry unit tests for every function and revert, fuzz tests for money
properties, end-to-end tests for every resolution route with balances checked against a separate Python
model, re-entrancy tests with malicious receivers and tokens, and a stateful invariant suite with 20
invariants over 4 markets, the resolver and the order book. On `3159dec`: 195 tests pass, production
code has 100% line coverage, Slither reports 23 results with no real issue. Mutation checks by hand
showed the tests fail when guards are removed.

| Question | Answer |
|---|---|
| Why invariant tests, not only unit tests? | They try random call orders across actors and time edges, which finds bugs unit tests miss |
| Why ghost counters in handlers? | With `fail_on_revert = false`, an assert inside a handler is swallowed; counters are checked in `invariant_*` functions |
| What did Slither find? | 23 results: 14 justified, 9 false positives, 0 fixes needed (`security-analysis.md`) |
| What is not tested? | Website, deploy scripts, a real-LLM injection test, a re-entrant bond token, `Market.sol` 2 branches (`testing.md` §5) |
| How do you know the tests can fail? | Mutation checks (`testing.md` §3) |
| How did AI affect the code? | See [ai-audit-report.md](ai-audit-report.md) |

Files: `contracts/test/`, `contracts/test/invariant/`, `docs/testing.md`, `docs/invariants.md`,
`docs/security-analysis.md`, `docs/threat-model.md`.

---

## 11. Deployment and CI

**Explain in 60 seconds.** Deploy order: `DeployMarketFactory` (which also deploys `OutcomeToken` and the
`Market` implementation), then `DeployOptimisticResolver` and `DeployChainlinkResolver`, then
`DeployOrderBook` (not run yet). Addresses are copied by hand into `web/src/contracts.ts` and the bot's
`.env`. Factory `0x8d399B14ea106bA62F79186217DB6fF1F75dc492` on Base Sepolia, block 50040022. CI runs
format, size and test checks for contracts, and `pytest` for the bot, on pushes and pull requests to
`main`.

| Question | Answer |
|---|---|
| Are the contracts verified on BaseScan? | TODO: evidence (P4-1) |
| Do deployed contracts match the code? | Since the broadcast commit `63c482d`, only the order book was added to `contracts/src`. Bytecode match not checked: TODO: evidence (P4-1) |
| Show a live trade | TODO: evidence (live demo, P4-2) |
| Why does CI skip tests for the size check? | The invariant test handler is over the 24,576-byte limit, which only matters for deployable contracts (AI log entry 8) |

Files: `contracts/script/`, `contracts/broadcast/*/84532/run-latest.json`, `.github/workflows/ci.yml`,
`docs/architecture.md` §11.
