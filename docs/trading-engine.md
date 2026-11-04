# Trading engine

Each market clone implements a two-outcome constant-product automated market maker (AMM). Its recorded YES and NO reserves determine prices and trade amounts. The market holds outcome shares in the factory's shared ERC-1155 contract and uses the factory's fixed six-decimal collateral token.

## Pool model and prices

At creation, the market records equal YES and NO reserves and mints the corresponding shares to itself. See [market creation and outcome tokens](market-creation-explained.md) for seeding and collateral requirements.

Collateral and shares use six-decimal raw units: `1e6` represents one whole collateral unit or one whole outcome share. ERC-1155 does not define a decimals field; the collateral token reports its decimals.

The product of the recorded reserves is preserved or increased by rounding during supported trades. Unsolicited collateral or outcome-token transfers do not change recorded reserves or quotes; donated outcome shares can make actual token inventory exceed the reserves. After liquidity withdrawal, recorded reserves remain unchanged to preserve the final price even though the pool shares have been burned.

`priceYes()` and `priceNo()` return reserve-based spot prices at 18-decimal precision:

```text
priceYes = noPool  × 1e18 / (yesPool + noPool)
priceNo  = yesPool × 1e18 / (yesPool + noPool)
```

These are spot prices, not execution quotes: a trade also has price impact and a fee. Buying an outcome moves its price upward; selling it moves its price downward, subject to integer rounding.

## Buy and sell accounting

For both formulas, `a` is the selected outcome reserve and `b` is the opposite reserve. Amounts are integers in raw units. The fee is 1%, rounded up to the next raw collateral unit.

### Buy

For collateral input `c`, the fee is charged on `c` and net collateral is `n = c - fee`:

```text
selectedAfter = ceil(a × b / (b + n))
sharesOut     = a + n - selectedAfter
```

The market receives `c`, accrues the fee, mints `n` YES and `n` NO shares to itself, updates the recorded reserves, and transfers `sharesOut` of the selected outcome to the buyer.

### Sell

For input `s` shares, the market finds the greatest integer gross collateral release `g` that preserves the reserve product:

```text
0 ≤ g ≤ min(s, b - 1)
(a + s - g) × (b - g) ≥ a × b
```

The contract computes `g` using binary search and full-precision division. It charges the fee on `g`, so the seller receives `g - fee`. The market receives the selected shares, burns `g` of each outcome from its own inventory, updates reserves, accrues the fee, and transfers the net collateral to the seller.

## Quotes and execution

`quoteBuy` and `quoteSell` use the current recorded reserves and return the output amount and fee without requiring the caller to hold tokens or grant approval. Both quotes and trades require the market to be `Open`; they revert at or after `closeTime`. Zero input or a trade that would produce zero output also reverts.

`buy` requires the buyer to approve the market to spend the collateral input. `sell` requires the seller to call `setApprovalForAll(market, true)` on the outcome-token contract. Both accept a minimum output and a deadline. Execution reverts if the output is below the minimum or the deadline is earlier than the block timestamp; a deadline equal to the timestamp is accepted.

Quotes describe the reserves at the time they are read, which can change before execution. The frontend calculates estimates locally using floating-point arithmetic; these estimates can differ from the contract's integer calculations and fee rounding. The minimum output is the execution constraint, not a guarantee that an earlier quote remains current.

## Fee accounting

Each market records fees in `accruedFees`, separately from AMM reserves, for its `creator`: the account that created the market and provided its seed collateral. At or after `closeTime`, anyone can call `withdrawFees()` to transfer the entire accrued amount to that creator. The caller cannot choose the recipient.

Withdrawal reverts while the market is open or if there are no fees. It clears the recorded amount before transferring, uses reentrancy protection, and emits `FeesWithdrawn`. If the transfer fails, the transaction reverts and the fee balance is restored.

## Limits and related documentation

The factory requires collateral that reports six decimals, but does not verify that it is USDC or that its transfer and balance behavior is suitable. Accounting and payouts depend on the configured token behaving as expected. Existing clones use their original implementation; changing market code requires deploying a new factory for new markets.

For creation and deployment prerequisites, see [market creation and outcome tokens](market-creation-explained.md) and `contracts/script/DeployMarketFactory.s.sol`. For payouts and resolver-specific behavior, see [market settlement and payouts](market-settlement.md), the [Chainlink resolver](chainlink-resolver.md), and the [optimistic resolver](optimistic-resolver.md).

Run the trading tests from `contracts/`:

```sh
forge test --match-contract MarketTradingTest
```
