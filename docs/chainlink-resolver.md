# Chainlink resolver

Resolves price markets from a Chainlink feed with no human input. A market opts in by setting
`arbitrator = ChainlinkResolver`; anyone can resolve it after close.

## Usage

```bash
# once
forge script script/DeployChainlinkResolver.s.sol --broadcast ...

# create + configure in one broadcast (wallet must own the factory and the resolver)
FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 RESOLVER=$RESOLVER \
THRESHOLD=200000000000 COMPARISON=below MAX_STALENESS=3600 \
SPEC="$(cat spec.json)" CLOSE_TIME=... forge script script/CreateMarket.s.sol --broadcast ...

# after close, anyone
RESOLVER=$RESOLVER MARKET=$MARKET forge script script/ResolveChainlinkMarket.s.sol --broadcast ...
```

`THRESHOLD` is in feed decimals (8 for USD). `below`: YES if price < threshold; `above`: YES if
price > threshold. **Ties resolve NO.** Config is write-once and locked at close.

## Web and bot

- The bot resolves closed markets within one poll. The market page's Resolution card shows the feed
  condition, a Resolve fallback (same round search) and the settled price.
- Admin → Create market → Resolution: *Chainlink price feed* only sets the arbitrator. Configure the
  feed before close, or create with `CreateMarket.s.sol`, which does both.

## Settlement price

The last round written at or before `closeTime`, i.e. what the feed returned at that second. The
caller passes `roundId`; the contract requires:

- `updatedAt <= closeTime` and `closeTime - updatedAt <= maxStaleness`
- `answer > 0`
- it is the latest round, or the next round (`roundId + 1`, or round 1 of the next phase) has
  `updatedAt > closeTime`

The result is independent of who resolves or when. Any failed check reverts; an unresolved market
cancels at `closeTime + 7 days`.

No `try/catch` on feed reads: a caught out-of-gas would skip the next-round check and let a caller
settle on a superseded price.

## Spec wording

> YES if the last Chainlink ETH/USD value published at or before 2026-11-30 00:00:00 UTC is below
> 2000.00000000. Equal resolves NO.

## Limits

- Feeds update on 0.15% deviation or a 20 min heartbeat, so the settled price can lag the true price
  at close by up to that. Matters only near the threshold.
- No L2 sequencer uptime check (none on Base Sepolia). Staleness covers it in practice; add it for
  mainnet (`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`).
- `ResolveChainlinkMarket` searches the current feed phase only; pass `ROUND_ID` if the aggregator
  was upgraded after close.
