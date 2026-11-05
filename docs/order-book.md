# Order book

`OutcomeOrderBook` is the secondary market for outcome shares (Bonus 1). Holders list YES or NO shares
at a fixed price; buyers fill from the cheapest listing first, and the oldest first at the same price.
Listed shares sit in escrow in the order book. Each fill pays the seller directly. One contract serves
every market of the factory. It has no owner, charges no fee and needs no per-market setup. `Market`
is unchanged: shares only change hands, with no mint or burn.

## Usage

```bash
# once
FACTORY=$FACTORY forge script script/DeployOrderBook.s.sol --broadcast ...

# seller: approve once, then list (outcome: 0 = YES, 1 = NO; price in USDC units per whole share)
cast send $TOKEN "setApprovalForAll(address,bool)" $BOOK true
cast send $BOOK "list(address,uint8,uint256,uint256)" $MARKET 0 100000000 700000   # 100 YES at 0.70

# buyer: approve USDC, quote, buy up to 40 YES at <= 0.70 from at most 10 listings
cast send $USDC "approve(address,uint256)" $BOOK 28000000
cast call $BOOK "quoteBuy(address,uint8,uint256,uint256,uint256)" $MARKET 0 40000000 700000 10
cast send $BOOK "buy(address,uint8,uint256,uint256,uint256)" $MARKET 0 40000000 700000 10

# seller: take the rest back (any market state)
cast send $BOOK "cancel(uint256)" 1
```

## Functions

| Function | Who | When | What it does |
|---|---|---|---|
| `list(market, outcome, amount, price)` | holder | `Open` | Escrows `amount` shares and inserts the listing after every listing priced at or below `price`. Returns the listing id (from 1) |
| `buy(market, outcome, shares, maxPrice, maxListings)` | anyone | `Open` | Fills from the head while shares are wanted, `price <= maxPrice` and fewer than `maxListings` listings were touched. Pays each seller as it goes and sends all shares at the end. Returns `(sharesBought, cost)` |
| `cancel(listingId)` | seller | any state | Removes the listing and returns its remaining shares |
| `quoteBuy(...)` | view | `Open` | Same arguments and same walk as `buy`. Returns `(0, 0)` where `buy` would revert `NothingFilled` |
| `bestPrice(market, outcome)` | view | any | Head price, or 0 if the book is empty |
| `listingsOf(market, outcome, startAfter, count)` | view | any | Up to `count` ids in fill order, after `startAfter` (0 = from the head) |
| `getListing(id)` | view | any | The stored listing. `remaining == 0` means filled or cancelled; `prev`/`next` are then 0 |

## Rules

- Only markets of the configured factory (`factory.markets(market.marketId()) == market`), else `NotFactoryMarket`.
- `list` and `buy` need `market.state() == Open`, else `MarketNotOpen(state)`. Trading follows the AMM
  window, so it stops at `closeTime`. `cancel` works in every state, so escrowed shares are never stuck.
- `price` must be strictly between 0 and `PRICE_SCALE` (1e6 = 1 USDC), else `InvalidPrice`. A zero
  `amount`, `shares` or `maxListings` reverts `ZeroAmount`.
- Each (market, outcome) book is a doubly linked list sorted by price ascending, FIFO at equal price.
- `buy` reverts `NothingFilled` if nothing matched. `cancel` reverts `ListingNotFound` for unknown,
  filled or cancelled ids, and `NotSeller` for anyone but the seller.
- `list`, `buy` and `cancel` are `nonReentrant`. Each listing is updated (and unlinked if empty) before
  its seller is paid.
- `listingsOf` reverts `ListingNotFound` if `startAfter` is not an open listing of that book.

## Rounding

A fill of `f` shares at price `p` costs `ceil(f × p / 1e6)` collateral units, rounded up per listing, so
a fill is never free. Example: 3 raw units at 0.333333 cost 1 unit, not 0. A sweep's `cost` is the sum
of these per-listing amounts.

## Example

Listings for YES: Carol 10 at 0.40, Dave 10 at 0.50, Alice 10 at 0.60. Bob calls
`buy(market, Yes, 25e6, 999_999, 10)`:

| Listing | Fill | Paid to seller |
|---|---|---|
| Carol @ 0.40 | 10 | 4 USDC |
| Dave @ 0.50 | 10 | 5 USDC |
| Alice @ 0.60 | 5 (5 stay listed) | 3 USDC |

Bob pays 12 USDC and receives 25 YES. After resolution he redeems through `Market.redeem` as usual.

## Limits

- Inserting a listing walks the book from the head (unless it is the new most expensive), so gas grows
  with the number of cheaper listings. A position hint would fix this; fine for the testnet demo.
- `maxListings` caps the gas of `buy`. Measured: about 157k gas for 1 listing, 658k for 10 (fresh sellers).
- Sellers are paid in the fill. A seller blocked by USDC makes fills against their listing revert, and
  that blocks the book behind it until they cancel. Use `maxListings` and `maxPrice`, or pick
  another price, to work around it.
- Public transactions can be front-run. `maxPrice` caps what a buyer can pay.
- No trading after `closeTime`, even before resolution (team decision Q2 B). Prices near close may be stale.
- Sell listings only; there are no bids.

## Frontend notes

- Listing needs `outcomeToken.setApprovalForAll(orderBook, true)` once per seller.
- Buying needs `collateral.approve(orderBook, cost)`. Approve the `quoteBuy` cost, or a bit more if the
  book may change before the transaction lands.
- Depth: page with `listingsOf(market, outcome, lastId, n)` and read each `getListing(id)`. `bestPrice`
  is the best ask. Watch `Listed`, `Filled` and `Cancelled` to refresh.
- Hide `list`/`buy` when `market.state() != Open`, but always offer `cancel` for the user's open listings.
