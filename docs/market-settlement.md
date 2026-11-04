# Market settlement and payouts

Each market closes trading at its configured `closeTime`. Its arbitrator can resolve it during the following seven-day resolution window. If it remains unresolved at the deadline, the market is cancelled and settles using the cancellation payout.

## Market lifecycle

| Time or event | Market state | Behavior |
|---|---|---|
| Before `closeTime` | `Open` | Trading is available. |
| From `closeTime` until the resolution deadline | `Closed` | Trading stops; the configured arbitrator can call `resolve(outcome)`. |
| A valid resolution | `Resolved` | The winning outcome is stored, including after the deadline. |
| At or after `closeTime + 7 days`, if unresolved | `Cancelled` | The market uses the cancellation payout. |

Closing and cancellation are determined by time and require no transaction. Only the arbitrator can resolve a closed market, and it must do so before the deadline. A resolved market remains resolved after the deadline.

Resolver requests are tracked separately: an optimistic market remains closed while a proposal or dispute is pending. See the [Chainlink resolver](chainlink-resolver.md) and [optimistic resolver](optimistic-resolver.md) for their resolution rules.

## Payouts

After resolution or cancellation, holders can redeem their shares for collateral. Amounts below are in raw six-decimal units:

| Settlement | Payout |
|---|---|
| `Resolved` | One raw collateral unit per raw unit of the winning outcome; losing shares pay zero. |
| `Cancelled` | `floor((yesBalance + noBalance) / 2)` raw collateral units. |

Cancellation combines both balances before rounding down. It pays half a collateral unit per share, rather than refunding the holder's original trade cost. Rounding down can leave raw-unit dust in the market.

Redemption requires a transaction and burns the holder's YES and NO balances together. It reverts if the payout is zero, including when a holder has only losing shares.

The market creator receives the settlement value of the pool's shares after resolution or cancellation. Anyone can trigger this liquidity withdrawal once, but the payout always goes to the creator. The pool shares are burned while the recorded reserves remain unchanged, keeping the final spot prices readable.

Trading fees also belong to the creator and can be withdrawn by anyone on the creator's behalf at or after close, separately from liquidity. See the [trading engine](trading-engine.md) for fee accounting.

## References

- [Market contract](../contracts/src/Market.sol) and [interface](../contracts/src/interfaces/IMarket.sol): state transitions and payout calculations.
- [Resolution tests](../contracts/test/MarketResolution.t.sol): lifecycle, redemption, and liquidity withdrawal.
- [Market creation and outcome tokens](market-creation-explained.md): collateral assumptions and market configuration.
