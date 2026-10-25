import { parseAbi, type Address } from 'viem'

// Base Sepolia deployment, from contracts/broadcast/DeployMarketFactory.s.sol/84532/run-latest.json.
export const FACTORY: Address = '0x8d399B14ea106bA62F79186217DB6fF1F75dc492'
// Sooth's MockUSDC (mUSDC, 6 decimals), the collateral for every market.
export const USDC: Address = '0x5f29331BBBA6f605942f5de0B217359F3C7B7c51'
// Factory deploy block: log scans start here, nothing older can belong to Sooth.
export const DEPLOY_BLOCK = 50_040_022n
// Deployed by the factory constructor: one ERC-1155 holds every market's YES/NO shares.
export const OUTCOME_TOKEN: Address = '0xA2D1e9A1e195d01B1aC21090962B7F2AD76BDB5B'

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
  'function quoteBuy(uint8 outcome, uint256 collateralIn) view returns (uint256 sharesOut, uint256 fee)',
  'function quoteSell(uint8 outcome, uint256 sharesIn) view returns (uint256 collateralOut, uint256 fee)',
  'function buy(uint8 outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline) returns (uint256 sharesOut)',
  'function sell(uint8 outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline) returns (uint256 collateralOut)',
  'event Bought(address indexed trader, uint8 indexed outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee)',
  'event Sold(address indexed trader, uint8 indexed outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee)',
  'error InsufficientOutput(uint256 actual, uint256 minimum)',
  'error TradingClosed(uint8 currentState)',
  'error DeadlineExpired(uint256 deadline, uint256 currentTime)',
])

export const outcomeTokenAbi = parseAbi([
  'function balanceOf(address account, uint256 id) view returns (uint256)',
  'function balanceOfBatch(address[] accounts, uint256[] ids) view returns (uint256[])',
  'function isApprovedForAll(address account, address operator) view returns (bool)',
  'function setApprovalForAll(address operator, bool approved)',
])
