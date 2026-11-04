# Optimistic resolver

`OptimisticResolver` settles markets through bonded proposals. An undisputed proposal can be finalized after a challenge window; a disputed proposal is decided by the resolver owner, called the judge. A market uses the resolver by setting it as its arbitrator.

## When to use

Use this resolver when a question needs evidence or interpretation beyond a price-feed comparison. For example: “Did an organization announce a product by close?” A proposer submits YES or NO with a bond; if someone disputes the proposal, the judge decides the outcome.

For a question decided by comparing a supported feed's price with a fixed threshold, see the [Chainlink resolver](chainlink-resolver.md), which derives the outcome from the feed without a proposal or judge.

## Configuration

Each resolver is bound to one factory and uses its collateral token for bonds. The judge, bond amount, and challenge window are set at deployment; the bond and window must be nonzero, and the window must be shorter than the market's seven-day resolution window. The deployment script defaults to a bond of `10e6` raw collateral units and a two-hour window. The bond and window are fixed for that resolver; markets need no additional resolver configuration.

The judge is the resolver owner. Ownership transfer uses `Ownable2Step`: the current owner calls `transferOwnership`, and the new owner must call `acceptOwnership`.

## How settlement works

1. After a market closes, anyone can call `propose` with YES (`0`) or NO (`1`), an evidence URI, and an allowance for one bond. The market must belong to the configured factory and name this resolver as its arbitrator. Each market can have only one request.
2. The proposal's challenge window must end strictly before the market's resolution deadline. Anyone can call `dispute` before the window ends, providing an evidence URI and an allowance for another bond. Only one dispute is accepted.
3. If undisputed, anyone can call `finalize` at or after the window end. If disputed, only the judge can call `rule` with the winning outcome. Either action must resolve the market before its deadline.
4. If the market becomes cancelled with a proposed or disputed request still open, anyone can call `refund` to return the posted bonds.

The resolver request's `Proposed` and `Disputed` statuses are separate from the market's state; the market remains `Closed` until resolution or cancellation. See [market settlement and payouts](market-settlement.md) for market states and share redemption.

### Bond settlement

| Path | Bond payment |
|---|---|
| Undisputed proposal finalized | The proposer receives their bond. |
| Judge rules for the proposed outcome | The proposer receives both bonds. |
| Judge rules against the proposed outcome | The disputer receives both bonds. |
| Market cancels with an open request | Each party that posted a bond receives it back through `refund`. |

The caller triggering finalization or refund cannot choose the recipient. There is no proposer reward beyond return of the bond; participants pay their own transaction costs.

## Clients and automation

`propose` and `dispute` emit their evidence URI in events; the URI is not stored in the request. The resolver does not validate the URI or evidence, and it accepts an empty string. A judge must assess disputed evidence independently.

The [bot](../bot/README.md) can propose from the market spec's source page, using a `data:` URI containing its reasoning and quotes. It also attempts to finalize undisputed requests, refund bonds on cancelled markets, and alert on disputes. These actions depend on the bot's checks and successful transactions.

The market page displays the request and available actions. It hides the dispute action during the final 60 seconds of the challenge window, even though the contract accepts a dispute until the window ends. The rule action is available only to the judge wallet.

## Limitations

- Bond payouts are pushed during settlement. If a transfer fails, the transaction reverts, including any market resolution in that transaction. The market cancels only if it remains unresolved until its deadline; a later `refund` can also fail if a bond transfer remains blocked.
- There is no early cancellation action for an invalid market. If it is not resolved, it becomes cancelled at its resolution deadline.
- The contract relies on the configured collateral token's transfer behavior. Its six-decimal requirement does not guarantee that bond transfers will succeed.

## Deployment and operation

Run these Foundry commands from `contracts/`. Set `RPC_URL`, `FACTORY`, `RESOLVER`, `MARKET`, `BOND_TOKEN`, `BOND`, and `CLOSE_TIME` for your deployment. `BOND` is the resolver's bond in raw collateral units, `BOND_TOKEN` is the factory's collateral token, and `CLOSE_TIME` is a future Unix timestamp. `spec.json` must contain the intended market spec. Use a funded keystore named by `ACCOUNT` and set `SENDER` to its address.

Deploy the resolver. `ADMIN` optionally sets the judge and defaults to the broadcasting wallet; `BOND` and `CHALLENGE_WINDOW` optionally override the deployment defaults.

```sh
FACTORY="$FACTORY" forge script script/DeployOptimisticResolver.s.sol \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --sender "$SENDER" --broadcast
```

Create a market using a factory admin wallet. This example selects the optimistic resolver by setting `ARBITRATOR` and clears `FEED` so an inherited value cannot select Chainlink mode:

```sh
FACTORY="$FACTORY" ARBITRATOR="$RESOLVER" CLOSE_TIME="$CLOSE_TIME" \
FEED=0x0000000000000000000000000000000000000000 \
SPEC="$(cat spec.json)" \
forge script script/CreateMarket.s.sol \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --sender "$SENDER" --broadcast
```

After close, a proposer approves a bond and proposes an outcome. A disputer must separately approve a bond from their own wallet before disputing. Set `ACCOUNT` and `SENDER` to the corresponding wallet for each action.

```sh
cast send "$BOND_TOKEN" 'approve(address,uint256)' "$RESOLVER" "$BOND" \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --from "$SENDER"
cast send "$RESOLVER" 'propose(address,uint8,string)' "$MARKET" 1 'ipfs://evidence' \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --from "$SENDER"

# After the disputer approves one bond from their own wallet:
cast send "$RESOLVER" 'dispute(address,string)' "$MARKET" 'ipfs://evidence' \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --from "$SENDER"
```

Use an appropriate funded wallet for each of the following alternative paths. Only the judge can call `rule`; the example rules YES.

```sh
# After an undisputed window, before the market deadline:
cast send "$RESOLVER" 'finalize(address)' "$MARKET" \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --from "$SENDER"
# A disputed request, before the market deadline (judge wallet):
cast send "$RESOLVER" 'rule(address,uint8)' "$MARKET" 0 \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --from "$SENDER"
# A cancelled market with an open request:
cast send "$RESOLVER" 'refund(address)' "$MARKET" \
  --rpc-url "$RPC_URL" --account "$ACCOUNT" --from "$SENDER"
```

Run the resolver tests from `contracts/`:

```sh
forge test --match-contract OptimisticResolverTest
```
