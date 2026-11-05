# Chainlink resolver

`ChainlinkResolver` settles price markets by comparing a Chainlink feed value with a fixed threshold. A market selects it as its arbitrator. Unlike the [optimistic resolver](optimistic-resolver.md), it has no proposal, bond, or dispute process.

## Resolution

After close, anyone can submit a feed round to resolve the market. The resolver checks that the round was the latest at or before `closeTime`, has a positive price, and is no older than the configured maximum staleness. It compares that price with the threshold and resolves the market before its resolution deadline.

For a `Below` comparison, YES wins when the price is strictly below the threshold; for `Above`, YES wins when it is strictly above. Equality resolves NO in both cases. The threshold uses the feed's decimals: for an eight-decimal feed, `200000000000` represents 2,000.

For example, a market can ask whether the last ETH/USD value published at or before close was below $2,000. The outcome depends on that on-chain observation, not necessarily the market price at the exact closing time.

## Configuration

The resolver owner configures each market once, before it closes, with a nonzero feed, threshold, comparison, and nonzero maximum staleness. The market must name the resolver as its arbitrator. The resolver does not verify that this configuration matches the market's written question.

Market creation and feed configuration are separate transactions. The creating wallet must be a factory admin, and the configuring wallet must own the resolver. If configuration fails after creation, the owner must configure the market before close; otherwise it cannot resolve through this resolver and will eventually cancel. The [frontend guide](../web/README.md) describes its creation and retry workflow.

## Design decisions and limitations

Chainlink feeds update according to their own heartbeat and deviation settings, and updates can be delayed. A round that fails the validity or staleness checks cannot settle the market. Failed feed reads also revert resolution rather than being treated as proof that no newer round exists. If the market remains unresolved through its deadline, it cancels; see [market settlement and payouts](market-settlement.md).

The resolver has no L2 sequencer uptime check. Price staleness does not substitute for checking sequencer health or a recovery grace period; consider [Chainlink's sequencer guidance](https://docs.chain.link/data-feeds/l2-sequencer-feeds) when deploying on an L2.

The [bot](../bot/README.md), frontend, and resolution script search only the feed's current phase. If the market closed in an earlier phase, an appropriate round can be supplied manually to the script using `ROUND_ID`. The contract can validate an earlier-phase round when the feed supports the required next-round reads.

## References

- [Resolver contract](../contracts/src/ChainlinkResolver.sol) and [interface](../contracts/src/interfaces/IChainlinkResolver.sol): configuration and round validation.
- [Resolver tests](../contracts/test/ChainlinkResolver.t.sol): comparisons, round selection, and resolution constraints.
- [Deployment](../contracts/script/DeployChainlinkResolver.s.sol), [market creation](../contracts/script/CreateMarket.s.sol), and [resolution](../contracts/script/ResolveChainlinkMarket.s.sol) scripts: configuration and operation.
- [Chainlink feed catalog](https://docs.chain.link/data-feeds/price-feeds/addresses): feeds and their network-specific settings.
