import { parseAbi, type Address } from 'viem'

// Base Sepolia deployment, from contracts/broadcast/DeployMarketFactory.s.sol/84532/run-latest.json.
export const FACTORY: Address = '0x8d399B14ea106bA62F79186217DB6fF1F75dc492'
// Sooth's MockUSDC (mUSDC, 6 decimals), the collateral for every market.
export const USDC: Address = '0x5f29331BBBA6f605942f5de0B217359F3C7B7c51'
// Factory deploy block: log scans start here, nothing older can belong to Sooth.
export const DEPLOY_BLOCK = 50_040_022n
// Deployed by the factory constructor: one ERC-1155 holds every market's YES/NO shares.
export const OUTCOME_TOKEN: Address = '0xA2D1e9A1e195d01B1aC21090962B7F2AD76BDB5B'
// Bonded-proposal resolver; its owner is the judge for disputes.
export const OPTIMISTIC_RESOLVER: Address = '0xe37DB6692De70F5fe69fcABb64b7C737fA096335'
// Price-feed resolver: settles on the Chainlink round live at close; anyone can trigger it.
export const CHAINLINK_RESOLVER: Address = '0xAD3F05e6eFFeCD81278894266f5816691E704638'
// Holder-to-holder order book, from contracts/broadcast/DeployOrderBook.s.sol/84532/run-latest.json.
// Setting it to the zero address hides the market page's order-book panel.
export const ORDER_BOOK: Address = '0x539a5842371cEeA853A5Adab48bAFc2a5d9B2b05'

export const factoryAbi = parseAbi([
  'function marketCount() view returns (uint256)',
  'function markets(uint256 marketId) view returns (address)',
  'function hasRole(bytes32 role, address account) view returns (bool)',
  'function createMarket((address arbitrator, uint64 closeTime, uint16 initialYesProbabilityBps, string spec, uint256 initialLiquidity) p) returns (uint256 marketId, address market)',
  'error ZeroArbitrator()',
  'error CloseTimeInPast(uint64 closeTime, uint256 currentTime)',
  'error UnsupportedInitialProbability(uint16 initialYesProbabilityBps)',
  'error LiquidityTooLow(uint256 initialLiquidity, uint256 minLiquidity)',
  'error EmptySpec()',
  'error AccessControlUnauthorizedAccount(address account, bytes32 neededRole)',
  'event MarketCreated(uint256 indexed marketId, address indexed market, address indexed creator, address arbitrator, address collateral, uint64 closeTime, bytes32 specHash, string spec, uint256 initialLiquidity)',
])

// Outcome: 0 = Yes, 1 = No. State: 0 Open, 1 Closed, 2 Proposed, 3 Resolved, 4 Cancelled.
export const marketAbi = parseAbi([
  'function yesTokenId() view returns (uint256)',
  'function noTokenId() view returns (uint256)',
  'function yesPool() view returns (uint256)',
  'function noPool() view returns (uint256)',
  'function closeTime() view returns (uint64)',
  'function state() view returns (uint8)',
  'function winningOutcome() view returns (uint8)',
  'function creator() view returns (address)',
  'function liquidityWithdrawn() view returns (bool)',
  'function accruedFees() view returns (uint256)',
  'function quoteBuy(uint8 outcome, uint256 collateralIn) view returns (uint256 sharesOut, uint256 fee)',
  'function quoteSell(uint8 outcome, uint256 sharesIn) view returns (uint256 collateralOut, uint256 fee)',
  'function buy(uint8 outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline) returns (uint256 sharesOut)',
  'function sell(uint8 outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline) returns (uint256 collateralOut)',
  'function redeem() returns (uint256 payout)',
  'function withdrawLiquidity() returns (uint256 amount)',
  'function withdrawFees() returns (uint256 amount)',
  'function resolve(uint8 outcome)',
  'event Bought(address indexed trader, uint8 indexed outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee)',
  'event Sold(address indexed trader, uint8 indexed outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee)',
  'event FeesWithdrawn(address indexed recipient, uint256 amount)',
  'event LiquidityWithdrawn(address indexed recipient, uint256 amount)',
  'event Redeemed(address indexed holder, uint256 payout)',
  'error InsufficientOutput(uint256 actual, uint256 minimum)',
  'error TradingClosed(uint8 currentState)',
  'error DeadlineExpired(uint256 deadline, uint256 currentTime)',
  'error NotSettled(uint8 currentState)',
  'error NothingToRedeem()',
  'error LiquidityAlreadyWithdrawn()',
  'error NotArbitrator(address caller)',
  'error CannotResolve(uint8 currentState)',
  'error NoFeesToWithdraw()',
  'error TradingStillOpen()',
])

export const outcomeTokenAbi = parseAbi([
  'function balanceOf(address account, uint256 id) view returns (uint256)',
  'function balanceOfBatch(address[] accounts, uint256[] ids) view returns (uint256[])',
  'function isApprovedForAll(address account, address operator) view returns (bool)',
  'function setApprovalForAll(address operator, bool approved)',
])

// Status: 0 None, 1 Proposed, 2 Disputed, 3 Settled. Bonds are in USDC.
export const optimisticResolverAbi = parseAbi([
  'function propose(address market, uint8 outcome, string evidenceURI)',
  'function dispute(address market, string evidenceURI)',
  'function finalize(address market)',
  'function rule(address market, uint8 outcome)',
  'function refund(address market)',
  'function bond() view returns (uint256)',
  'function challengeWindow() view returns (uint64)',
  'function owner() view returns (address)',
  'event Proposed(address indexed market, address indexed proposer, uint8 outcome, string evidenceURI)',
  'event Disputed(address indexed market, address indexed disputer, string evidenceURI)',
  'event Finalized(address indexed market, uint8 outcome)',
  'event Ruled(address indexed market, uint8 outcome, address indexed winner)',
  'event Refunded(address indexed market)',
  'error NotFactoryMarket(address market)',
  'error MarketNotUsingResolver(address market)',
  'error MarketNotClosed(uint8 currentState)',
  'error ProposalTooLate(uint256 windowEnd, uint64 resolutionDeadline)',
  'error WrongStatus(uint8 current)',
  'error ChallengeWindowOpen(uint256 windowEnd)',
  'error ChallengeWindowClosed(uint256 windowEnd)',
  'error MarketNotCancelled(uint8 currentState)',
  'error OwnableUnauthorizedAccount(address account)',
  // Bubbled up from the bond transfer, so a short balance or allowance reads as such.
  'error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)',
  'error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)',
])

// Comparison: 0 Below, 1 Above (strict); a price equal to the threshold resolves NO.
export const chainlinkResolverAbi = parseAbi([
  'function configure(address market, (address feed, int256 threshold, uint8 comparison, uint64 maxStaleness) config)',
  'function resolve(address market, uint80 roundId)',
  'function configOf(address market) view returns ((address feed, int256 threshold, uint8 comparison, uint64 maxStaleness))',
  'event PriceResolved(address indexed market, uint80 roundId, int256 price, uint8 outcome)',
  'error NotConfigured(address market)',
  'error RoundNotFound(uint80 roundId)',
  'error RoundAfterClose(uint80 roundId, uint256 updatedAt)',
  'error RoundSuperseded(uint80 roundId, uint256 nextUpdatedAt)',
  'error StalePrice(uint256 updatedAt, uint64 closeTime)',
  'error InvalidPrice(int256 answer)',
  'error InvalidConfig()',
  'error MarketNotUsingResolver(address market)',
  'error AlreadyConfigured(address market)',
  'error ConfigureAfterClose(address market)',
  'error OwnableUnauthorizedAccount(address account)',
  // Bubbled up from Market.resolve when someone resolved first.
  'error CannotResolve(uint8 currentState)',
])

// Outcome: 0 = Yes, 1 = No. Prices are mUSDC units (6 decimals) per whole share, strictly between 0 and
// PRICE_SCALE (1e6); a buyer pays ceil(fill * price / 1e6) per listing. list and buy only while Open.
export const orderBookAbi = parseAbi([
  'struct Listing { address seller; address market; uint8 outcome; uint256 price; uint256 remaining; uint256 prev; uint256 next; }',
  'function list(address market, uint8 outcome, uint256 amount, uint256 price) returns (uint256 listingId)',
  'function buy(address market, uint8 outcome, uint256 shares, uint256 maxPrice, uint256 maxListings) returns (uint256 sharesBought, uint256 cost)',
  'function cancel(uint256 listingId) returns (uint256 returned)',
  'function quoteBuy(address market, uint8 outcome, uint256 shares, uint256 maxPrice, uint256 maxListings) view returns (uint256 sharesBought, uint256 cost)',
  'function bestPrice(address market, uint8 outcome) view returns (uint256)',
  'function listingsOf(address market, uint8 outcome, uint256 startAfter, uint256 count) view returns (uint256[] ids)',
  'function getListing(uint256 listingId) view returns (Listing)',
  'function PRICE_SCALE() view returns (uint256)',
  'function factory() view returns (address)',
  'function outcomeToken() view returns (address)',
  'function listingCount() view returns (uint256)',
  'event Listed(uint256 indexed listingId, address indexed market, address indexed seller, uint8 outcome, uint256 amount, uint256 price)',
  'event Filled(uint256 indexed listingId, address indexed market, address indexed buyer, address seller, uint8 outcome, uint256 shares, uint256 cost)',
  'event Cancelled(uint256 indexed listingId, address indexed market, address indexed seller, uint256 returned)',
  'error NotFactoryMarket(address market)',
  'error MarketNotOpen(uint8 currentState)',
  'error ZeroAmount()',
  'error InvalidPrice(uint256 price)',
  'error NotSeller(address caller)',
  'error ListingNotFound(uint256 listingId)',
  'error NothingFilled()',
  // Bubbled up from the share and mUSDC transfers, so a short balance or allowance reads as such.
  'error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId)',
  'error ERC1155MissingApprovalForAll(address operator, address owner)',
  'error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)',
  'error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)',
])

// The subset of AggregatorV3Interface the page reads: feed name and scale, and round lookups for resolve.
export const aggregatorAbi = parseAbi([
  'function decimals() view returns (uint8)',
  'function description() view returns (string)',
  'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
  'function getRoundData(uint80 roundId) view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
])
