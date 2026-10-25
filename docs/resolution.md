# Resolution and payout (E3, phase 1)

Phase 1 lets a market end: the arbitrator sets the result, holders redeem their tokens, and the creator gets the pool back. Bonds, a challenge window and disputes are phase 2 and will change this interface.

## Lifecycle

```
Open ──(closeTime)──▶ Closed ──arbitrator: resolve(Yes | No)──▶ Resolved   winning token pays 1, losing 0
                        │
                        ├──arbitrator: resolve(Invalid)───────▶ Cancelled  every token pays 0.5
                        │
                        └──(resolutionDeadline, no result)────▶ Cancelled  (derived, no transaction)
```

- `Closed` and the timeout `Cancelled` are derived from `block.timestamp` in `state()`. Nobody needs to send a transaction for either.
- `resolutionDeadline() = closeTime + RESOLUTION_WINDOW` (7 days). The arbitrator can resolve from `closeTime` up to one second before it.
- A result can't be changed. A resolved market never times out.
- Trading is blocked in every state except `Open` (the existing `_requireOpen`).

## Functions

| Function | Who | When | What it does |
|---|---|---|---|
| `resolve(Resolution r)` | `arbitrator` only | `Closed` | `Yes`/`No` → `Resolved`; `Invalid` → `Cancelled`. Emits `MarketResolved` (and `MarketCancelled` for `Invalid`) |
| `finalize()` | anyone | timeout `Cancelled` not yet stored | Stores the cancellation and emits `MarketCancelled`. Optional: only useful for indexers |
| `redeem(yesAmount, noAmount)` | any holder | `Resolved` or `Cancelled` | Burns the caller's tokens, then pays. No approval needed. Emits `Redeemed` |
| `claimLiquidity()` | anyone (pays `creator`) | `Resolved` or `Cancelled` | Redeems every YES/NO token the market itself holds (the AMM pool, plus any donated tokens) and pays `creator`. Emits `LiquidityClaimed` |
| `previewRedeem(yesAmount, noAmount)` | view | final | What `redeem` would pay |
| `finalResolution()` | view | final | `Yes`/`No` when `Resolved`, `Invalid` when `Cancelled` |
| `withdrawFees()` | anyone (pays `creator`) | not `Open` | Unchanged from the trading engine |

Errors: `NotArbitrator`, `NotClosed(state)`, `NotFinal(state)`, `NothingToFinalize(state)`, `NothingToClaim`, `ZeroAmount`. Redeeming more than you hold reverts with OpenZeppelin's `ERC1155InsufficientBalance`.

## Why payouts are always covered

Tokens are only minted and burned in YES+NO pairs, one pair per unit of collateral, so `totalSupply(YES) == totalSupply(NO) == backing`. Every result pays exactly the backing:

- **Resolved YES:** `totalSupply(YES) × 1`
- **Resolved NO:** `totalSupply(NO) × 1`
- **Cancelled:** `(totalSupply(YES) + totalSupply(NO)) × 0.5`

Payouts are rounded down, so at most a few raw units of dust can stay in the market. Fees (`accruedFees`) are paid separately and are never part of the backing.

Example: seed 100, Alice buys YES for 10.10 (fee 0.10) and gets about 19.09 YES. The pool then holds about 90.91 YES and 110 NO.

| Result | Alice | Creator (`claimLiquidity`) | Total |
|---|---|---|---|
| YES | 19.09 | 90.91 | 110 |
| NO | 0 | 110 | 110 |
| Cancelled | 9.55 | 100.45 | 110 |

A cancelled market pays fair value (0.5 per token), not "money back", so the UI should say so.

## Frontend notes (E5-8)

- **Show the resolve button** to the arbitrator when `state() == Closed`.
- **Show the redeem button** when `state()` is `Resolved` or `Cancelled`. Call `redeem(yesBalance, noBalance)` in one transaction, so a holder of both sides is only rounded once.
- **Show the payout** from `previewRedeem`.
- **Read the result** with `finalResolution()`, or from the `MarketResolved` / `MarketCancelled` events. A timeout cancellation has no event until someone calls `finalize()`, so read `state()` rather than relying on events alone.

## Tests

`test/MarketResolution.t.sol`, 28 tests:
- resolve access and timing, including exact deadline edges
- payouts for YES, NO, INVALID and timeout
- double and excess redeem
- `finalize` edge cases
- `claimLiquidity`, including donated tokens
- fees after resolution
- a full settlement that leaves 0 behind
- a 1000-run fuzz test that settlement never pays more than the backing
- reentrancy through a malicious collateral token
