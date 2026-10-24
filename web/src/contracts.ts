import { parseAbi, type Address } from 'viem'

// Base Sepolia deployment, from contracts/broadcast/DeployMarketFactory.s.sol/84532/run-latest.json.
export const FACTORY: Address = '0x5A4126469494e7Fe968250bE4a5506942c2EA817'
// Sooth's MockUSDC (mUSDC, 6 decimals), the collateral for every market.
export const USDC: Address = '0x5f29331BBBA6f605942f5de0B217359F3C7B7c51'
// Factory deploy block: log scans start here, nothing older can belong to Sooth.
export const DEPLOY_BLOCK = 49_608_346n

export const factoryAbi = parseAbi([
  'function marketCount() view returns (uint256)',
  'function markets(uint256 marketId) view returns (address)',
  'event MarketCreated(uint256 indexed marketId, address indexed market, address indexed creator, address arbitrator, address collateral, uint64 closeTime, bytes32 specHash, string specCID, uint256 initialLiquidity)',
])

// Outcome: 0 = Yes, 1 = No. State: 0 Open, 1 Closed, 2 Proposed, 3 Resolved, 4 Cancelled.
export const marketAbi = parseAbi([
  'function yesPool() view returns (uint256)',
  'function noPool() view returns (uint256)',
  'function closeTime() view returns (uint64)',
  'function state() view returns (uint8)',
  'function specHash() view returns (bytes32)',
  'function quoteBuy(uint8 outcome, uint256 collateralIn) view returns (uint256 sharesOut, uint256 fee)',
  'function quoteSell(uint8 outcome, uint256 sharesIn) view returns (uint256 collateralOut, uint256 fee)',
  'function buy(uint8 outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline) returns (uint256 sharesOut)',
  'function sell(uint8 outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline) returns (uint256 collateralOut)',
  'event Bought(address indexed trader, uint8 indexed outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee)',
  'event Sold(address indexed trader, uint8 indexed outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee)',
])
