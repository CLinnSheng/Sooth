# Market settlement and payouts

Each market closes trading at its configured `closeTime`. Its arbitrator can resolve it during the following seven-day resolution window. If it remains unresolved at the deadline, the market is cancelled and settles using the cancellation payout.

## Lifecycle and resolution

| Time or event | Market state | Behavior |
|---|---|---|
| Before `closeTime` | `Open` | Trading is available. |
| From `closeTime` until the resolution deadline | `Closed` | Trading stops; the configured arbitrator can call `resolve(outcome)`. |
| A valid resolution | `Resolved` | The winning outcome is stored, including after the deadline. |
| At or after `closeTime + 7 days`, if unresolved | `Cancelled` | The market uses the cancellation payout. |

`Closed` and `Cancelled` are derived from the block timestamp; neither transition requires a transaction. A successful `resolve` stores `Resolved` and the winning outcome. Only the arbitrator can resolve, and it cannot resolve before close, at or after the deadline, or a second time.

The `IMarket.State` enum also contains `Proposed`, but `Market` does not enter that state. Optimistic proposal and dispute statuses are tracked separately by the optimistic resolver.

## Holder redemption

After resolution or cancellation, a holder calls `redeem()` to burn their YES and NO balances and receive collateral. Amounts below are in raw six-decimal units:

| Settlement | Payout |
|---|---|
| `Resolved` | One raw collateral unit per raw unit of the winning outcome; losing shares pay zero. |
| `Cancelled` | `floor((yesBalance + noBalance) / 2)` raw collateral units. |

The cancellation calculation combines both balances before rounding down. Cancellation is a half-unit payout per share, not a refund of the holder's original trade cost.

`redeem()` reverts before settlement or when the calculated payout is zero. When a holder has both winning and losing shares, a successful redemption burns both balances; a holder with only losing shares cannot redeem them for collateral. Redemptions are separate transactions for each holder.

## Creator liquidity and fees

After resolution or cancellation, anyone can call `withdrawLiquidity()` once. It burns the market's recorded pool shares and pays their settlement value to the market's `creator`, using the same payout calculation as holder redemption. The recorded reserves remain unchanged after withdrawal so the market's final spot prices remain readable.

Fee withdrawal is separate from liquidity withdrawal. At or after `closeTime`, anyone can call `withdrawFees()` to send all accrued trading fees to the creator. It reverts if no fees are available. Fees and their rounding are described in the [trading engine](trading-engine.md).

## Limitations and related documentation

The automatic time-based state changes do not send collateral: redemption and withdrawal each require a transaction. Successful transfers depend on the configured collateral token's behavior. Cancellation payouts round down per redemption or liquidity-withdrawal call, which can leave raw-unit dust in the market. Unsolicited collateral and outcome-token transfers are not added to recorded reserves or fees.

For the arbitrators' configuration and settlement rules, see the [Chainlink resolver](chainlink-resolver.md) and [optimistic resolver](optimistic-resolver.md) guides. For creation and collateral assumptions, see [market creation and outcome tokens](market-creation-explained.md).

Run the lifecycle and payout tests from `contracts/`:

```sh
forge test --match-contract MarketResolutionTest
```
