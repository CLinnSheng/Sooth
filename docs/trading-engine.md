# Trading engine

Each market clone is its own two-outcome constant-product AMM. The factory seeds it with six-decimal collateral; the market mints an equal number of YES and NO shares into its own ERC-1155 inventory. Shares use the collateral's raw units: `1e6` units is one whole outcome share. ERC-1155 has no standard decimals field; clients can read `decimals()` from the market's collateral token.

At initialization, `yesPool` and `noPool` are both `initialLiquidity`. The market checks the collateral arrived and verifies its actual YES/NO balances exactly match the recorded reserves. Later unsolicited transfers do not alter reserves or quotes; actual inventory may exceed reserves, never fall below them through supported trades.

## Trading

Trades are open to any address while `market.state() == Open`, before `closeTime`. The quote views use current recorded reserves and need no token balance or approval. Execution functions accept a deadline and minimum output to limit stale-quote and slippage risk.

For a buy of outcome reserve `a`, opposite reserve `b`, and collateral input `c`, the fee is rounded up to the next raw USDC unit. The net input `n = c - fee` buys outcome shares:

```text
selectedAfter = ceil(a × b / (b + n))
sharesOut     = a + n - selectedAfter
```

The market receives `c`, records the fee in `accruedFees`, mints `n` YES and `n` NO shares, and sends `sharesOut` of the selected outcome to the buyer. Buyers approve the market to spend USDC first.

For a sell of `s` shares, the engine finds the greatest integer gross collateral release `g` that preserves the reserve product:

```text
0 ≤ g ≤ min(s, b - 1)
(a + s - g) × (b - g) ≥ a × b
```

It computes this bound using integer binary search and full-precision division. The fee is rounded up; the seller receives `g - fee`. The seller approves the market as ERC-1155 operator. The market receives the seller's shares, burns `g` of both outcomes from its own balance, updates reserves, and pays the seller.

`priceYes()` and `priceNo()` report the current reserve-based probabilities at 18-decimal precision. They are spot prices; quote functions report execution amounts including fee and price impact. A trade moves the price toward the outcome bought or away from the outcome sold, while the constant-product reserve invariant is preserved or increased by rounding.

All collateral and share amounts use six-decimal raw units: `1e6` is one USDC or one whole outcome share. The factory rejects collateral that does not report six decimals. Fee rounding, reserves, minting, burning, and collateral accounting all use those same raw units.

## Fees and deployment

Each market accrues the existing 1% fee in `accruedFees`, owed to its recorded `creator`: the platform wallet that supplied the seed liquidity and called `createMarket`. Fees remain as collateral in the market, outside AMM reserves. At or after `closeTime`, anyone can call `withdrawFees()` to transfer the entire accrued amount to that creator. The caller cannot choose a recipient. Withdrawal clears the fee balance before transferring, uses reentrancy protection, and emits `FeesWithdrawn`. It reverts while the market is Open or when no fees remain. A failed transfer restores the fee balance through transaction rollback.

Deploy the factory with `(admin, collateral)` using a six-decimal collateral token. Each market pays its own creating wallet, which may differ between platform admins. On test chains, omitting `COLLATERAL` deploys `MockUSDC`; on other chains pass the intended collateral token. Existing market clones use their original implementation, so markets deployed without withdrawal support cannot gain it; deploy a new factory for markets supporting fee withdrawal.

Example local deployment:

```sh
forge script script/DeployMarketFactory.s.sol:DeployMarketFactory \
  --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil-key>
```

Before creation, approve seed USDC to the factory. Before trading, approve buy USDC to the market or call `setApprovalForAll(market, true)` on the outcome-token contract to sell. After trading closes, call `withdrawFees()` on the market to pay its creator; pool backing and unsolicited collateral donations remain in the market. Run `forge test` from `contracts/` for factory and trading tests.
