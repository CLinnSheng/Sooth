# Contract specification

The single reference table of every Sooth contract: functions, events, errors, constants, access rules
and state rules. It says *what* each item does. For *why*, maths and examples, see the component docs:

- [architecture.md](architecture.md): system overview, diagrams and deployed addresses
- [market-creation-explained.md](market-creation-explained.md): factory, clones and outcome tokens
- [trading-engine.md](trading-engine.md): AMM pricing and fees
- [market-settlement.md](market-settlement.md): lifecycle, redemption and withdrawals
- [optimistic-resolver.md](optimistic-resolver.md), [chainlink-resolver.md](chainlink-resolver.md): resolution
- [order-book.md](order-book.md): Bonus 1 order book
- [invariants.md](invariants.md), [threat-model.md](threat-model.md), [testing.md](testing.md#security-analysis): properties, risks, Slither and coverage

## Conventions

- **Units.** Amounts are raw collateral units (6 decimals, `1e6` = 1 USDC). One whole share is also `1e6`.
- **Prices.** `Market.priceYes` / `priceNo` use 18 decimals (`1e18` = 100%). Order-book prices use
  `PRICE_SCALE` (`1e6` = 1 USDC per whole share).
- **Enums** are `uint8` in the ABI. `Outcome`: 0 = `Yes`, 1 = `No`.
- **"Inherited"** means the item comes from OpenZeppelin, not Sooth code.
- Solidity `^0.8.24`, built with `0.8.28` (`contracts/foundry.toml`).

## Contracts at a glance

| Contract | File | Kind | How many | Admin |
|---|---|---|---|---|
| `MarketFactory` | `src/MarketFactory.sol` | Entry point, creates markets | 1 | `DEFAULT_ADMIN_ROLE` |
| `OutcomeToken` | `src/OutcomeToken.sol` | ERC-1155 for every market's shares | 1, deployed by the factory | none |
| `Market` | `src/Market.sol` | One binary market (AMM, resolution, payout) | 1 implementation + 1 EIP-1167 clone per market | none |
| `OptimisticResolver` | `src/OptimisticResolver.sol` | Arbitrator: bonded proposal, dispute, judge | 1 | owner = judge (`Ownable2Step`) |
| `ChainlinkResolver` | `src/ChainlinkResolver.sol` | Arbitrator: price feed | 1 | owner (`Ownable`) |
| `OutcomeOrderBook` | `src/OutcomeOrderBook.sol` | Fixed-price share listings (Bonus 1) | 1 | none |
| `OutcomeTokenId` | `src/libraries/OutcomeTokenId.sol` | Library: token id formula | inlined | n/a |
| `MockUSDC` | `src/mocks/MockUSDC.sol` | Test collateral, anyone can mint | test chains only | none |
| `MockAggregator` | `src/mocks/MockAggregator.sol` | Test Chainlink feed | tests only | none |

Base Sepolia addresses: [architecture.md §11](architecture.md#11-deployment).

## Shared types

Defined in `src/interfaces/`.

| Type | Fields or values |
|---|---|
| `IMarket.State` | `Open` (0), `Closed` (1), `Proposed` (2), `Resolved` (3), `Cancelled` (4). Only `Open` and `Resolved` are stored; `Closed` and `Cancelled` are derived from the clock. `Proposed` is never returned by `Market` |
| `IMarket.Outcome` | `Yes` (0), `No` (1) |
| `IMarket.InitParams` | `marketId`, `creator`, `arbitrator`, `closeTime` (`uint64`), `specHash` (`bytes32`), `initialLiquidity` |
| `IMarketFactory.CreateParams` | `arbitrator`, `closeTime` (`uint64`), `initialYesProbabilityBps` (`uint16`, must be 5000), `spec` (string), `initialLiquidity` |
| `IOptimisticResolver.Status` | `None` (0), `Proposed` (1), `Disputed` (2), `Settled` (3) |
| `IOptimisticResolver.Request` | `proposer`, `outcome`, `status`, `proposedAt` (`uint64`), `disputer` |
| `IChainlinkResolver.Comparison` | `Below` (0): YES if price < threshold. `Above` (1): YES if price > threshold. A tie is NO |
| `IChainlinkResolver.Config` | `feed` (`AggregatorV3Interface`), `threshold` (`int256`, feed decimals), `comparison`, `maxStaleness` (`uint64` seconds) |
| `IOutcomeOrderBook.Listing` | `seller`, `market`, `outcome`, `price`, `remaining`, `prev`, `next` |
| `OutcomeOrderBook.Book` (internal) | `head`, `tail` of one (market, outcome) list. 0 = empty |

## 1. MarketFactory

Interface `IMarketFactory`. Inherits `AccessControl`. Details: [market-creation-explained.md](market-creation-explained.md).

| Name | Kind | Value or meaning |
|---|---|---|
| `MIN_LIQUIDITY` | public constant | `10e6` (10 USDC). Smallest seed |
| `FIFTY_FIFTY_BPS` | internal constant | `5_000`. The only accepted `initialYesProbabilityBps` |
| `implementation`, `outcomeToken` | public immutable | Deployed in the constructor |
| `collateral` | public immutable | Fixed at deploy |
| `marketCount` | public storage | Number of markets. Ids start at 1 |
| `markets(marketId)` | public mapping | Clone address by id. `address(0)` for unknown ids |

`constructor(address admin, address collateral_)` deploys `OutcomeToken(address(this))` and the `Market`
implementation, then grants `DEFAULT_ADMIN_ROLE` to `admin`.

| Function | Who | When | Effect |
|---|---|---|---|
| `createMarket(CreateParams p) returns (marketId, market)` | `DEFAULT_ADMIN_ROLE` | Caller approved `initialLiquidity` | Validates `p`, `marketId = ++marketCount`, clones and records the market, `registerMarket`, moves the seed to the clone, `initialize` with `creator = msg.sender` and `specHash = keccak256(bytes(spec))`, emits `MarketCreated` |
| `implementation()`, `outcomeToken()`, `collateral()`, `MIN_LIQUIDITY()`, `marketCount()`, `markets(id)` | view | any | See above |
| `DEFAULT_ADMIN_ROLE()`, `hasRole`, `getRoleAdmin`, `supportsInterface` | view, inherited | any | `DEFAULT_ADMIN_ROLE` is `bytes32(0)`; the website calls `hasRole(0x0, account)` |
| `grantRole`, `revokeRole` | role admin, inherited | any | Emits `RoleGranted` / `RoleRevoked` |
| `renounceRole(role, callerConfirmation)` | holder, inherited | any | Drops the caller's own role |

| Event or error | Kind | When |
|---|---|---|
| `MarketCreated(marketId indexed, market indexed, creator indexed, arbitrator, collateral, closeTime, specHash, spec, initialLiquidity)` | event | End of `createMarket`. The only place the full `spec` is kept |
| `RoleGranted`, `RoleRevoked`, `RoleAdminChanged` | inherited events | Role changes |
| `InvalidConfig()` | error | Constructor: `admin` or `collateral_` is zero |
| `InvalidCollateralDecimals(decimals)` | error | Constructor: collateral `decimals() != 6` |
| `ZeroArbitrator()` | error | `p.arbitrator == address(0)` |
| `CloseTimeInPast(closeTime, currentTime)` | error | `p.closeTime <= block.timestamp` |
| `UnsupportedInitialProbability(bps)` | error | `p.initialYesProbabilityBps != 5000` |
| `LiquidityTooLow(initialLiquidity, minLiquidity)` | error | `p.initialLiquidity < MIN_LIQUIDITY` |
| `EmptySpec()` | error | `bytes(p.spec).length == 0` |
| `AccessControlUnauthorizedAccount`, `AccessControlBadConfirmation` | inherited errors | Missing role; `renounceRole` for another address |
| `FailedDeployment()`, `InsufficientBalance(balance, needed)`, `SafeERC20FailedOperation(token)` | inherited errors | Clone deploy failed (not expected); collateral transfer returned `false` |

The factory does not check that the arbitrator is a contract or differs from the creator
([threat-model.md](threat-model.md)).

## 2. Market

Interface `IMarket`. Inherits `Initializable`, `ERC1155Holder`, `ReentrancyGuardTransient`. Pricing:
[trading-engine.md](trading-engine.md). Payouts: [market-settlement.md](market-settlement.md).

| Name | Kind | Value or meaning |
|---|---|---|
| `FEE_BPS` | public constant | `100` (1%) |
| `BPS_DENOMINATOR` | internal constant | `10_000` |
| `RESOLUTION_WINDOW` | public constant | `7 days` after `closeTime` |
| `factory`, `outcomeToken`, `collateral` | public immutable | Set in the implementation's constructor; shared by all clones |
| `marketId`, `creator`, `arbitrator`, `closeTime`, `specHash` | public storage | Set once in `initialize` |
| `yesPool`, `noPool` | public storage | AMM reserves. Kept after `withdrawLiquidity` so the last price stays readable |
| `accruedFees` | public storage | Fees owed to `creator`. Not share backing |
| `_state` | internal storage | `Open` or `Resolved` |
| `winningOutcome` | public storage | Valid only when `Resolved` |
| `liquidityWithdrawn` | public storage | `true` after `withdrawLiquidity` |

The implementation's constructor calls `_disableInitializers()`. **State rule:** `state()` returns
`_state` unless it is `Open`; then `Cancelled` if `block.timestamp >= closeTime + RESOLUTION_WINDOW`,
`Closed` if `block.timestamp >= closeTime`, else `Open`.

| Function | Who | When | Effect |
|---|---|---|---|
| `initialize(InitParams p)` | factory, once | During `createMarket` | Requires `collateral.balanceOf(this) >= initialLiquidity`. Sets `yesPool = noPool = initialLiquidity` and mints that many YES and NO to itself |
| `buy(outcome, collateralIn, minSharesOut, deadline) returns (sharesOut)` | anyone, `nonReentrant` | `Open`, `deadline >= now`, collateral approved | Fee `ceil(1%)`; mints `collateralIn - fee` pairs, sends `sharesOut`, adds fee to `accruedFees`. Emits `Bought` |
| `sell(outcome, sharesIn, minCollateralOut, deadline) returns (collateralOut)` | anyone, `nonReentrant` | `Open`, `deadline >= now`, `setApprovalForAll` | Takes `sharesIn`, burns `gross` pairs (binary search), pays `gross - fee`. Emits `Sold` |
| `withdrawFees() returns (amount)` | anyone, `nonReentrant` | Not `Open` | Pays all `accruedFees` to `creator`. Emits `FeesWithdrawn` |
| `resolve(outcome)` | `arbitrator` | `Closed` | Sets `Resolved` and `winningOutcome`. Emits `MarketResolved` |
| `redeem() returns (payout)` | holder, `nonReentrant` | `Resolved` or `Cancelled` | Burns all the caller's YES and NO. Pays 1 per winning share, or `(yes + no) / 2` rounded down if `Cancelled`. Emits `Redeemed` |
| `withdrawLiquidity() returns (amount)` | anyone, `nonReentrant` | `Resolved` or `Cancelled`, once | Burns the pool's shares at `redeem` rates, pays `creator`. Emits `LiquidityWithdrawn` |
| `quoteBuy(outcome, collateralIn) returns (sharesOut, fee)`, `quoteSell(outcome, sharesIn) returns (collateralOut, fee)` | view | `Open` | Same maths as `buy` / `sell` |
| `priceYes()`, `priceNo()` | view | any | `noPool / (yesPool + noPool)` and the mirror, 18 decimals |
| `resolutionDeadline()` | view | any | `closeTime + RESOLUTION_WINDOW` |
| `state()` | view | any | See state rule |
| `yesTokenId()`, `noTokenId()` | view | any | `OutcomeTokenId.compute(marketId, Yes / No)` |
| Getters for every public item above | view | any | |
| `onERC1155Received`, `onERC1155BatchReceived`, `supportsInterface` | inherited `ERC1155Holder` | Transfers in | Lets the market hold its pool shares |

| Event or error | Kind | When |
|---|---|---|
| `Bought(trader indexed, outcome indexed, collateralIn, sharesOut, fee)` | event | `buy`; `collateralIn` includes `fee` |
| `Sold(trader indexed, outcome indexed, sharesIn, collateralOut, fee)` | event | `sell`; `collateralOut` is after the fee |
| `FeesWithdrawn(recipient indexed, amount)`, `LiquidityWithdrawn(recipient indexed, amount)` | event | Withdrawals; `recipient` is always `creator` |
| `MarketResolved(outcome indexed)` | event | `resolve` |
| `Redeemed(holder indexed, payout)` | event | `redeem` |
| `Initialized(version)` | inherited event | Once, in `initialize` |
| `NotFactory(caller)` | error | `initialize` not from `factory` |
| `CollateralNotReceived(expected, actual)` | error | Clone holds less than `initialLiquidity` |
| `TradingClosed(currentState)` | error | Trade or quote when not `Open` |
| `DeadlineExpired(deadline, currentTime)` | error | `deadline < block.timestamp` |
| `InsufficientOutput(actual, minimum)` | error | Slippage limit |
| `ZeroAmount()` | error | `collateralIn` or `sharesIn` is 0 |
| `ZeroOutput()` | error | Net amount, `sharesOut` or `collateralOut` is 0, or the opposite pool is 1 or less |
| `TradingStillOpen()`, `NoFeesToWithdraw()` | error | `withdrawFees` while `Open`, or with nothing accrued |
| `NotArbitrator(caller)`, `CannotResolve(currentState)` | error | `resolve` by someone else, or not `Closed` |
| `NotSettled(currentState)` | error | `redeem` / `withdrawLiquidity` before settlement |
| `NothingToRedeem()` | error | Payout would be 0 |
| `LiquidityAlreadyWithdrawn()` | error | Second `withdrawLiquidity` |
| `InvalidInitialization()`, `NotInitializing()`, `ReentrancyGuardReentrantCall()`, `SafeERC20FailedOperation(token)` | inherited errors | Second `initialize`; re-entry; failed collateral transfer |

## 3. OutcomeToken

Interface `IOutcomeToken`. Inherits `ERC1155Supply`. URI is `""` (no metadata).

| Function | Who | Effect |
|---|---|---|
| `registerMarket(marketId, market)` | `factory` | Sets `marketOf` for the YES and NO ids. Emits `MarketRegistered` |
| `mint(to, id, amount)`, `mintBatch(to, ids, amounts)` | `marketOf[id]` for every id | Mints |
| `burn(from, id, amount)`, `burnBatch(from, ids, amounts)` | `marketOf[id]` for every id | Burns **without** an ERC-1155 approval check |
| `totalSupply(id)`, `totalSupply()`, `exists(id)` | view | Supply per id, over all ids (inherited), `> 0` |
| `factory()`, `marketOf(id)` | view | Immutable factory; owning market per id (`address(0)` if none) |
| `balanceOf`, `balanceOfBatch`, `isApprovedForAll`, `uri`, `supportsInterface` | view, inherited | Standard ERC-1155 |
| `setApprovalForAll(operator, approved)` | holder, inherited | Needed before `Market.sell` and `OutcomeOrderBook.list` |
| `safeTransferFrom`, `safeBatchTransferFrom` | holder or operator, inherited | Shares move freely in every market state |

| Event or error | Kind | When |
|---|---|---|
| `MarketRegistered(marketId indexed, market indexed, yesTokenId, noTokenId)` | event | `registerMarket` |
| `TransferSingle`, `TransferBatch`, `ApprovalForAll`, `URI` | inherited events | Standard ERC-1155 |
| `NotFactory(caller)` | error | `registerMarket` not from `factory` |
| `NotMarketForToken(caller, id)` | error | Mint or burn of an id the caller does not own |
| `MarketAlreadyRegistered(marketId)` | error | Same id registered twice |
| `ERC1155InsufficientBalance`, `ERC1155InvalidApprover`, `ERC1155InvalidArrayLength`, `ERC1155InvalidOperator`, `ERC1155InvalidReceiver`, `ERC1155InvalidSender`, `ERC1155MissingApprovalForAll` | inherited errors | Standard ERC-1155 failures |

## 4. OptimisticResolver

Interface `IOptimisticResolver`. Inherits `Ownable2Step`, `ReentrancyGuardTransient`. A market uses it
by naming it as `arbitrator`. Rules and bond paths: [optimistic-resolver.md](optimistic-resolver.md).

| Name | Kind | Meaning |
|---|---|---|
| `factory` | public immutable | Only its markets can be proposed on |
| `bondToken` | public immutable | `factory.collateral()` |
| `bond` | public immutable | Per proposal and per dispute. Deployed: `10000000` (10 mUSDC) |
| `challengeWindow` | public immutable | Seconds. Deployed: `7200` (2 hours) |
| `_requests(market)` | internal mapping | One `Request` per market |

`constructor(address judge, IMarketFactory factory_, uint256 bond_, uint64 challengeWindow_)`. Deployed
values are in `broadcast/DeployOptimisticResolver.s.sol/84532/run-latest.json`.

| From | Call | To | Bonds held after |
|---|---|---|---|
| `None` | `propose` | `Proposed` | 1 |
| `Proposed` | `dispute` (inside the window) | `Disputed` | 2 |
| `Proposed` | `finalize` (after the window) | `Settled` | 0 (proposer refunded) |
| `Disputed` | `rule` (judge) | `Settled` | 0 (winner gets `2 * bond`) |
| `Proposed` or `Disputed` | `refund` (market `Cancelled`) | `Settled` | 0 (each bond back) |

| Function | Who | When | Effect |
|---|---|---|---|
| `propose(market, outcome, evidenceURI)` | anyone, `nonReentrant` | Factory market using this resolver, `Closed`, status `None`, `now + challengeWindow < resolutionDeadline()` | Stores the request, pulls `bond`. Emits `Proposed` |
| `dispute(market, evidenceURI)` | anyone, `nonReentrant` | `Proposed`, `now < proposedAt + challengeWindow` | Sets `Disputed`, pulls `bond`. Emits `Disputed` |
| `finalize(market)` | anyone, `nonReentrant` | `Proposed`, `now >= proposedAt + challengeWindow`, market still `Closed` | Resolves the market, returns the bond. Emits `Finalized` |
| `rule(market, outcome)` | owner (judge), `nonReentrant` | `Disputed`, market still `Closed` | Resolves the market, pays `2 * bond` to whichever side matches `outcome`. Emits `Ruled` |
| `refund(market)` | anyone, `nonReentrant` | `Proposed` or `Disputed`, market `Cancelled` | Returns each bond. Emits `Refunded` |
| `requestOf(market)` | view | any | Stored `Request` (zero if none) |
| `factory()`, `bondToken()`, `bond()`, `challengeWindow()`, `owner()`, `pendingOwner()` | view | any | |
| `transferOwnership`, `acceptOwnership`, `renounceOwnership` | owner / pending owner, inherited | any | Two-step judge transfer. After `renounceOwnership`, disputed requests can only end by `refund` |

| Event or error | Kind | When |
|---|---|---|
| `Proposed(market indexed, proposer indexed, outcome, evidenceURI)` | event | `propose`; evidence is only in the log |
| `Disputed(market indexed, disputer indexed, evidenceURI)` | event | `dispute` |
| `Finalized(market indexed, outcome)` | event | `finalize` |
| `Ruled(market indexed, outcome, winner indexed)` | event | `rule` |
| `Refunded(market indexed)` | event | `refund` |
| `OwnershipTransferStarted`, `OwnershipTransferred` | inherited events | Judge changes |
| `InvalidConfig()` | error | Constructor: zero `factory_`, zero `bond_` or `challengeWindow_`, or `challengeWindow_ >= 7 days` |
| `NotFactoryMarket(market)` | error | `propose`: `factory.markets(market.marketId()) != market` |
| `MarketNotUsingResolver(market)` | error | `propose`: arbitrator is not this contract |
| `MarketNotClosed(currentState)` | error | `propose` when not `Closed` |
| `ProposalTooLate(windowEnd, resolutionDeadline)` | error | Window would end at or after the deadline |
| `WrongStatus(current)` | error | Any action in the wrong status |
| `ChallengeWindowClosed(windowEnd)`, `ChallengeWindowOpen(windowEnd)` | error | Late `dispute`; early `finalize` |
| `MarketNotCancelled(currentState)` | error | `refund` when not `Cancelled` |
| `OwnableUnauthorizedAccount`, `OwnableInvalidOwner`, `ReentrancyGuardReentrantCall`, `SafeERC20FailedOperation` | inherited errors | Non-judge call; zero judge; re-entry; failed bond transfer |

## 5. ChainlinkResolver

Interface `IChainlinkResolver`. Inherits `Ownable` (one step). Round checks and configuration:
[chainlink-resolver.md](chainlink-resolver.md).

| Name | Kind | Meaning |
|---|---|---|
| `PHASE_OFFSET` | internal constant | `64`. Proxy round id = `phaseId << 64 \| aggregatorRoundId` |
| `_configs(market)` | internal mapping | One `Config` per market. Zero `feed` = not configured |

`constructor(address owner_)`.

| Function | Who | When | Effect |
|---|---|---|---|
| `configure(market, config)` | owner | Once, before `closeTime`, market's arbitrator is this contract | Stores the config. Emits `MarketConfigured` |
| `resolve(market, roundId)` | anyone | Configured; `Market.resolve` requires `Closed` | Checks the round was the one live at `closeTime` (exists, not after close, not superseded, within `maxStaleness`, `answer > 0`). Emits `PriceResolved`, then calls `market.resolve` |
| `configOf(market)`, `owner()` | view | any | |
| `transferOwnership`, `renounceOwnership` | owner, inherited | any | Emits `OwnershipTransferred` |

| Event or error | Kind | When |
|---|---|---|
| `MarketConfigured(market indexed, feed indexed, threshold, comparison, maxStaleness)` | event | `configure` |
| `PriceResolved(market indexed, roundId, price, outcome)` | event | `resolve` |
| `OwnershipTransferred` | inherited event | Owner changes |
| `InvalidConfig()` | error | Zero `feed` or zero `maxStaleness` |
| `MarketNotUsingResolver(market)` | error | Market's arbitrator is not this contract |
| `AlreadyConfigured(market)`, `ConfigureAfterClose(market)` | error | Second `configure`; at or after `closeTime` |
| `NotConfigured(market)` | error | `resolve` on an unconfigured market |
| `RoundNotFound(roundId)` | error | `updatedAt == 0` |
| `RoundAfterClose(roundId, updatedAt)` | error | Round updated after `closeTime` |
| `RoundSuperseded(roundId, nextUpdatedAt)` | error | A later round was also at or before `closeTime` |
| `StalePrice(updatedAt, closeTime)` | error | Older than `maxStaleness` at close |
| `InvalidPrice(answer)` | error | `answer <= 0` |
| `OwnableUnauthorizedAccount`, `OwnableInvalidOwner` | inherited errors | Non-owner call; zero owner |

`configure` does not check that the market came from the Sooth factory. There is no L2 sequencer uptime
check.

## 6. OutcomeOrderBook

Interface `IOutcomeOrderBook`. Inherits `ERC1155Holder`, `ReentrancyGuardTransient`. No owner, no fee, no
mint or burn. Rules, rounding and website: [order-book.md](order-book.md).

| Name | Kind | Meaning |
|---|---|---|
| `PRICE_SCALE` | public constant | `1e6` = 1 USDC per whole share |
| `factory` | public immutable | Markets must belong to it |
| `outcomeToken` | public immutable | `factory.outcomeToken()` |
| `listingCount` | public storage | Last listing id. Ids start at 1 |
| `_listings(id)` | internal mapping | `Listing` by id |
| `_books(market, outcome)` | internal mapping | `Book` of a list sorted by price ascending, FIFO at equal price |

`constructor(IMarketFactory factory_)`. No zero check.

| Function | Who | When | Effect |
|---|---|---|---|
| `list(market, outcome, amount, price) returns (listingId)` | holder, `nonReentrant` | Factory market, `Open`, `setApprovalForAll` | Inserts listing `++listingCount` after the last one priced `<= price`, emits `Listed`, escrows `amount` |
| `buy(market, outcome, shares, maxPrice, maxListings) returns (sharesBought, cost)` | anyone, `nonReentrant` | Factory market, `Open`, collateral approved | Fills from the head while `price <= maxPrice`, up to `maxListings` listings; each fill costs `ceil(fill * price / PRICE_SCALE)`, paid to the seller, emits `Filled`. Sends all shares in one transfer |
| `cancel(listingId) returns (returned)` | seller, `nonReentrant` | Any market state | Unlinks, emits `Cancelled`, returns the remaining shares |
| `quoteBuy(...)` (same arguments as `buy`) | view | Same checks as `buy` | Same walk; `(0, 0)` where `buy` would revert `NothingFilled` |
| `bestPrice(market, outcome)` | view | any | Head price, or 0 |
| `listingsOf(market, outcome, startAfter, count) returns (ids)` | view | any | Up to `count` ids in fill order after `startAfter` (0 = head) |
| `getListing(listingId)` | view | any | `remaining == 0` means filled or cancelled |
| `PRICE_SCALE()`, `factory()`, `outcomeToken()`, `listingCount()` | view | any | |
| `onERC1155Received`, `onERC1155BatchReceived`, `supportsInterface` | inherited `ERC1155Holder` | Transfers in | Lets the book hold escrow |

| Event or error | Kind | When |
|---|---|---|
| `Listed(listingId indexed, market indexed, seller indexed, outcome, amount, price)` | event | `list` |
| `Filled(listingId indexed, market indexed, buyer indexed, seller, outcome, shares, cost)` | event | Each listing touched by `buy` |
| `Cancelled(listingId indexed, market indexed, seller indexed, returned)` | event | `cancel` |
| `NotFactoryMarket(market)` | error | `list`, `buy`, `quoteBuy` on a non-factory market |
| `MarketNotOpen(currentState)` | error | `list`, `buy`, `quoteBuy` when not `Open` |
| `ZeroAmount()` | error | `amount`, `shares` or `maxListings` is 0 |
| `InvalidPrice(price)` | error | `price == 0` or `price >= PRICE_SCALE` |
| `NotSeller(caller)` | error | `cancel` by someone else |
| `ListingNotFound(listingId)` | error | `cancel` of an unknown or closed id; bad `startAfter` in `listingsOf` |
| `NothingFilled()` | error | `buy` matched nothing |
| `ReentrancyGuardReentrantCall()`, `SafeERC20FailedOperation(token)` | inherited errors | Re-entry; failed collateral transfer |

## 7. Libraries and external interfaces

| Item | Spec |
|---|---|
| `OutcomeTokenId.compute(marketId, outcome)` | `uint256(keccak256(abi.encode(marketId, outcome)))`. Internal pure; `web/src/chain.ts` uses the same formula |
| `AggregatorV3Interface` | Minimal copy of Chainlink's interface: `decimals()`, `description()`, `version()`, `getRoundData(roundId)`, `latestRoundData()`. The resolver uses the last two |

## 8. Mocks (test only)

| Contract | Functions | Notes |
|---|---|---|
| `MockUSDC` (`mUSDC`) | Standard ERC-20 with `decimals` = 6, plus `mint(to, amount)` with **no access control**. Inherited events `Transfer`, `Approval`; errors `ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, `ERC20InvalidSender`, `ERC20InvalidReceiver`, `ERC20InvalidApprover`, `ERC20InvalidSpender` | `DeployMarketFactory.s.sol` deploys it only on chains 31337, 84532, 11155111, 421614 |
| `MockAggregator` | `setRound(roundId, answer, updatedAt)` (no access control), `latestRoundId`, `decimals` = 8, `description` = "ETH / USD", `version` = 4, `getRoundData`, `latestRoundData` | Unset rounds return zeros. The highest id set is the latest |

## 9. Access control

| Role | Held by (Base Sepolia, at deploy) | Can do |
|---|---|---|
| Factory `DEFAULT_ADMIN_ROLE` | The deployer wallet (`ADMIN` argument). Later role changes were not checked on chain | `createMarket`, grant and revoke roles |
| `Market.factory`, `OutcomeToken.factory` | `MarketFactory` | `Market.initialize`, `registerMarket` |
| `OutcomeToken.marketOf[id]` | The market for that id | `mint`, `mintBatch`, `burn`, `burnBatch` of its ids |
| `Market.arbitrator` | Set per market: `OptimisticResolver`, `ChainlinkResolver`, or any address | `Market.resolve` while `Closed` |
| `OptimisticResolver` owner (judge) | The deployer wallet | `rule`, ownership functions |
| `ChainlinkResolver` owner | The deployer wallet | `configure`, ownership functions |
| Order book seller | Listing creator | `cancel` of their listing |
| Anyone | | Trade, redeem, trigger `withdrawFees` / `withdrawLiquidity` (paid to `creator`), `propose`, `dispute`, `finalize`, `refund`, `ChainlinkResolver.resolve`, `list`, `buy` |

No contract is upgradeable. There is no pause and no way for an admin to move a market's collateral.

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
| `CreateMarket.s.sol` | Approves the seed, calls `createMarket`, and for price markets `ChainlinkResolver.configure` in the same broadcast | `FACTORY`, `SPEC`, `CLOSE_TIME`, `LIQUIDITY` (default `100e6`), `ARBITRATOR`; price markets: `FEED`, `RESOLVER`, `THRESHOLD`, `COMPARISON` (`below` / `above`), `MAX_STALENESS` (default 3600 s) |
| `ResolveChainlinkMarket.s.sol` | Finds the round live at close (current phase only) and calls `ChainlinkResolver.resolve` | `RESOLVER`, `MARKET`, `ROUND_ID` (optional) |

## Notes

- `IMarket.State.Proposed` is in the enum but `Market` never stores or returns it; proposal status lives in
  `OptimisticResolver.Status`.
- `OutcomeToken.burn` / `burnBatch` skip ERC-1155 approval. `Market` uses them only in `redeem` (on the
  caller) and on its own pool.
- `Market`, `OptimisticResolver` and `OutcomeOrderBook` push payments. A recipient blocked by the
  collateral token blocks that call.
- `Market.resolve` has no reentrancy guard; it makes no external calls.
