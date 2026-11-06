# Final report

Sooth is a binary (YES/NO) prediction market dApp on Base Sepolia. This report explains the problem we
solved, how the design solves it and why we made each design choice. It was written from
`lin/integration` at `7d7b76f` (plus the threat-model refresh `fe9919e`) on 2026-11-05.

How we used AI and what it got wrong is in the AI Audit Report ([ai-audit-report.md](ai-audit-report.md))
and the per-member AI logs ([ai/](ai/)). This report does not repeat them. Short talking points for every
component are in [cross-explanation.md](cross-explanation.md).

## 1. Problem identification

The course brief (`Project_requirements`) asks for a decentralized market where users create, trade and
resolve markets on future real-world events. We read it as three problems.

| Problem | What goes wrong today | What a smart contract can do | What it cannot do |
|---|---|---|---|
| **Incentive alignment** | Forecasters are not paid for being right, so forecasts are cheap talk | Let people buy YES/NO shares. A share pays 1 if right, 0 if wrong, so the price is the crowd's probability | Make the crowd well-informed |
| **Custody and settlement** | A sportsbook holds the money, takes a rake and can limit or close accounts | Hold the collateral in a contract. Pay winners by rule, with no operator able to block a payout | Stop an admin from creating a bad market |
| **The oracle problem** | A contract cannot see the real world, so someone must report the outcome | Make reporting accountable: a fixed arbitrator per market, bonds, a challenge window, a price feed, and a fallback when nobody reports | Know the truth |

**Trust statement.** The chain guarantees settlement, not truth. Once an outcome reaches
`Market.resolve`, winners get exactly 1 collateral unit per share, once. Whether that outcome is true
depends on the market's arbitrator: the Chainlink feed, the optimistic proposer plus disputers plus the
judge, or a custom address. The bond and dispute design reduces the oracle problem; it does not remove it.
Full actor and trust table: [threat-model.md §2-3](threat-model.md).

Users: traders (bet and redeem), the admin (creates markets and picks the arbitrator), the judge (rules
on disputes), proposers and disputers (anyone with a bond), and the bot (automates resolution).

## 2. Solution overview

```mermaid
flowchart LR
    trader([Trader]) -->|wallet| web[Website]
    admin([Admin]) -->|wallet| web
    web -->|reads, txs| F[MarketFactory]
    web --> M["Market clone<br/>AMM + payouts"]
    web --> OB[OutcomeOrderBook]
    F -->|clone + seed| M
    M -->|mint, burn| T[OutcomeToken ERC-1155]
    OR[OptimisticResolver] -->|resolve| M
    CR[ChainlinkResolver] -->|resolve| M
    bot[Bot + LLM] -->|propose, finalize| OR
    bot -->|resolve with roundId| CR
    CR -->|getRoundData| feed[Chainlink feed]
    OB -->|escrow shares| T
```

Lifecycle of one market:

1. **Create.** The admin calls `MarketFactory.createMarket` with the spec, close time, arbitrator and seed
   liquidity. The factory deploys an EIP-1167 clone of `Market` and seeds a 50/50 pool.
2. **Trade.** While `Open`, anyone buys or sells YES/NO on the AMM, or lists and buys shares on the order
   book (Bonus 1). Prices move with trades.
3. **Close.** At `closeTime` trading stops. `Closed` is derived from the clock, not written.
4. **Resolve.** Within 7 days (`RESOLUTION_WINDOW`), the arbitrator calls `Market.resolve(outcome)`.
5. **Pay out.** Holders call `redeem()`. If nobody resolved in time, the market is `Cancelled` and every
   share redeems at half a unit.

Full diagrams (call graph, state machine, sequence diagrams): [architecture.md](architecture.md).

## 3. Feature requirements: what we built and where

Each row is a bullet of "Feature Requirements" in `Project_requirements`. Test names are from
`contracts/test/`; full per-test descriptions are in [testing.md §2](testing.md).

| Requirement | How Sooth meets it | Code | Tests |
|---|---|---|---|
| **Market creation:** topics with outcome options | A question, rules and source go into a spec JSON. Its `keccak256` is stored as `specHash`; the full spec is in the `MarketCreated` log. Outcomes are fixed to YES and NO (`IMarket.Outcome`) | `MarketFactory.createMarket`, `_validate`; `web/src/pages/Admin.tsx` | `test_CreateMarket_StoresParameters`, `test_CreateMarket_EmitsMarketCreated`, `test_RevertWhen_SpecEmpty` |
| **Market creation:** timestamps | `closeTime` must be in the future. `resolutionDeadline() = closeTime + 7 days`. State is derived from the clock | `MarketFactory._validate`, `Market.state` | `test_RevertWhen_CloseTimeInPast`, `test_RevertWhen_CloseTimeIsNow`, `test_StateMovesFromOpenToClosedToCancelledWithoutTransactions` |
| **Market creation:** arbitrator identities | `arbitrator` is fixed per market and must be non-zero. It can be `OptimisticResolver`, `ChainlinkResolver` or any address ("custom" on the Admin page) | `Market.arbitrator`, `Market.resolve`; `Admin.tsx` resolution picker | `test_RevertWhen_ArbitratorIsZero`, `test_CreateMarket_ArbitratorCanBeCreator`, `test_RevertWhen_ResolverIsNotArbitrator` |
| **Trading and minting:** place bets, receive outcome tokens | `buy` takes collateral, mints a YES+NO pair per net unit and sends the chosen side from the pool. `sell` is the reverse. Slippage (`minSharesOut`, `minCollateralOut`) and `deadline` on both | `Market.buy`, `Market.sell`, `OutcomeToken.mintBatch` / `burnBatch`; `web/src/components.tsx` trade panel | `test_BuyQuoteMatchesExecutionAndAccountsForFee`, `test_SellQuoteMatchesExecutionAndBurnsFromMarketCustody`, `test_RevertWhen_BuyBelowMinShares`, `test_RevertWhen_TradingAfterClose`, `testFuzz_BuyThenSellCannotProfit` |
| **Trading and minting:** dynamically derive odds | Constant-product pool. `priceYes = noPool / (yesPool + noPool)` (18 decimals), `priceNo` the mirror. Every trade moves it | `Market.priceYes`, `priceNo`, `_quoteBuy`, `_quoteSell` | `test_BuyNoMovesPriceInOppositeDirection`, `test_SellNoMovesPriceInOppositeDirection`, `test_CreateMarket_StartsAtFiftyFifty`, `invariant_COL_6_productNeverFallsAndRoundTripNeverProfits` |
| **Resolution and payouts:** arbitrator submits final outcome | Only `arbitrator`, only while `Closed`, only once. Three arbitrator types (section 4.5) | `Market.resolve`, `OptimisticResolver`, `ChainlinkResolver`; `web/src/resolution.tsx`; `bot/` | `test_ArbitratorResolvesClosedMarket`, `test_RevertWhen_ResolvingTwice`, `test_FinalizeResolvesMarketAndReturnsBond`, `test_RuleForDisputerPaysDisputerBothBonds`, `test_E2E1_DirectYes` to `test_E2E8b_...`, `invariant_RES_1_resolvedAtMostOnce` |
| **Resolution and payouts:** winners redeem | `redeem` burns all the caller's YES and NO and pays 1 per winning share (Resolved) or half per share (Cancelled) | `Market.redeem`, `_settlementValue`; Market and Portfolio pages | `test_WinnerRedeemsOneCollateralPerShare`, `test_RevertWhen_RedeemingTwice`, `test_CancelledRedeemPaysHalfPerShare`, `invariant_RED_2_redeemPaysOnePerWinningShare`, `invariant_RED_4_noDoubleClaims` |
| Cancel and refund path (team rule: never cut) | No outcome by the deadline: market cancels by itself; shares pay half; bonds are refunded | `Market.state`, `_settlementValue`, `OptimisticResolver.refund` | `test_E2E7_TimeoutCancelsAndRefunds`, `test_E2E8_OptimisticDisputedLeftOpenRefundsBothBonds`, `invariant_RED_3_cancelledRedeemPaysHalf`, `invariant_BND_4_refundMakesEveryoneWhole` |
| **Bonus 1:** secondary market before resolution | **Built.** `OutcomeOrderBook`: holders list shares at a fixed price, buyers fill cheapest first. Merged and **deployed on Base Sepolia** (`0x539a5842371cEeA853A5Adab48bAFc2a5d9B2b05`) | `OutcomeOrderBook.sol`; `web/src/orderbook.tsx` (hidden while `ORDER_BOOK` is the zero address) | 38 tests in `OutcomeOrderBook.t.sol` (e.g. `test_Buy_FillsCheapestFirst`, `test_RevertWhen_ReenteringBuyFromReceiver`, `test_EndToEnd_AmmBookResolveRedeem`); `invariant_OB_1_escrowEqualsOpenListings` to `invariant_OB_4_...` |
| **Bonus 2:** multi-asset collateral | **Not built** (user decision 2026-11-04, `work_plan.md` P2-4 `skipped`). One 6-decimal collateral per factory | `MarketFactory` constructor (`InvalidCollateralDecimals`) | `test_RevertWhen_CollateralDecimalsNotSix` |
| **Bonus 3:** reputation-weighted voting | **Not built** (`work_plan.md` P2-3 `skipped`). Disputes go to one judge | – | – |

Live demo evidence for these rows: TODO: evidence (live demo, P4-2).

## 4. Design justifications

### 4.1 Chain and toolchain

| Choice | Why | Cost |
|---|---|---|
| Solidity on an EVM chain | Standard tools (OpenZeppelin, Foundry, wagmi/viem, Chainlink) and the course content | Gas costs and public mempool (front-running) |
| **Base Sepolia** (chain id 84532) | About 2 s blocks for a fast demo, very cheap gas, BaseScan verification, plain EVM behaviour. A prediction market has many small trades, so L2 fees matter (`market_creation_plan.md` Q8) | Test ETH sometimes has to be bridged. No L2 sequencer uptime feed (K-3) |
| Foundry (forge 1.8.5, solc 0.8.28) | Fast tests, fuzz and stateful invariant testing in Solidity | – |
| Time, not block numbers | All windows use `block.timestamp`, so the design does not depend on block time | Validator drift of seconds (Slither rows 11-17, justified) |

`market_creation_plan.md` records Base Sepolia as chosen "in practice" (the website and MockUSDC
already used it), not as a formal team vote. TODO(team): confirm the chain decision was agreed.

### 4.2 Market structure: factory, clones, one ERC-1155

- **One clone per market (EIP-1167).** Each market's collateral sits in its own contract, so a bug or a
  bad market cannot drain other markets. A clone is about 45 bytes, much cheaper than a full deploy.
  The risk of clones (someone initialising them) is closed by `initializer`, `NotFactory` and
  `_disableInitializers()` on the implementation (`test_RevertWhen_NonFactoryInitializesClone`,
  `test_RevertWhen_ImplementationInitialized`).
- **One `OutcomeToken` (ERC-1155) for all markets.** Wallets and the website track one contract. The token
  id is `keccak256(abi.encode(marketId, outcome))` (`OutcomeTokenId`). Only the market that owns an id can
  mint or burn it (`_requireMarketOf`).
- **Admin-only creation.** `createMarket` needs `DEFAULT_ADMIN_ROLE`. The admin also supplies the seed
  liquidity. We chose this over open creation because the admin picks the arbitrator, which is a trust
  point (R-4). Open creation would need creator bonds (backlog E1-5, not built).
- **Seed check uses `>=`.** Clone addresses are predictable; an exact balance check would let anyone block
  creation by sending 1 unit first (C-13).

Details: [market-creation-explained.md](market-creation-explained.md), [contract-spec.md §1-3](contract-spec.md).

### 4.3 Collateral model

- **Complete sets.** 1 YES + 1 NO is always backed by exactly 1 unit of collateral. A buy mints pairs; a
  sell or redeem burns them. So the market can always pay: Resolved pays 1 per winning share, Cancelled
  pays `(yes + no) / 2` rounded down (`_settlementValue`). Checked by `invariant_COL_2_...` and
  `invariant_RED_1_payoutsNeverExceedReceipts`.
- **6-decimal collateral only.** The factory rejects other decimals. On testnet it is `MockUSDC`
  (anyone can mint it). `1e6` raw units is one USDC and one whole share.
- **Fees apart from backing.** The 1% fee (`FEE_BPS = 100`, rounded up) goes to `accruedFees`, owed to
  the market's `creator`. It is never used to mint shares.
- **Recorded pools, not balances.** `yesPool` and `noPool` are stored values, so donations cannot move
  prices (`test_DonationsDoNotChangeRecordedReserves`). Donated tokens stay in the market (K-6).
- **Why the cancel value is 50/50.** If nobody resolves, there is no fair winner. Paying half per share
  returns the full collateral of every complete set and never needs more money than the market holds.

### 4.4 Pricing: constant-product AMM

The backlog fixed "AMM (constant product)" as a team baseline. It does not record why; the comparison
below is our own reasoning.

| Option | For | Against |
|---|---|---|
| **Constant product (chosen)** | Always a price and a counterparty, even with few traders. Integer maths only (no `exp`/`ln`). Familiar from Uniswap. The seed is the creator's maximum loss | Price impact on big trades. The creator's pool can end up worth less than the seed |
| LMSR | Bounded loss set by one parameter; the classic prediction-market maker | Needs `exp` and `ln` in fixed point, which is harder to get right and test |
| Order book only | No market maker needed; users set prices | Thin markets have no liquidity. Matching on chain costs gas |

**Formulas** (`Market._quoteBuy`, `_quoteSell`; [trading-engine.md](trading-engine.md)). For pools `a`
(chosen side) and `b` (other side):

- Spot price: `priceYes = noPool / (yesPool + noPool)`. It starts at 0.5 (the factory only accepts
  `initialYesProbabilityBps = 5000`).
- Buy with `c` collateral: `fee = ceil(c × 1%)`, `n = c - fee`, `aAfter = ceil(a × b / (b + n))`,
  `sharesOut = a + n - aAfter`.
- Sell `s` shares: the largest `g` with `(a + s - g) × (b - g) >= a × b`, found by binary search; the
  seller gets `g - ceil(g × 1%)`.

**Rounding always favours the pool.** The fee and the pool-after round up and the sell search rounds
down, so `yesPool × noPool` never falls and a buy-then-sell never profits
(`testFuzz_BuyThenSellCannotProfit`, `invariant_COL_6_...`).

The website quotes in the browser with the same maths (`web/src/mock.ts`), and the on-chain
`minSharesOut` / `minCollateralOut` protects the trader if pools moved.

### 4.5 Oracle and resolution model

Each market names one arbitrator at creation. The market only checks "is the caller my arbitrator, is
the market `Closed`, is this the first time". That keeps `Market` small and lets us plug in different
oracles.

| Arbitrator | For | How it works | Trust |
|---|---|---|---|
| `ChainlinkResolver` | Price questions ("ETH below 2000 at close?") | Owner configures feed, threshold, comparison and staleness before close (write-once). After close **anyone** calls `resolve(market, roundId)`. The contract checks the round was the one live at `closeTime` (not later, not superseded, not stale, price > 0) | The feed, and the owner's config matching the spec. Ties resolve NO |
| `OptimisticResolver` | Any other question | After close anyone `propose`s with a bond (deployed: 10 mUSDC). Anyone can `dispute` with the same bond within the challenge window (deployed: 2 hours). No dispute: `finalize` resolves and returns the bond. Dispute: the judge (`owner`) calls `rule`, and the winner gets both bonds | Watchers who dispute, and the judge. The judge can dispute and rule itself, so it effectively controls every optimistic market (R-3) |
| Custom address | Demos and trusted reporters | That address calls `Market.resolve` directly | Fully trusted |
| (any) timeout | Safety net | No outcome by `closeTime + 7 days`: `Cancelled`, 50/50 payout, `refund` returns bonds | None needed |

Why this model:

- **Optimistic first, humans only on disputes.** Most outcomes are not contested. A bond makes a wrong
  proposal cost money, and the challenge window gives others time to object. This follows the
  "reporter staking" idea in the brief, with a single trusted judge instead of a vote (Bonus 3 skipped).
- **`propose` is refused if its window would end at or after the deadline** (`ProposalTooLate`), so an
  undisputed proposal can always be finalized in time.
- **Chainlink for prices, with no human input.** The caller passes the round id but cannot choose the
  price, because the contract checks the next round started after close.
- **The bot is advisory.** It reads the spec's source page in headless Chromium and asks an LLM. It only
  proposes when every quote is found verbatim on the page and all `AGENT_RUNS` (default 2) runs agree.
  It never disputes. The contracts treat it like any proposer, so a wrong bot answer must still be
  disputed by a human (R-1, O-2).

Details: [optimistic-resolver.md](optimistic-resolver.md), [chainlink-resolver.md](chainlink-resolver.md),
`bot/README.md`.

### 4.6 On-chain vs off-chain split

Rule: **anything that moves funds or decides an outcome is on chain.** Everything else is off chain and
can fail without risk to funds.

| On chain | Off chain |
|---|---|
| Collateral custody, shares, pool prices, fees | Market list, search and display (website reads the chain directly) |
| `specHash` (the full spec text is in the `MarketCreated` log) | Rendering the spec JSON |
| State machine, resolution, bonds, payouts | Trade history and charts, rebuilt in the browser from logs |
| Chainlink round checks | Finding the round id at close (bot or website) |
| Order book listings and escrow | Order book display (view calls) |
| | Bot: LLM resolution, finalize, refund, dispute alerts |

There is no backend database and no indexer. The website scans logs from `DEPLOY_BLOCK` (`50_040_022`).
This keeps the "funds never depend on the backend" rule but makes first load slower as history grows (O-7).
The backlog planned IPFS for the spec; we store the spec in the event log instead (decision P3-1 still
`todo` in `work_plan.md`). TODO(team): record the IPFS decision. Full table:
[architecture.md §2](architecture.md).

### 4.7 Order book design (Bonus 1)

The brief asks for "secondary derivative market trading prior to event resolution". A YES share is a
derivative of the event: it pays 1 if the event happens. The AMM is the primary market (it creates
shares). The order book is a secondary market: holders trade existing shares with each other. No shares
are minted or burned, and `Market` did not change.

Decisions (`secondary_trading_plan.md` §5, user answers on 2026-11-04):

| Question | Decision | Why |
|---|---|---|
| Q1 Order types | Sell listings only (no bids) | Simplest form that meets the requirement in the time left. Bids can be added later |
| Q2 When can fills happen | Only while `Open` (stops at `closeTime`) | Fairness: after close the result may be known to some traders, and they would buy from people who do not know it yet |
| Q3 Fee | None | Simplest; no extra rounding or accounting |
| Q4 Matching | Automatic, cheapest first, oldest first at the same price | Works like a real exchange: the buyer gives a size and a price limit, not a listing id |
| Q5 Website | Our own panel on the market page | We built the contract, so we could ship the UI without waiting |

How it works (`OutcomeOrderBook.sol`, [order-book.md](order-book.md)):

- `list(market, outcome, amount, price)` escrows shares and inserts the listing in a doubly linked list
  per (market, outcome), sorted by price, FIFO at equal price. Price is in USDC units per whole share,
  strictly between 0 and `PRICE_SCALE` (1e6), because a share never pays more than 1.
- `buy(market, outcome, shares, maxPrice, maxListings)` walks from the cheapest listing. Each fill costs
  `ceil(fill × price / 1e6)`, rounded up so a fill is never free, and is paid straight to the seller.
  `maxPrice` caps front-running damage; `maxListings` caps gas.
- `cancel(listingId)` works in **every** market state, so escrowed shares are never stuck.
- Only factory markets are accepted. `list`, `buy` and `cancel` are `nonReentrant`, and each listing is
  updated before its seller is paid.

Known limits: insert gas grows with the number of cheaper listings (B-1); a USDC-blocked seller at the
head blocks buys on that book until they cancel (B-3). Measured `buy` gas: 157,339 for 1 listing, 657,640
for 10 (`test_Gas_BuyOneVersusTenListings`, from [threat-model.md §7](threat-model.md)).

### 4.8 Security design

- `ReentrancyGuardTransient` on every function that moves collateral or shares, plus
  checks-effects-interactions. Tested with malicious ERC-1155 receivers and callback tokens
  (`test/MarketReentrancy.t.sol`, `OutcomeOrderBook.t.sol`), and mutation checks showed the tests fail
  when the guard is removed ([testing.md §3](testing.md)).
- Access control is per role: admin creates, arbitrator resolves, judge rules, Chainlink owner
  configures, only a market mints its own ids ([contract-spec.md §9](contract-spec.md)).
- 55 written invariants ([invariants.md](invariants.md)), 20 of them checked by the stateful invariant
  suite. Threats and residual risks: [threat-model.md](threat-model.md).

## 5. Implementation

| Part | Where | Notes |
|---|---|---|
| Contracts | `contracts/src/` | `MarketFactory`, `Market`, `OutcomeToken`, `OptimisticResolver`, `ChainlinkResolver`, `OutcomeOrderBook`, library `OutcomeTokenId`, mocks `MockUSDC`, `MockAggregator` |
| Scripts | `contracts/script/` | Deploy scripts for each contract, `CreateMarket.s.sol`, `ResolveChainlinkMarket.s.sol` |
| Website | `web/` | React, TypeScript, Vite, wagmi, viem, RainbowKit. Pages: Home, Market, Portfolio, Admin create, Admin collect. Hosted on Cloudflare Workers (`wrangler.jsonc`) |
| Bot | `bot/` | Python, web3.py, Playwright Chromium, OpenAI-compatible LLM. Polls every 300 s by default |
| CI | `.github/workflows/ci.yml` | `forge fmt --check`, size check of deployable contracts, `forge test -vvv`; bot `pytest`. No web job |

### Deployment (Base Sepolia, 84532)

From `contracts/broadcast/*/84532/run-latest.json`:

| Contract | Address | Deploy tx | Block |
|---|---|---|---|
| `MarketFactory` (also creates `OutcomeToken` and the `Market` implementation) | `0x8d399B14ea106bA62F79186217DB6fF1F75dc492` | `0x724b7dbfb27a28bfe4057c830f55c154cd02f8da499731f3afa5b4a39f1e43b8` | 50040022 |
| `OutcomeToken` | `0xA2D1e9A1e195d01B1aC21090962B7F2AD76BDB5B` | same | 50040022 |
| `Market` implementation | `0x3a69D08ba7Ab7CcE6f8f53Fc193bAD9Ac661D098` | same | 50040022 |
| `ChainlinkResolver` | `0xAD3F05e6eFFeCD81278894266f5816691E704638` | `0x618c577a99b4ddb1dcaa58412a37f6b77a78aad6d3851fe3efbdd9437f059c5c` | 50040516 |
| `OptimisticResolver` (bond 10e6, window 7200 s) | `0xe37DB6692De70F5fe69fcABb64b7C737fA096335` | `0xbc82d25b7795e1887b915a6a08f8b43c59fc0613ea7a1dd79a479b3225249bbd` | 50040832 |
| `MockUSDC` (collateral) | `0x5f29331BBBA6f605942f5de0B217359F3C7B7c51` | not in these broadcast files | – |
| `OutcomeOrderBook` | `0x539a5842371cEeA853A5Adab48bAFc2a5d9B2b05` | `0x66f0f8f79de12a3c12b14bf37d8e11e9d61aa839bee686db7b488ef54ca634e1` | 55252775 |

Since the commit that added these broadcast files (`63c482d`), the only change in `contracts/src` is the
new order book (`git diff --stat 63c482d 7d7b76f -- contracts/src`). BaseScan source verification:
TODO: evidence (P4-1).

## 6. Testing and evidence

All numbers are copied from [testing.md §4](testing.md) and [security-analysis.md](security-analysis.md)
(runs on `3159dec`, 2026-11-04; `contracts/src`, `bot` and `web` are unchanged between `3159dec` and
`7d7b76f`).

| Check | Result |
|---|---|
| `forge test` | 195 passed, 0 failed (9 suites; the invariant suite counts as 1) |
| Stateful invariants | 20 `invariant_*` functions; default 64 runs x 64 calls; deep profile 512 x 128 passed |
| Coverage, `src/` | Lines and functions 100% for every production contract; branches 100% except `Market.sol` 93.75% (30/32) |
| Slither 0.11.6 | 23 results, 0 real issues (14 justified, 9 false positives) |
| Mutation checks (by hand) | Every recorded mutant made tests fail. One (removing the `liquidityWithdrawn` check) is caught only through the handler's bulk-donation action ([testing.md §3](testing.md)) |
| Bot `pytest` | 173 passed, 15 skipped |
| Website | No automated tests |
| Live demo on Base Sepolia | TODO: evidence (live demo, P4-2) |

Bugs found and fixed during development, and what the AI got wrong, are in
[ai-audit-report.md](ai-audit-report.md) and [ai/](ai/).

## 7. Limitations

The main ones. The full list with decisions is [threat-model.md §5](threat-model.md) (K-1 to K-12).

| Limitation | Effect | Why we accepted it |
|---|---|---|
| Binary YES/NO only, 50/50 start only | No multi-outcome markets; the first trades set the price | Keeps the AMM and payout maths simple and tested |
| Admin creates every market and picks the arbitrator | The admin is trusted (R-4) | No creator bond or arbitrator allow-list yet |
| One judge key decides every disputed market, and can dispute itself (R-3) | Centralised dispute outcome | Bonus 3 (reputation voting) skipped; multisig handover is possible (`Ownable2Step`) |
| No INVALID result (K-4) | An ambiguous market waits 7 days, then cancels 50/50 | P2-1 not built |
| Bonds are pushed (K-1); a late dispute can leave the judge seconds (K-2) | With real USDC, a blacklisted address could block settlement | Resolver hardening (P2-2) skipped by user decision; documented |
| No L2 sequencer check (K-3) | Price could be stale if Base stops | No uptime feed on Base Sepolia; staleness check covers it in practice |
| No indexer; browser log scan (K-11) | Slow first load as history grows | Fewer moving parts for a testnet demo |
| Order book: listings only, `Open` only, insert gas grows | Less liquidity than a full exchange | Team decisions Q1, Q2; fine for the demo |
| Order book deployed, no live demo yet | Bonus 1 has no public transaction evidence of trades yet | Pending P4-2 (demo) |
| Spec not on IPFS | Spec text lives in a log, only its hash in storage | P3-1 undecided |
| Website has no tests or CI job | UI regressions are found by hand | Time |
| Creator keeps fees in a cancelled market (K-7) | Traders are made whole only to 50/50 | To be confirmed by the team |

## 8. Future work

| Item | Fixes |
|---|---|
| Pull-based bonds and a minimum judge time | K-1, K-2 |
| INVALID outcome and early cancel by the arbitrator | K-4 |
| Judge and admin on a multisig; reputation-weighted dispute voting (Bonus 3) | R-3, K-9 |
| Creator bonds and an arbitrator allow-list, then open market creation | R-4 |
| Multi-asset collateral (Bonus 2): one factory or implementation per whitelisted 6-decimal token | Bonus 2 |
| Order book: bids, a position hint for `list`, pull payments to sellers | B-1, B-3 |
| Indexer (for example Ponder) with reorg handling | O-6, O-7 |
| Sequencer uptime check before mainnet; real USDC | K-3 |
| Prompt-injection tests against a real model; a dispute-watcher bot | O-2, R-1 |
| Website tests and a web CI job | Testing gap |

## 9. Team and contributions

TODO(team): names, roles (backlog roles M1 core contracts, M2 resolution and security, M3 app and AI)
and what each member built and reviewed. Git authors on `lin/integration` are `linnsheng`, `lin001234`,
`Khant Naing Lin` and `Tingfeng03`; which member is which, and their share of the work, must come from
the team.

## 10. Document map

| Doc | Covers |
|---|---|
| [architecture.md](architecture.md) | System diagrams, on/off-chain split, website, bot, deployment |
| [contract-spec.md](contract-spec.md) | Every function, event, error and constant |
| [market-creation-explained.md](market-creation-explained.md) | Factory, clones, outcome tokens |
| [trading-engine.md](trading-engine.md) | AMM maths and fees |
| [optimistic-resolver.md](optimistic-resolver.md), [chainlink-resolver.md](chainlink-resolver.md) | Resolution |
| [order-book.md](order-book.md) | Bonus 1 |
| [invariants.md](invariants.md), [testing.md](testing.md), [security-analysis.md](security-analysis.md) | Properties, tests, Slither, coverage |
| [threat-model.md](threat-model.md) | Actors, trust, threats, limitations |
| [ai-audit-report.md](ai-audit-report.md), [ai/](ai/) | AI Audit Report and AI logs |
| [cross-explanation.md](cross-explanation.md) | Talking points per component |

Setup and usage instructions: the root `README.md` is being rewritten on the unmerged branch
`docs/audit-and-readme` (features, local setup, test-wallet funding); see it once merged.
