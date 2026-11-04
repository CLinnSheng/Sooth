# Optimistic resolver

`OptimisticResolver` settles markets through bonded proposals. It is suited to questions that require evidence or interpretation beyond a price-feed comparison. A market selects the resolver as its arbitrator; the resolver's owner acts as the judge for disputes.

## Resolution workflow

After a market closes, anyone can propose YES or NO by posting a bond. During the challenge window, anyone can dispute that proposal by posting an equal bond. Each market can have one proposal and at most one dispute.

If the proposal is undisputed, anyone can finalize it at or after the challenge window ends. If it is disputed, only the judge can rule on the outcome. Neither path is automatic: a transaction must resolve the market before its resolution deadline.

A proposal is accepted only if its challenge window ends strictly before the market's deadline. Disputes must be submitted before the challenge window ends. If the market cancels with a request still open, anyone can trigger a refund of the posted bonds. See [market settlement and payouts](market-settlement.md) for the market lifecycle.

## Bonds and incentives

Each resolver is bound to one factory and uses its collateral token for bonds. Its bond amount and challenge window are fixed at deployment; both must be nonzero, and the window must be shorter than the market's seven-day resolution window. Proposers and disputers must each approve the resolver to transfer their bond.

| Path | Bond payment |
|---|---|
| Undisputed proposal finalized | The proposer receives their bond back. |
| Judge rules for the proposed outcome | The proposer receives both bonds. |
| Judge rules against the proposed outcome | The disputer receives both bonds. |
| Market cancels with an open request | Each party receives their bond back. |

An undisputed proposer earns no reward beyond return of their bond. Participants pay their own transaction costs.

## Design decisions and limitations

The resolver does not validate evidence, so participants must monitor proposals and the judge must assess disputes independently. Evidence URIs are emitted in events rather than stored in the request, and may be empty. Proposal and dispute statuses are separate from the market state; the market remains closed until resolution or cancellation.

The optional [bot](../bot/README.md) can propose from a market's source page, attempt finalization and refunds, and alert on disputes. Its actions depend on its checks and successful transactions.

Bond payments are pushed during settlement. A failed transfer reverts the transaction, including any market resolution in it; a later refund can also fail if the transfer remains blocked. There is no early cancellation for an invalid market: if unresolved, it cancels at its deadline.

## References

- [Resolver contract](../contracts/src/OptimisticResolver.sol) and [interface](../contracts/src/interfaces/IOptimisticResolver.sol): requests, actions, and bond settlement.
- [Resolver tests](../contracts/test/OptimisticResolver.t.sol): timing, permissions, bond payments, and refunds.
- [Deployment](../contracts/script/DeployOptimisticResolver.s.sol) and [market creation](../contracts/script/CreateMarket.s.sol) scripts: configuration and operation.
- [Chainlink resolver](chainlink-resolver.md): price-feed settlement for questions that can be decided by a threshold.
