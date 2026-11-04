# Trading engine

Each market uses a constant-product automated market maker (AMM) to trade YES and NO shares against collateral. Its recorded share reserves determine prices and trade amounts. The market starts with equal reserves, as described in [market creation](market-creation-explained.md).

## Pool model and pricing

One YES and one NO share together are backed by one unit of collateral. Buying uses collateral to mint paired shares into the pool and pays the buyer in the selected outcome. Selling returns shares to the pool, which burns pairs to release collateral.

The constant-product invariant is `k = yesPool × noPool`. Trades preserve this product or increase it through rounding: $k_{after} \ge k_{before}$

The reserve-based spot prices use 18-decimal precision:

```text
priceYes = noPool  × 1e18 / (yesPool + noPool)
priceNo  = yesPool × 1e18 / (yesPool + noPool)
```

Buying an outcome raises its price; selling lowers it, subject to rounding. The spot price is not an execution quote: a trade also has price impact and a fee.

## Trading and fees

The formulas below use integer amounts in six-decimal raw units, where `1e6` is one collateral unit or share. For either outcome, `a` is its reserve and `b` is the opposite reserve.

### Buy

For collateral input `c`, the fee is charged on `c` and net collateral is `n = c - fee`:

```text
selectedAfter = ceil(a × b / (b + n))
sharesOut     = a + n - selectedAfter
```

The net collateral mints `n` shares of each outcome to the pool, which transfers `sharesOut` of the selected outcome to the buyer.

### Sell

For input `s` shares, the market finds the greatest integer gross collateral release `g` that preserves the reserve product:

```text
0 ≤ g ≤ min(s, b - 1)
(a + s - g) × (b - g) ≥ a × b
```

The pool receives the selected shares and burns `g` shares of each outcome. The fee is charged on `g`, so the seller receives `g - fee` collateral.

Each trade pays a 1% fee, rounded up to the next raw collateral unit. Fees accrue separately from the reserves for the market creator. See [market settlement and payouts](market-settlement.md) for fee withdrawal.

## Execution and design considerations

Quotes and trades are available while the market is open. Buyers approve the market to spend collateral; sellers approve it as an operator for their outcome shares. Trades specify a minimum output and a deadline, protecting the trader if reserves change before execution.

Contract quotes use the current recorded reserves. The frontend estimates trades using floating-point arithmetic, so its estimates can differ from the contract's integer calculations and fee rounding.

Unsolicited collateral or outcome-share transfers do not change recorded reserves or quotes. Donated shares can make the market's actual token inventory exceed its recorded reserves. See [market creation](market-creation-explained.md) for collateral assumptions.

## References

- [Market contract](../contracts/src/Market.sol) and [interface](../contracts/src/interfaces/IMarket.sol): trade calculations, quotes, and execution requirements.
- [Trading tests](../contracts/test/MarketTrading.t.sol): accounting, rounding, approvals, and trade constraints.
- [Market settlement and payouts](market-settlement.md): lifecycle, fee withdrawal, and redemption.
