# Contract specification

This is the single reference for every Sooth contract: interfaces, storage, access rules and state rules.
It was written from `contracts/src` on `lin/integration` at `3159dec`. It says *what* each function does.
For *why* and worked examples, follow the links to the per-component docs.

- System overview: [architecture.md](architecture.md)
- Market creation and outcome tokens: [market-creation-explained.md](market-creation-explained.md)
- AMM pricing and fees: [trading-engine.md](trading-engine.md)
- Resolvers: [chainlink-resolver.md](chainlink-resolver.md), [optimistic-resolver.md](optimistic-resolver.md)
- Order book: [order-book.md](order-book.md)
- Properties that must hold: [invariants.md](invariants.md). Risks: [threat-model.md](threat-model.md). Slither and coverage: [security-analysis.md](security-analysis.md)

## Conventions

- **Units.** Amounts are raw collateral units. The collateral has 6 decimals, so `1e6` is 1 USDC. One whole
  outcome share is also `1e6` units, because each YES+NO pair is backed by exactly one collateral unit.
- **Prices.** `Market.priceYes` and `priceNo` use 18 decimals (`1e18` = 100%). Order-book prices use
  `PRICE_SCALE` (`1e6` = 1 USDC per whole share).
- **Enums** are `uint8` in the ABI. `Outcome`: 0 = `Yes`, 1 = `No`.
- **"Anyone"** means any address. **"View"** means a read with no state change.
- **"Inherited"** means the item comes from OpenZeppelin and is not written in Sooth code.
- Solidity `^0.8.24`, built with `0.8.28` (see `contracts/foundry.toml`).

## Contracts at a glance

| Contract | File | Kind | How many | Admin | Base Sepolia (84532) |
|---|---|---|---|---|---|
| `MarketFactory` | `src/MarketFactory.sol` | Entry point, creates markets | 1 | `DEFAULT_ADMIN_ROLE` | `0x8d399B14ea106bA62F79186217DB6fF1F75dc492` |
| `OutcomeToken` | `src/OutcomeToken.sol` | ERC-1155 for every market's shares | 1, deployed by the factory | none | `0xA2D1e9A1e195d01B1aC21090962B7F2AD76BDB5B` |
| `Market` | `src/Market.sol` | One binary market (AMM, resolution, payout) | 1 implementation + 1 EIP-1167 clone per market | none | implementation `0x3a69D08ba7Ab7CcE6f8f53Fc193bAD9Ac661D098`; clones from `factory.markets(id)` |
| `OptimisticResolver` | `src/OptimisticResolver.sol` | Arbitrator: bonded proposal, dispute, judge | 1 | owner = judge (`Ownable2Step`) | `0xe37DB6692De70F5fe69fcABb64b7C737fA096335` |
| `ChainlinkResolver` | `src/ChainlinkResolver.sol` | Arbitrator: price feed | 1 | owner (`Ownable`) | `0xAD3F05e6eFFeCD81278894266f5816691E704638` |
| `OutcomeOrderBook` | `src/OutcomeOrderBook.sol` | Fixed-price share listings (Bonus 1) | 1 | none | `0x539a5842371cEeA853A5Adab48bAFc2a5d9B2b05` |
| `OutcomeTokenId` | `src/libraries/OutcomeTokenId.sol` | Library: token id formula | inlined | n/a | n/a |
| `MockUSDC` | `src/mocks/MockUSDC.sol` | Test collateral, anyone can mint | test chains only | none | `0x5f29331BBBA6f605942f5de0B217359F3C7B7c51` |
| `MockAggregator` | `src/mocks/MockAggregator.sol` | Test Chainlink feed | tests only | none | not deployed |

Address sources: `contracts/broadcast/*/84532/run-latest.json` and `web/src/contracts.ts`. The factory
was deployed in block `50040022` (`DEPLOY_BLOCK` in `web/src/contracts.ts`). The `OutcomeToken` and the
`Market` implementation are created inside the factory constructor, so they appear as
`additionalContracts` of the factory deploy. The MockUSDC address is the `COLLATERAL` argument of every
factory deploy; the transaction that deployed MockUSDC is not in the broadcast files.

## Shared types

Defined in `src/interfaces/`.

| Type | Defined in | Fields or values |
|---|---|---|
| `IMarket.State` | `IMarket` | `Open` (0), `Closed` (1), `Proposed` (2), `Resolved` (3), `Cancelled` (4). Only `Open` and `Resolved` are stored. `Closed` and `Cancelled` are derived from the clock in `state()`. `Proposed` is never returned by `Market` (see [Notes](#notes-and-known-gaps)) |
| `IMarket.Outcome` | `IMarket` | `Yes` (0), `No` (1) |
| `IMarket.InitParams` | `IMarket` | `marketId`, `creator`, `arbitrator`, `closeTime` (`uint64`), `specHash` (`bytes32`), `initialLiquidity` |
| `IMarketFactory.CreateParams` | `IMarketFactory` | `arbitrator`, `closeTime` (`uint64`), `initialYesProbabilityBps` (`uint16`, must be 5000), `spec` (JSON string), `initialLiquidity` |
| `IOptimisticResolver.Status` | `IOptimisticResolver` | `None` (0), `Proposed` (1), `Disputed` (2), `Settled` (3) |
| `IOptimisticResolver.Request` | `IOptimisticResolver` | `proposer`, `outcome`, `status`, `proposedAt` (`uint64`), `disputer` |
| `IChainlinkResolver.Comparison` | `IChainlinkResolver` | `Below` (0): YES if price < threshold. `Above` (1): YES if price > threshold. A tie is NO |
| `IChainlinkResolver.Config` | `IChainlinkResolver` | `feed` (`AggregatorV3Interface`), `threshold` (`int256`, feed decimals), `comparison`, `maxStaleness` (`uint64` seconds) |
| `IOutcomeOrderBook.Listing` | `IOutcomeOrderBook` | `seller`, `market`, `outcome`, `price`, `remaining`, `prev`, `next` |
| `OutcomeOrderBook.Book` | `OutcomeOrderBook` (internal) | `head`, `tail`: ends of one (market, outcome) list. 0 = empty |

## 1. MarketFactory

Validates parameters, clones `Market`, seeds it with collateral and emits `MarketCreated`. Interface:
`IMarketFactory`. Inherits OpenZeppelin `AccessControl`. Details: [market-creation-explained.md](market-creation-explained.md).

### Storage and constants

| Name | Kind | Value or meaning |
|---|---|---|
| `MIN_LIQUIDITY` | public constant | `10e6` (10 USDC). Smallest seed |
| `FIFTY_FIFTY_BPS` | internal constant | `5_000`. The only accepted `initialYesProbabilityBps` |
| `implementation` | public immutable | The `Market` implementation, deployed in the constructor |
| `outcomeToken` | public immutable | The `OutcomeToken`, deployed in the constructor with this factory as `factory` |
| `collateral` | public immutable | The collateral token, fixed at deploy |
| `marketCount` | public storage | Number of markets. Ids start at 1 |
| `markets(marketId)` | public mapping | Market clone address by id. `address(0)` for unknown ids |

### Constructor

`constructor(address admin, address collateral_)`. Reverts `InvalidConfig` if either address is zero, and
`InvalidCollateralDecimals(decimals)` if the collateral does not report 6 decimals. Deploys
`OutcomeToken(address(this))` and `Market(address(this), token, collateral)`, then grants
`DEFAULT_ADMIN_ROLE` to `admin`.

### Functions

| Function | Who | When | Effect |
|---|---|---|---|
| `createMarket(CreateParams p) returns (marketId, market)` | `DEFAULT_ADMIN_ROLE` | Any time. Caller must approve the factory for `initialLiquidity` | Validates `p` (see errors). `marketId = ++marketCount`. Clones `implementation`, stores it in `markets`, calls `outcomeToken.registerMarket`, moves `initialLiquidity` from the caller straight to the clone, calls `Market.initialize` with `creator = msg.sender` and `specHash = keccak256(bytes(spec))`, emits `MarketCreated`. All in one transaction |
| `implementation()`, `outcomeToken()`, `collateral()`, `MIN_LIQUIDITY()`, `marketCount()`, `markets(id)` | view | any | See storage |
| `DEFAULT_ADMIN_ROLE()` | view, inherited | any | `bytes32(0)` |
| `hasRole(role, account)`, `getRoleAdmin(role)` | view, inherited | any | Role lookups. The website calls `hasRole(0x0, account)` to show admin pages |
| `grantRole(role, account)`, `revokeRole(role, account)` | admin of `role`, inherited | any | Adds or removes a role holder. Emits `RoleGranted` / `RoleRevoked` |
| `renounceRole(role, callerConfirmation)` | the holder, inherited | any | Drops the caller's own role |
| `supportsInterface(id)` | view, inherited | any | ERC-165 |

### Events

| Event | Emitted by | When |
|---|---|---|
| `MarketCreated(marketId indexed, market indexed, creator indexed, arbitrator, collateral, closeTime, specHash, spec, initialLiquidity)` | `createMarket` | Last step of a successful creation. This is the only place the full `spec` JSON is stored (in the log) |
| `RoleGranted`, `RoleRevoked`, `RoleAdminChanged` | inherited `AccessControl` | Role changes (`RoleGranted` also at construction) |

### Errors

| Error | Raised by | When |
|---|---|---|
| `InvalidConfig()` | constructor | `admin` or `collateral_` is zero |
| `InvalidCollateralDecimals(decimals)` | constructor | Collateral `decimals() != 6` |
| `ZeroArbitrator()` | `createMarket` | `p.arbitrator == address(0)` |
| `CloseTimeInPast(closeTime, currentTime)` | `createMarket` | `p.closeTime <= block.timestamp` |
| `UnsupportedInitialProbability(bps)` | `createMarket` | `p.initialYesProbabilityBps != 5000` |
| `LiquidityTooLow(initialLiquidity, minLiquidity)` | `createMarket` | `p.initialLiquidity < MIN_LIQUIDITY` |
| `EmptySpec()` | `createMarket` | `bytes(p.spec).length == 0` |
| `AccessControlUnauthorizedAccount(account, neededRole)` | inherited | Caller lacks the role |
| `AccessControlBadConfirmation()` | inherited | `renounceRole` for an address other than the caller |
| `FailedDeployment()`, `InsufficientBalance(balance, needed)` | inherited (`Clones`, OpenZeppelin `Errors`) | Clone deployment failed. Not expected in practice |
| `SafeERC20FailedOperation(token)` | inherited | Collateral transfer returned `false` |

The factory does not check that the arbitrator is a contract, or that it differs from the creator. Both
are documented risks in [threat-model.md](threat-model.md).

## 2. Market

One binary market. Holds its collateral, its AMM pool of YES and NO shares and its accrued fees.
Interface: `IMarket`. Inherits `Initializable`, `ERC1155Holder`, `ReentrancyGuardTransient`.
Pricing: [trading-engine.md](trading-engine.md).

### Storage and constants

| Name | Kind | Value or meaning |
|---|---|---|
| `FEE_BPS` | public constant | `100` (1%) |
| `BPS_DENOMINATOR` | internal constant | `10_000` |
| `RESOLUTION_WINDOW` | public constant | `7 days`. Time after `closeTime` for the arbitrator to resolve |
| `factory`, `outcomeToken`, `collateral` | public immutable | Set in the implementation's constructor. Clones run the implementation's code, so all clones share them |
| `marketId`, `creator`, `arbitrator`, `closeTime`, `specHash` | public storage | Set once in `initialize` |
| `yesPool`, `noPool` | public storage | AMM reserves (shares held by the market). Kept after `withdrawLiquidity` so the last price stays readable |
| `accruedFees` | public storage | Collateral fees owed to `creator`. Not part of share backing |
| `_state` | internal storage | Stored state: `Open` or `Resolved` |
| `winningOutcome` | public storage | Valid only when `state() == Resolved` |
| `liquidityWithdrawn` | public storage | `true` after `withdrawLiquidity` |

The implementation's constructor calls `_disableInitializers()`, so nobody can initialize the
implementation itself.

### State rule

`state()` returns `_state` if it is not `Open`. Otherwise it returns `Cancelled` if
`block.timestamp >= closeTime + RESOLUTION_WINDOW`, `Closed` if `block.timestamp >= closeTime`, and `Open`
before that. No transaction is needed to close or cancel a market. See the state diagram in
[architecture.md](architecture.md#4-market-state-machine).

### Functions

| Function | Who | When | Effect |
|---|---|---|---|
| `initialize(InitParams p)` | factory only, once (`initializer`) | During `createMarket` | Stores the params, sets `_state = Open`. Requires `collateral.balanceOf(this) >= initialLiquidity`. Sets `yesPool = noPool = initialLiquidity` and mints that many YES and NO to itself. Emits `Initialized(1)` |
| `buy(outcome, collateralIn, minSharesOut, deadline) returns (sharesOut)` | anyone, `nonReentrant` | `Open`, `deadline >= block.timestamp`. Caller approves `collateralIn` | Fee = `ceil(1%)` of `collateralIn`. Pulls `collateralIn`, mints `net = collateralIn - fee` YES and NO to the pool, sends `sharesOut` of `outcome` to the caller, adds `fee` to `accruedFees`. Emits `Bought` |
| `sell(outcome, sharesIn, minCollateralOut, deadline) returns (collateralOut)` | anyone, `nonReentrant` | `Open`, `deadline >= block.timestamp`. Caller sets `setApprovalForAll(market, true)` | Finds the largest gross release that keeps `yesPool * noPool` from falling (binary search). Takes `sharesIn`, burns `gross` YES and NO, pays `collateralOut = gross - fee`, adds `fee` to `accruedFees`. Emits `Sold` |
| `withdrawFees() returns (amount)` | anyone, `nonReentrant` | `state() != Open` | Sends all `accruedFees` to `creator` and zeroes them first. Emits `FeesWithdrawn` |
| `resolve(outcome)` | `arbitrator` only | `state() == Closed` | Sets `_state = Resolved` and `winningOutcome`. Emits `MarketResolved`. Not callable before close, at or after the deadline, or twice |
| `redeem() returns (payout)` | any holder, `nonReentrant` | `Resolved` or `Cancelled` | Burns all the caller's YES and NO of this market. `Resolved`: pays 1 unit per winning share. `Cancelled`: pays `(yes + no) / 2`, rounded down. Emits `Redeemed` |
| `withdrawLiquidity() returns (amount)` | anyone, `nonReentrant` | `Resolved` or `Cancelled`, once | Values the pool's own shares at the `redeem` rates, burns them, pays `creator`, sets `liquidityWithdrawn`. Emits `LiquidityWithdrawn` |
| `quoteBuy(outcome, collateralIn) returns (sharesOut, fee)` | view | `Open` | Same maths as `buy` |
| `quoteSell(outcome, sharesIn) returns (collateralOut, fee)` | view | `Open` | Same maths as `sell` |
| `priceYes()` / `priceNo()` | view | any | `noPool / (yesPool + noPool)` and `yesPool / (yesPool + noPool)`, 18 decimals |
| `resolutionDeadline()` | view | any | `closeTime + RESOLUTION_WINDOW` |
| `state()` | view | any | See state rule |
| `yesTokenId()` / `noTokenId()` | view | any | `OutcomeTokenId.compute(marketId, Yes / No)` |
| `factory()`, `outcomeToken()`, `collateral()`, `FEE_BPS()`, `RESOLUTION_WINDOW()`, `marketId()`, `creator()`, `arbitrator()`, `closeTime()`, `specHash()`, `yesPool()`, `noPool()`, `accruedFees()`, `winningOutcome()`, `liquidityWithdrawn()` | view | any | See storage |
| `onERC1155Received`, `onERC1155BatchReceived`, `supportsInterface` | inherited `ERC1155Holder` | On ERC-1155 transfers to the market | Accepts the tokens. Needed because the market holds its own pool shares |

### Events

| Event | Emitted by | Meaning |
|---|---|---|
| `Bought(trader indexed, outcome indexed, collateralIn, sharesOut, fee)` | `buy` | `collateralIn` includes `fee` |
| `Sold(trader indexed, outcome indexed, sharesIn, collateralOut, fee)` | `sell` | `collateralOut` is after the fee |
| `FeesWithdrawn(recipient indexed, amount)` | `withdrawFees` | `recipient` is always `creator` |
| `MarketResolved(outcome indexed)` | `resolve` | Final outcome |
| `Redeemed(holder indexed, payout)` | `redeem` | |
| `LiquidityWithdrawn(recipient indexed, amount)` | `withdrawLiquidity` | `recipient` is always `creator` |
| `Initialized(version)` | inherited `Initializable` | Once, in `initialize` |

### Errors

| Error | Raised by | When |
|---|---|---|
| `NotFactory(caller)` | `initialize` | Caller is not `factory` |
| `CollateralNotReceived(expected, actual)` | `initialize` | Clone holds less than `initialLiquidity` |
| `TradingClosed(currentState)` | `buy`, `sell`, `quoteBuy`, `quoteSell` | `state() != Open` |
| `DeadlineExpired(deadline, currentTime)` | `buy`, `sell` | `deadline < block.timestamp` |
| `InsufficientOutput(actual, minimum)` | `buy`, `sell` | Below the caller's minimum (slippage) |
| `ZeroAmount()` | `buy`, `sell`, quotes | `collateralIn` or `sharesIn` is 0 |
| `ZeroOutput()` | `buy`, `sell`, quotes | Net after fee, `sharesOut` or `collateralOut` is 0, or the opposite pool is 1 or less |
| `TradingStillOpen()` | `withdrawFees` | `state() == Open` |
| `NoFeesToWithdraw()` | `withdrawFees` | `accruedFees == 0` |
| `NotArbitrator(caller)` | `resolve` | Caller is not `arbitrator` |
| `CannotResolve(currentState)` | `resolve` | `state() != Closed` |
| `NotSettled(currentState)` | `redeem`, `withdrawLiquidity` | Not `Resolved` or `Cancelled` |
| `NothingToRedeem()` | `redeem` | Payout would be 0 |
| `LiquidityAlreadyWithdrawn()` | `withdrawLiquidity` | Second call |
| `InvalidInitialization()`, `NotInitializing()` | inherited `Initializable` | Second `initialize`, or `initialize` on the implementation |
| `ReentrancyGuardReentrantCall()` | inherited | Re-entry into a `nonReentrant` function |
| `SafeERC20FailedOperation(token)` | inherited | Collateral transfer returned `false` |

## 3. OutcomeToken

One ERC-1155 for every market. Each token id can be minted or burned only by the market it is
registered to. Interface: `IOutcomeToken`. Inherits `ERC1155Supply`. Details:
[market-creation-explained.md](market-creation-explained.md).

### Storage

| Name | Kind | Meaning |
|---|---|---|
| `factory` | public immutable | The only address that can call `registerMarket` |
| `marketOf(id)` | public mapping | Market that owns token `id`. `address(0)` if unregistered |
| URI | inherited | Set to `""` in the constructor. There is no metadata |

### Functions

| Function | Who | When | Effect |
|---|---|---|---|
| `registerMarket(marketId, market)` | factory only | During `createMarket` | Sets `marketOf` for both the YES and NO id. Emits `MarketRegistered` |
| `mint(to, id, amount)` | `marketOf[id]` only | any | Mints. Inherited `TransferSingle` event |
| `mintBatch(to, ids, amounts)` | market owning every id | any | Mints a batch. Each id is checked |
| `burn(from, id, amount)` | `marketOf[id]` only | any | Burns from `from` **without** an ERC-1155 approval check. Markets use it on their own pool and in `redeem` on the caller |
| `burnBatch(from, ids, amounts)` | market owning every id | any | Same, batched |
| `totalSupply(id)`, `totalSupply()` | view | any | Supply of one id. The inherited no-argument overload returns the total over all ids |
| `exists(id)` | view, inherited | any | `totalSupply(id) > 0` |
| `factory()`, `marketOf(id)` | view | any | See storage |
| `balanceOf`, `balanceOfBatch`, `isApprovedForAll`, `uri` | view, inherited | any | Standard ERC-1155 |
| `setApprovalForAll(operator, approved)` | holder, inherited | any | Needed before `Market.sell` and `OutcomeOrderBook.list` |
| `safeTransferFrom`, `safeBatchTransferFrom` | holder or approved operator, inherited | any | Shares move freely in every market state |
| `supportsInterface(id)` | view, inherited | any | ERC-165 |

### Events and errors

| Item | Kind | When |
|---|---|---|
| `MarketRegistered(marketId indexed, market indexed, yesTokenId, noTokenId)` | event | `registerMarket` |
| `TransferSingle`, `TransferBatch`, `ApprovalForAll`, `URI` | inherited events | Standard ERC-1155 |
| `NotFactory(caller)` | error | `registerMarket` from anyone but `factory` |
| `NotMarketForToken(caller, id)` | error | Mint or burn of an id the caller does not own |
| `MarketAlreadyRegistered(marketId)` | error | Same id registered twice (the YES id is checked; YES and NO are always set together) |
| `ERC1155InsufficientBalance`, `ERC1155InvalidApprover`, `ERC1155InvalidArrayLength`, `ERC1155InvalidOperator`, `ERC1155InvalidReceiver`, `ERC1155InvalidSender`, `ERC1155MissingApprovalForAll` | inherited errors | Standard ERC-1155 failures |

## 4. OptimisticResolver

Arbitrator for markets without a price feed. A bonded proposal stands unless disputed within the
challenge window. A dispute goes to the owner, who is the judge. A market uses it by naming it as
`arbitrator`; there is no per-market setup. Interface: `IOptimisticResolver`. Inherits `Ownable2Step`,
`ReentrancyGuardTransient`. Rules and operation: [optimistic-resolver.md](optimistic-resolver.md).

### Storage

| Name | Kind | Meaning |
|---|---|---|
| `factory` | public immutable | Only markets of this factory can be proposed on |
| `bondToken` | public immutable | `factory.collateral()`, read in the constructor |
| `bond` | public immutable | Bond per proposal and per dispute. Deployed value: `10000000` (10 mUSDC) |
| `challengeWindow` | public immutable | Seconds. Deployed value: `7200` (2 hours) |
| `_requests(market)` | internal mapping | One `Request` per market, read with `requestOf` |

Deployed values are the constructor arguments in `broadcast/DeployOptimisticResolver.s.sol/84532/run-latest.json`.

### Constructor

`constructor(address judge, IMarketFactory factory_, uint256 bond_, uint64 challengeWindow_)`. Reverts
`InvalidConfig` if `factory_` is zero, `bond_` or `challengeWindow_` is 0, or
`challengeWindow_ >= Market.RESOLUTION_WINDOW` (7 days). Reverts `OwnableInvalidOwner` if `judge` is zero.

### Request status

| From | Call | To | Bonds held after |
|---|---|---|---|
| `None` | `propose` | `Proposed` | 1 |
| `Proposed` | `dispute` (inside the window) | `Disputed` | 2 |
| `Proposed` | `finalize` (after the window) | `Settled` | 0 (proposer refunded) |
| `Disputed` | `rule` (judge) | `Settled` | 0 (winner gets `2 * bond`) |
| `Proposed` or `Disputed` | `refund` (market `Cancelled`) | `Settled` | 0 (each bond back to its owner) |

`Settled` is final. A market gets at most one request.

### Functions

| Function | Who | When | Effect |
|---|---|---|---|
| `propose(market, outcome, evidenceURI)` | anyone, `nonReentrant` | Market is a factory market with this resolver as arbitrator, `state() == Closed`, status `None`, and `block.timestamp + challengeWindow < resolutionDeadline()`. Caller approves `bond` | Stores the request (`proposedAt = now`), pulls `bond` from the caller. Emits `Proposed` |
| `dispute(market, evidenceURI)` | anyone, `nonReentrant` | Status `Proposed` and `block.timestamp < proposedAt + challengeWindow`. Caller approves `bond` | Sets `Disputed` and `disputer`, pulls `bond`. Emits `Disputed` |
| `finalize(market)` | anyone, `nonReentrant` | Status `Proposed` and `block.timestamp >= proposedAt + challengeWindow`. Market must still be `Closed` (else `Market.resolve` reverts `CannotResolve`) | Sets `Settled`, calls `market.resolve(outcome)`, returns the bond to the proposer. Emits `Finalized` |
| `rule(market, outcome)` | owner (judge), `nonReentrant` | Status `Disputed`. Market must still be `Closed` | Sets `Settled`, calls `market.resolve(outcome)`, pays `2 * bond` to the proposer if `outcome` matches the proposal, else to the disputer. Emits `Ruled` |
| `refund(market)` | anyone, `nonReentrant` | Status `Proposed` or `Disputed`, and `market.state() == Cancelled` | Sets `Settled`, returns the proposer's bond and, if disputed, the disputer's bond. Emits `Refunded` |
| `requestOf(market)` | view | any | The stored `Request` (all zero if none) |
| `factory()`, `bondToken()`, `bond()`, `challengeWindow()` | view | any | See storage |
| `owner()`, `pendingOwner()` | view, inherited | any | Judge, and the judge-elect during a two-step transfer |
| `transferOwnership(newOwner)` | owner, inherited | any | Starts a two-step transfer. Emits `OwnershipTransferStarted` |
| `acceptOwnership()` | pending owner, inherited | any | Completes the transfer. Emits `OwnershipTransferred` |
| `renounceOwnership()` | owner, inherited | any | Removes the judge. Disputed requests can then only end by `refund` after the market cancels |

### Events

| Event | Emitted by | Meaning |
|---|---|---|
| `Proposed(market indexed, proposer indexed, outcome, evidenceURI)` | `propose` | Evidence is only in the log, not stored |
| `Disputed(market indexed, disputer indexed, evidenceURI)` | `dispute` | |
| `Finalized(market indexed, outcome)` | `finalize` | |
| `Ruled(market indexed, outcome, winner indexed)` | `rule` | `winner` received `2 * bond` |
| `Refunded(market indexed)` | `refund` | |
| `OwnershipTransferStarted`, `OwnershipTransferred` | inherited | Judge changes |

### Errors

| Error | Raised by | When |
|---|---|---|
| `InvalidConfig()` | constructor | See constructor |
| `NotFactoryMarket(market)` | `propose` | `factory.markets(market.marketId()) != market` |
| `MarketNotUsingResolver(market)` | `propose` | `market.arbitrator() != this` |
| `MarketNotClosed(currentState)` | `propose` | Market not `Closed` |
| `ProposalTooLate(windowEnd, resolutionDeadline)` | `propose` | Window would end at or after the deadline |
| `WrongStatus(current)` | all five actions | Request is in the wrong status for that call |
| `ChallengeWindowClosed(windowEnd)` | `dispute` | Window over |
| `ChallengeWindowOpen(windowEnd)` | `finalize` | Window not over |
| `MarketNotCancelled(currentState)` | `refund` | Market not `Cancelled` |
| `OwnableUnauthorizedAccount(account)` | inherited | `rule` or owner functions from a non-owner |
| `OwnableInvalidOwner(owner)` | inherited | Zero judge at deploy |
| `ReentrancyGuardReentrantCall()`, `SafeERC20FailedOperation(token)` | inherited | Re-entry, or a bond transfer returned `false` |

Bonds are pushed to recipients. A recipient blocked by the token makes that call revert (noted as a
shortcut in the source).

## 5. ChainlinkResolver

Arbitrator for price markets. Settles each market on the Chainlink round that was live at its
`closeTime`, so the result does not depend on who calls or when. Interface: `IChainlinkResolver`.
Inherits `Ownable` (one step). Settlement rules: [chainlink-resolver.md](chainlink-resolver.md).

### Storage and constants

| Name | Kind | Meaning |
|---|---|---|
| `PHASE_OFFSET` | internal constant | `64`. Proxy round id = `phaseId << 64 \| aggregatorRoundId` |
| `_configs(market)` | internal mapping | One `Config` per market, read with `configOf`. Zero `feed` = not configured |

Constructor: `constructor(address owner_)`. Reverts `OwnableInvalidOwner` if `owner_` is zero.

### Functions

| Function | Who | When | Effect |
|---|---|---|---|
| `configure(market, config)` | owner | Once per market, `block.timestamp < market.closeTime()`, `market.arbitrator() == this` | Stores the config. Emits `MarketConfigured` |
| `resolve(market, roundId)` | anyone | Market configured. `Market.resolve` itself requires `Closed` | Reads `getRoundData(roundId)` and checks: round exists, `updatedAt <= closeTime`, `closeTime - updatedAt <= maxStaleness`, `answer > 0`, and, unless it is the latest round, the next round (same phase `roundId + 1`, else round 1 of the next phase) was updated after `closeTime`. Emits `PriceResolved`, then calls `market.resolve(outcome)` |
| `configOf(market)` | view | any | The stored `Config` |
| `owner()` | view, inherited | any | |
| `transferOwnership(newOwner)`, `renounceOwnership()` | owner, inherited | any | One-step transfer. Emits `OwnershipTransferred` |

### Events and errors

| Item | Kind | When |
|---|---|---|
| `MarketConfigured(market indexed, feed indexed, threshold, comparison, maxStaleness)` | event | `configure` |
| `PriceResolved(market indexed, roundId, price, outcome)` | event | `resolve`, just before `market.resolve` |
| `OwnershipTransferred` | inherited event | Owner changes |
| `InvalidConfig()` | error | `configure` with zero `feed` or zero `maxStaleness` |
| `MarketNotUsingResolver(market)` | error | `configure` on a market whose arbitrator is not this contract |
| `AlreadyConfigured(market)` | error | Second `configure` |
| `ConfigureAfterClose(market)` | error | `configure` at or after `closeTime` |
| `NotConfigured(market)` | error | `resolve` on an unconfigured market |
| `RoundNotFound(roundId)` | error | `updatedAt == 0` |
| `RoundAfterClose(roundId, updatedAt)` | error | Round updated after `closeTime` |
| `RoundSuperseded(roundId, nextUpdatedAt)` | error | A later round was also updated at or before `closeTime` |
| `StalePrice(updatedAt, closeTime)` | error | Round older than `maxStaleness` at close |
| `InvalidPrice(answer)` | error | `answer <= 0` |
| `OwnableUnauthorizedAccount`, `OwnableInvalidOwner` | inherited errors | Non-owner call, zero owner |

`configure` does not check that the market came from the Sooth factory. Only the owner can call it, and
`resolve` only works on configured markets. There is no L2 sequencer uptime check (shortcut in the source,
Base Sepolia has no uptime feed).

## 6. OutcomeOrderBook

Fixed-price listings of YES or NO shares for every market of one factory (Bonus 1). Sellers escrow shares;
buyers fill from the cheapest listing first, oldest first at equal price, and pay each seller directly.
No owner, no fee, no mint or burn. Interface: `IOutcomeOrderBook`. Inherits `ERC1155Holder`,
`ReentrancyGuardTransient`. Usage and examples: [order-book.md](order-book.md).

**Deployed** on Base Sepolia at `0x539a5842371cEeA853A5Adab48bAFc2a5d9B2b05` (tx `0x66f0f8f79de12a3c12b14bf37d8e11e9d61aa839bee686db7b488ef54ca634e1`, block 55252775). The website's
order-book panel uses `ORDER_BOOK` in `web/src/contracts.ts`; the zero address hides it.

### Storage and constants

| Name | Kind | Meaning |
|---|---|---|
| `PRICE_SCALE` | public constant | `1e6`. A price of `1e6` means 1 USDC per whole share |
| `factory` | public immutable | Markets must belong to it |
| `outcomeToken` | public immutable | `factory.outcomeToken()`, read in the constructor |
| `listingCount` | public storage | Last listing id. Ids start at 1 |
| `_listings(id)` | internal mapping | `Listing` by id, read with `getListing` |
| `_books(market, outcome)` | internal mapping | `Book` (head, tail) of a doubly linked list sorted by price ascending, FIFO at equal price |

Constructor: `constructor(IMarketFactory factory_)`. No zero check.

### Functions

| Function | Who | When | Effect |
|---|---|---|---|
| `list(market, outcome, amount, price) returns (listingId)` | holder, `nonReentrant` | Factory market, `Open`. Caller sets `setApprovalForAll(orderBook, true)` | Creates listing `++listingCount`, inserts it after the last listing priced `<= price`, emits `Listed`, then pulls `amount` shares into escrow |
| `buy(market, outcome, shares, maxPrice, maxListings) returns (sharesBought, cost)` | anyone, `nonReentrant` | Factory market, `Open`. Caller approves collateral | Walks from the head while shares are wanted, `price <= maxPrice` and fewer than `maxListings` listings were touched. Per listing: fill `min(remaining, wanted)`, cost `ceil(fill * price / PRICE_SCALE)`, update and unlink if empty, emit `Filled`, pull the cost from the buyer straight to the seller. Then sends all `sharesBought` to the buyer in one transfer |
| `cancel(listingId) returns (returned)` | seller, `nonReentrant` | Any market state | Sets `remaining = 0`, unlinks, emits `Cancelled`, returns the remaining shares |
| `quoteBuy(market, outcome, shares, maxPrice, maxListings) returns (sharesBought, cost)` | view | Same checks as `buy` | Same walk as `buy`. Returns `(0, 0)` where `buy` would revert `NothingFilled` |
| `bestPrice(market, outcome)` | view | any | Head price, or 0 if empty |
| `listingsOf(market, outcome, startAfter, count) returns (ids)` | view | any | Up to `count` ids in fill order after `startAfter` (0 = from the head) |
| `getListing(listingId)` | view | any | The stored `Listing`. `remaining == 0` means filled or cancelled, and then `prev == next == 0` |
| `PRICE_SCALE()`, `factory()`, `outcomeToken()`, `listingCount()` | view | any | See storage |
| `onERC1155Received`, `onERC1155BatchReceived`, `supportsInterface` | inherited `ERC1155Holder` | On share transfers in | Lets the book hold escrowed shares |

### Events and errors

| Item | Kind | When |
|---|---|---|
| `Listed(listingId indexed, market indexed, seller indexed, outcome, amount, price)` | event | `list` |
| `Filled(listingId indexed, market indexed, buyer indexed, seller, outcome, shares, cost)` | event | Each listing touched by `buy` |
| `Cancelled(listingId indexed, market indexed, seller indexed, returned)` | event | `cancel` |
| `NotFactoryMarket(market)` | error | `list`, `buy`, `quoteBuy`: `factory.markets(market.marketId()) != market` |
| `MarketNotOpen(currentState)` | error | `list`, `buy`, `quoteBuy`: market not `Open` |
| `ZeroAmount()` | error | `amount`, `shares` or `maxListings` is 0 |
| `InvalidPrice(price)` | error | `price == 0` or `price >= PRICE_SCALE` |
| `NotSeller(caller)` | error | `cancel` by someone else |
| `ListingNotFound(listingId)` | error | `cancel` of an unknown, filled or cancelled id; `listingsOf` with a `startAfter` that is not an open listing of that book |
| `NothingFilled()` | error | `buy` matched nothing |
| `ReentrancyGuardReentrantCall()`, `SafeERC20FailedOperation(token)` | inherited errors | Re-entry, or a collateral transfer returned `false` |

Sellers are paid inside the fill. A seller blocked by the collateral token makes fills against their
listing revert until they cancel it (shortcut in the source).

## 7. Libraries and external interfaces

| Item | File | Spec |
|---|---|---|
| `OutcomeTokenId.compute(marketId, outcome)` | `src/libraries/OutcomeTokenId.sol` | `uint256(keccak256(abi.encode(marketId, outcome)))`. Internal pure, inlined into `Market` and `OutcomeToken`. `web/src/chain.ts` uses the same formula |
| `AggregatorV3Interface` | `src/interfaces/AggregatorV3Interface.sol` | Minimal copy of Chainlink's interface: `decimals()`, `description()`, `version()`, `getRoundData(roundId)`, `latestRoundData()`. The resolver uses only the last two |

## 8. Mocks (test only)

| Contract | Functions | Notes |
|---|---|---|
| `MockUSDC` (`mUSDC`) | ERC-20 (`name`, `symbol`, `decimals` = 6, `totalSupply`, `balanceOf`, `transfer`, `transferFrom`, `approve`, `allowance`) plus `mint(to, amount)` with **no access control**. Inherited events `Transfer`, `Approval` and errors `ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, `ERC20InvalidSender`, `ERC20InvalidReceiver`, `ERC20InvalidApprover`, `ERC20InvalidSpender` | Collateral on Base Sepolia. `DeployMarketFactory.s.sol` refuses to deploy it outside chains 31337, 84532, 11155111, 421614. Never use on mainnet |
| `MockAggregator` | `setRound(roundId, answer, updatedAt)` (no access control), `latestRoundId`, `decimals` = 8, `description` = "ETH / USD", `version` = 4, `getRoundData`, `latestRoundData` | Unset rounds return zeros, like OCR aggregators. The highest id set is the latest |

## 9. Access control

| Role | Held by (Base Sepolia, at deploy) | Can do |
|---|---|---|
| Factory `DEFAULT_ADMIN_ROLE` | The deployer wallet (`ADMIN` argument). Later role changes were not checked on chain | `createMarket`, grant and revoke roles |
| `Market.factory` | `MarketFactory` | `Market.initialize` |
| `OutcomeToken.factory` | `MarketFactory` | `registerMarket` |
| `OutcomeToken.marketOf[id]` | The market for that id | `mint`, `mintBatch`, `burn`, `burnBatch` of its ids |
| `Market.arbitrator` | Set per market at creation: `OptimisticResolver`, `ChainlinkResolver`, or any address (EOA or contract) | `Market.resolve` while `Closed` |
| `OptimisticResolver` owner (judge) | The deployer wallet (constructor argument) | `rule`, ownership functions |
| `ChainlinkResolver` owner | The deployer wallet (constructor argument) | `configure`, ownership functions |
| Order book seller | Listing creator | `cancel` of their listing |
| Anyone | | Trade, redeem, trigger `withdrawFees` / `withdrawLiquidity` (paid to `creator`), `propose`, `dispute`, `finalize`, `refund`, `ChainlinkResolver.resolve`, `list`, `buy` |

No contract is upgradeable. There is no pause function and no way for an admin to move a market's
collateral.

## 10. What works in which market state

| Action | `Open` | `Closed` | `Resolved` | `Cancelled` |
|---|---|---|---|---|
| `Market.buy`, `sell`, `quoteBuy`, `quoteSell` | yes | no | no | no |
| `Market.withdrawFees` | no | yes | yes | yes |
| `Market.resolve` (arbitrator) | no | yes | no | no |
| `Market.redeem`, `withdrawLiquidity` | no | no | yes | yes |
| `OptimisticResolver.propose` | no | yes, if the window ends before the deadline | no | no |
| `OptimisticResolver.dispute` | no (no request can exist) | yes, inside the challenge window | no | no (the window always ends before the deadline) |
| `OptimisticResolver.finalize`, `rule` | no (no request can exist) | yes | no (`CannotResolve`) | no (`CannotResolve`) |
| `OptimisticResolver.refund` | no | no | no | yes |
| `ChainlinkResolver.configure` | yes, before `closeTime` | no | no | no |
| `ChainlinkResolver.resolve` | no (`CannotResolve`) | yes | no | no |
| `OutcomeOrderBook.list`, `buy`, `quoteBuy` | yes | no | no | no |
| `OutcomeOrderBook.cancel` | yes | yes | yes | yes |
| Outcome share transfers | yes | yes | yes | yes |

## 11. Deploy and operation scripts

All in `contracts/script/`. Each reads env vars and broadcasts with the wallet passed to `forge script`.

| Script | Does | Env vars |
|---|---|---|
| `DeployMarketFactory.s.sol` | Deploys `MarketFactory` (and `MockUSDC` if `COLLATERAL` is unset, test chains only) | `COLLATERAL`, `ADMIN` |
| `DeployOptimisticResolver.s.sol` | Deploys `OptimisticResolver` | `FACTORY`, `ADMIN` (judge), `BOND` (default `10e6`), `CHALLENGE_WINDOW` (default 7200 s) |
| `DeployChainlinkResolver.s.sol` | Deploys `ChainlinkResolver` | `ADMIN` |
| `DeployOrderBook.s.sol` | Deploys `OutcomeOrderBook` | `FACTORY` |
| `CreateMarket.s.sol` | Approves the seed, calls `createMarket`, and for price markets calls `ChainlinkResolver.configure` in the same broadcast | `FACTORY`, `SPEC`, `CLOSE_TIME`, `LIQUIDITY` (default `100e6`), `ARBITRATOR`; price markets: `FEED`, `RESOLVER`, `THRESHOLD`, `COMPARISON` (`below` / `above`), `MAX_STALENESS` (default 3600 s) |
| `ResolveChainlinkMarket.s.sol` | Binary-searches the round live at close (current phase only) and calls `ChainlinkResolver.resolve` | `RESOLVER`, `MARKET`, `ROUND_ID` (optional) |

## Notes and known gaps

- `IMarket.State.Proposed` exists in the enum but `Market` never stores or returns it. Proposal status lives
  in `OptimisticResolver.Status`. The website and bot mirror the enum and treat it as unused.
- `OutcomeToken.burn` and `burnBatch` skip ERC-1155 approval. Only the market that owns the id can call them,
  so a market can burn its own shares from any holder. `Market` does this only in `redeem` (on the caller) and
  on its own pool.
- `Market`, `OptimisticResolver` and `OutcomeOrderBook` push payments (fees, payouts, bonds, seller proceeds). A recipient
  blocked by the collateral token blocks that one call.
- `withdrawFees` and `withdrawLiquidity` can be triggered by anyone, but always pay `creator`.
- `Market.resolve` has no reentrancy guard. It makes no external calls.
- Invariant IDs for these rules are in [invariants.md](invariants.md).
