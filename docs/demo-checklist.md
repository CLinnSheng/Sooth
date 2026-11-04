# Live demo checklist (Base Sepolia)

A script for one end-to-end run of Sooth on Base Sepolia (chain 84532), recording every transaction hash
for the AI Audit Report and the final report (task P4-2). Fill the **Tx hash** column as you go; each
hash opens at `https://sepolia.basescan.org/tx/<hash>`.

Addresses are those in `web/src/contracts.ts`. Never paste private keys here; use Foundry keystore names.

## 0. Before you start

| # | Step | Done |
|---|---|---|
| 0.1 | Three wallets with Base Sepolia ETH: **Admin** (factory admin, judge, Chainlink resolver owner), **Alice**, **Bob** | ☐ |
| 0.2 | Order book deployed (`contracts/script/DeployOrderBook.s.sol`, `FACTORY=0x8d399B14ea106bA62F79186217DB6fF1F75dc492`) and its address set as `ORDER_BOOK` in `web/src/contracts.ts` | ☐ |
| 0.3 | Mint test collateral to each wallet (MockUSDC `0x5f29331BBBA6f605942f5de0B217359F3C7B7c51`, 6 decimals). 100 mUSDC = `100000000`: `cast send 0x5f29331BBBA6f605942f5de0B217359F3C7B7c51 'mint(address,uint256)' <wallet> 100000000 --rpc-url <rpc> --account <keystore>` | ☐ |
| 0.4 | Screen recording on; website open at `/` with the wallet on Base Sepolia | ☐ |

Timing: the optimistic challenge window is **7,200 s (2 hours)** and the bond is **10 mUSDC**
(`DeployOptimisticResolver` broadcast). Create the markets first, with close times a few minutes ahead,
so trading and closing fit in one sitting; the optimistic flow then needs a 2-hour wait.

## 1. Create markets (Admin, `/admin/create`)

| # | Step | Expected | Tx hash |
|---|---|---|---|
| 1.1 | Create market A, resolution **Optimistic**, close in ~15 min, seed 50 mUSDC | Appears on `/` as Open | |
| 1.2 | Create market B, resolution **Chainlink** (feed and threshold set in the form), close in ~15 min, seed 50 mUSDC | Appears on `/`; the configure tx is sent by the form | |
| 1.3 | (Optional) Create market C, resolution **Optimistic**, for the dispute flow | | |

## 2. Trade on the AMM (Alice and Bob, `/market/<id>`)

| # | Step | Expected | Tx hash |
|---|---|---|---|
| 2.1 | Alice buys YES on A for 10 mUSDC (approve + buy) | YES price rises; trade row appears | |
| 2.2 | Bob buys NO on A for 5 mUSDC | Price moves back | |
| 2.3 | Alice sells part of her YES | Receives mUSDC minus 1% fee | |
| 2.4 | Alice and Bob trade on B the same way | | |

## 3. Order book (Bonus 1, market A, "Trade with others" panel)

| # | Step | Expected | Tx hash |
|---|---|---|---|
| 3.1 | Alice lists 5 YES at 0.70 (first time: `setApprovalForAll`, then `list`) | Listing shown, cheapest first, "yours" badge | |
| 3.2 | Alice lists 5 YES at 0.60 | Shown above the 0.70 listing | |
| 3.3 | Bob buys 7 YES with max price 0.75 (approve exact quote, then `buy`) | Fills 5 at 0.60 then 2 at 0.70; Alice receives mUSDC directly | |
| 3.4 | Alice cancels the rest | 3 YES back to Alice | |
| 3.5 | After close: panel shows trading closed, only own listings with Cancel | No buy or list forms | screenshot |

## 4. Close and resolve

| # | Step | Expected | Tx hash |
|---|---|---|---|
| 4.1 | Wait for close time | State shows Closed; AMM and order book disabled | screenshot |
| 4.2 | B (Chainlink): click resolve on the market page (or `ResolveChainlinkMarket.s.sol`) | Resolved YES/NO from the round live at close | |
| 4.3 | A (Optimistic): Alice proposes an outcome with the 10 mUSDC bond | Request shows Proposed, 2-hour countdown | |
| 4.4 | After 2 hours: anyone finalizes | A Resolved; Alice's bond returned | |
| 4.5 | (Optional, market C) Bob proposes the wrong outcome, Alice disputes, Admin (judge) rules | Winner gets both bonds | |

## 5. Pay out

| # | Step | Expected | Tx hash |
|---|---|---|---|
| 5.1 | Winners redeem on A and B (`/portfolio` or market page) | 1 mUSDC per winning share; losing shares burned | |
| 5.2 | Admin collects liquidity and fees (`/admin/collect`) | Creator receives pool value and fees | |
| 5.3 | Portfolio shows the payouts and PnL | | screenshot |

## 6. Not shown live

- **Timeout cancellation** (no result 7 days after close, 0.5 per share): too slow for a live demo. Evidence is
  `test_E2E7_TimeoutCancelsAndRefunds` in `contracts/test/EndToEnd.t.sol` and `invariant_RED_3_cancelledRedeemPaysHalf`.
- **Bot resolution**: optional; run `uv run python -m sooth_bot` (see `bot/README.md`) during step 4 to
  let it finalize or propose, and record its transactions above.

## 7. After the demo

- Paste the hashes into `docs/final-report.md` and `docs/ai-audit-report.md` where they say
  `TODO: evidence (live demo, P4-2)`.
- Save screenshots under `docs/ai/img/` or `docs/img/`.
