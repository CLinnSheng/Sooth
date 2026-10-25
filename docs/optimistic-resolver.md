# Optimistic resolver

Resolves markets without a price feed. A bonded proposal stands unless disputed within the challenge
window; disputes go to the judge (resolver owner). A market opts in by setting
`arbitrator = OptimisticResolver`; no per-market config.

## Usage

```bash
# once (ADMIN = judge; defaults: 10 USDC bond, 2h window)
FACTORY=$FACTORY forge script script/DeployOptimisticResolver.s.sol --broadcast ...

# create a market judged by it
ARBITRATOR=$RESOLVER SPEC="$(cat spec.json)" CLOSE_TIME=... forge script script/CreateMarket.s.sol --broadcast ...

# after close (approve BOND on the collateral first); outcome: 0 = YES, 1 = NO
cast send $RESOLVER "propose(address,uint8,string)" $MARKET 1 "ipfs://..."
cast send $RESOLVER "dispute(address,string)" $MARKET "ipfs://..."   # within the window
cast send $RESOLVER "finalize(address)" $MARKET                      # after an undisputed window
cast send $RESOLVER "rule(address,uint8)" $MARKET 0                  # judge, disputed only
cast send $RESOLVER "refund(address)" $MARKET                        # market cancelled with a request open
```

## Rules

| Path | Bonds |
|---|---|
| No dispute, `finalize` | Proposer gets theirs back |
| Disputed, judge rules for the proposal | Proposer gets both |
| Disputed, judge rules against it | Disputer gets both |
| Market cancels first (`refund`) | Each side gets theirs back |

- One request per market. A wrong proposal is disputed, not out-proposed.
- `propose` requires the window to end strictly before the market's resolution deadline; otherwise
  it could never finalize.
- Only markets from the configured factory with `arbitrator == this` are accepted.
- Evidence URIs are emitted in `Proposed`/`Disputed`, not stored.
- The judge is `Ownable2Step`; hand over to a multisig with `transferOwnership` + `acceptOwnership`.

## Limits

- Bonds are pushed. A USDC-blacklisted recipient makes that settlement revert and the market cancels.
  Switch to pull payments before real USDC.
- No proposer reward: proposing costs gas and returns only the bond.
- An invalid market can't be cancelled early; it waits for the 7-day deadline.
