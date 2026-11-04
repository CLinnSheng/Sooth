# Chainlink resolver

`ChainlinkResolver` resolves price markets using a configured Chainlink feed. A market uses it by setting the resolver as its arbitrator. After the market closes, anyone can submit the round used for settlement; the contract validates the round and calls the market's `resolve` function.

## Configuration and permissions

The resolver owner configures each market once, strictly before `closeTime`. The market must name this resolver as its arbitrator. Configuration contains a nonzero feed address, a threshold in the feed's decimals, a comparison (`Below` or `Above`), and a nonzero `maxStaleness` in seconds. The resolver does not verify that the chosen feed, threshold, or market spec describe the intended question.

The frontend's admin form offers the configured Base Sepolia ETH/USD feed and a one-hour maximum staleness. It creates the market and then requests a separate feed-configuration transaction. The creating wallet must have the factory's `DEFAULT_ADMIN_ROLE`; the configuring wallet must also own the resolver. If configuration fails or is rejected, the market can already exist without a configured feed. The form offers a retry while its unconfigured-market state is available; configuration must still succeed before close.

`CreateMarket.s.sol` can also create and configure a Chainlink market in one script run. Its broadcaster must be both a factory admin and the resolver owner. Approval, creation, and configuration are separate broadcast transactions, so configuration can fail after the market has been created. If that happens, check `configOf(market)`: a zero feed address means the resolver owner must configure the market before close. Once the market closes, it cannot be configured and remains unresolved until cancellation.

## Price selection and outcome

The submitted `roundId` must identify the feed round live at `closeTime`. The resolver checks that:

- The round exists, has a positive answer, and has `updatedAt <= closeTime`.
- `closeTime - updatedAt <= maxStaleness`.
- The round is the latest round, or its next round was updated after close. The next round is `roundId + 1` within a phase, or the first round of the next phase when the current phase has ended.

For `Below`, YES wins if the answer is strictly less than the threshold. For `Above`, YES wins if it is strictly greater. A tie resolves NO in either case. For example, a threshold of `200000000000` represents `2000` for a feed with eight decimals; use the selected feed's actual decimals.

The resolver does not catch errors from feed reads. This prevents a failed next-round read, including an out-of-gas failure, from being treated as proof that no later round exists. A failed check or feed read reverts the resolution transaction. The market itself permits resolution only while closed and before its deadline; an unresolved market cancels at `closeTime + 7 days`. See [market settlement and payouts](market-settlement.md).

Example spec wording:

> YES if the last Chainlink ETH/USD value published at or before 2026-11-30 00:00:00 UTC is below 2000.00000000. Equal resolves NO.

## Resolution paths

- The bot attempts to resolve configured, closed Chainlink markets during its polls. A failed feed read, stale round, transaction, or unavailable bot can delay or prevent resolution; a one-poll result is not guaranteed. See the [bot guide](../bot/README.md).
- The market page offers a Resolve action for a configured, closed market and displays the feed condition and settled price.
- Anyone can run `script/ResolveChainlinkMarket.s.sol` with `RESOLVER` and `MARKET`. Set `ROUND_ID` to supply a round directly instead of searching.

The bot, frontend, and script search the feed's current phase only. If the market closed before that phase, find the appropriate round and pass it as `ROUND_ID` to the script. The contract can validate the last round of an earlier phase when the feed's next-round reads support it.

## Feed and network limitations

- Chainlink feeds update on heartbeat or deviation conditions; their settings vary by feed and network, and network conditions can delay updates. The settlement answer is an on-chain feed value at or before close, not necessarily the contemporaneous market price. Check the chosen feed's parameters in the [Chainlink feed catalog](https://docs.chain.link/data-feeds/price-feeds/addresses).
- The resolver checks age relative to the market's close, but has no L2 sequencer uptime check. Staleness is not a substitute for sequencer health or a recovery grace period. Evaluate [Chainlink's L2 sequencer guidance](https://docs.chain.link/data-feeds/l2-sequencer-feeds) before deploying on an L2.
- `maxStaleness` is fixed when the market is configured. If no valid round meets the checks before the resolution deadline, the market remains unresolved and then cancels.

## Deployment and operation

Run these Foundry commands from `contracts/`. They use a keystore named `deployer`; `SENDER` must be the address of that keystore. Set `RPC_URL`, `SENDER`, `FACTORY`, `RESOLVER`, `CLOSE_TIME`, and, for resolution, `MARKET` to values for your deployment. `CLOSE_TIME` is a future Unix timestamp, and `spec.json` must contain the intended market spec.

Deploy the resolver. Its owner defaults to the broadcasting wallet; set `ADMIN` in the environment to use another owner.

```sh
forge script script/DeployChainlinkResolver.s.sol \
  --rpc-url "$RPC_URL" --account deployer --sender "$SENDER" --broadcast
```

Create and configure a market using a wallet that is both a factory admin and the resolver owner. `LIQUIDITY` defaults to `100e6` raw collateral units; `MAX_STALENESS` defaults to `3600` seconds.

```sh
FACTORY="$FACTORY" RESOLVER="$RESOLVER" CLOSE_TIME="$CLOSE_TIME" \
FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 \
THRESHOLD=200000000000 COMPARISON=below MAX_STALENESS=3600 \
SPEC="$(cat spec.json)" \
forge script script/CreateMarket.s.sol \
  --rpc-url "$RPC_URL" --account deployer --sender "$SENDER" --broadcast
```

The example feed is the address offered by the frontend on Base Sepolia. Verify the feed and signer configuration for the target deployment. The inline assignments pass the factory, resolver, close time, and feed settings to the script even if the corresponding shell variables have not been exported.

After the market closes, any funded signer can run the resolution script. Set `ROUND_ID` in the environment to use a specific round instead of the automatic search.

```sh
RESOLVER="$RESOLVER" MARKET="$MARKET" \
forge script script/ResolveChainlinkMarket.s.sol \
  --rpc-url "$RPC_URL" --account deployer --sender "$SENDER" --broadcast
```

For contract checks, run:

```sh
forge test --match-contract ChainlinkResolverTest
```
