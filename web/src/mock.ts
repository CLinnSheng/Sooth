// Mock data and helpers for the UI prototype. Everything here is replaced by
// contract reads (viem/wagmi) once the contracts exist.

export type Category = 'Crypto' | 'Economics' | 'Science' | 'Climate' | 'Sports'
export const categories: Category[] = ['Crypto', 'Economics', 'Science', 'Climate', 'Sports']
export type Outcome = 'YES' | 'NO'

export type Market = {
  id: number
  address: string
  question: string
  category?: Category // unset when the spec can't be verified
  closesAt: string // ISO timestamp
  status: 'open' | 'closed' | 'resolved'
  resolvedOutcome?: Outcome
  // CPMM pool reserves of outcome shares. YES price = noReserve / (yesReserve + noReserve).
  yesReserve: number
  noReserve: number
  volume: number // USDC
  history: number[] // daily YES price, oldest first, last = current
  rules: string
  source?: { label: string; url: string }
}

export type Position = { marketId: number; outcome: Outcome; shares: number; avgPrice: number }

export type Trade = {
  marketId: number
  trader: string
  side: 'Buy' | 'Sell'
  outcome: Outcome
  amount: number // USDC paid or received
  shares: number
  at: string // ISO timestamp
  tx: string
}

export const FEE = 0.005
export const MARKET_ADDRESS = '0x8B2a4f1C93e0d5B7A6c2E9f04D31b8C5aE07D17F'
export const WALLET = { address: '0x71C7656EC7ab88b098defB751B7401B5f6d89A42', usdc: 250 }

// Deterministic fake price walk that ends exactly at the current price.
function walk(end: number, start: number, seed: number, days = 90): number[] {
  return Array.from({ length: days }, (_, i) => {
    const t = i / (days - 1)
    const noise = i === days - 1 ? 0 : 0.025 * Math.sin(i * seed) + 0.015 * Math.sin(i * seed * 2.7)
    return Math.min(0.99, Math.max(0.01, start + (end - start) * t + noise))
  })
}

// Reserves chosen so that noReserve / (yes + no) equals the target price.
function pool(price: number, depth: number) {
  return { yesReserve: depth * (1 - price), noReserve: depth * price }
}

const placeholderRules =
  'Placeholder rules. The final resolution process (who resolves, data source, dispute window) is not decided yet.'

export const markets: Market[] = [
  {
    id: 1,
    address: MARKET_ADDRESS,
    question: 'Will ETH be at or above $4,000 on January 1, 2027?',
    category: 'Crypto',
    closesAt: '2026-12-31T23:59:00Z',
    status: 'open',
    ...pool(0.64, 4000),
    volume: 128_400,
    history: walk(0.64, 0.52, 1.3),
    rules: `YES if the ETH/USD price is at or above $4,000 at 00:00 UTC on January 1, 2027. Otherwise NO. ${placeholderRules}`,
    source: { label: 'Chainlink ETH / USD', url: 'https://data.chain.link/feeds/ethereum/mainnet/eth-usd' },
  },
  {
    id: 2,
    address: MARKET_ADDRESS,
    question: 'Will BTC be at or above $100,000 on January 1, 2027?',
    category: 'Crypto',
    closesAt: '2026-12-31T23:59:00Z',
    status: 'open',
    ...pool(0.58, 3200),
    volume: 96_200,
    history: walk(0.58, 0.61, 2.1),
    rules: `YES if the BTC/USD price is at or above $100,000 at 00:00 UTC on January 1, 2027. Otherwise NO. ${placeholderRules}`,
    source: { label: 'Chainlink BTC / USD', url: 'https://data.chain.link/feeds/ethereum/mainnet/btc-usd' },
  },
  {
    id: 3,
    address: MARKET_ADDRESS,
    question: 'Will US annual CPI be below 3% for December 2026?',
    category: 'Economics',
    closesAt: '2027-01-12T13:30:00Z',
    status: 'open',
    ...pool(0.72, 1800),
    volume: 42_800,
    history: walk(0.72, 0.6, 0.7),
    rules: `YES if the BLS reports December 2026 year-over-year CPI-U below 3.0%. Otherwise NO. ${placeholderRules}`,
    source: { label: 'US Bureau of Labor Statistics', url: 'https://www.bls.gov/cpi/' },
  },
  {
    id: 4,
    address: MARKET_ADDRESS,
    question: 'Will the Fed upper target rate be below 4% after its December meeting?',
    category: 'Economics',
    closesAt: '2026-12-09T19:00:00Z',
    status: 'open',
    ...pool(0.41, 2400),
    volume: 67_500,
    history: walk(0.41, 0.48, 1.9),
    rules: `YES if the upper bound of the federal funds target range is below 4.00% after the December 2026 FOMC meeting. ${placeholderRules}`,
    source: { label: 'Federal Reserve', url: 'https://www.federalreserve.gov/monetarypolicy/openmarket.htm' },
  },
  {
    id: 5,
    address: MARKET_ADDRESS,
    question: 'Will NASA launch Artemis III before January 1, 2027?',
    category: 'Science',
    closesAt: '2026-12-31T23:59:00Z',
    status: 'open',
    ...pool(0.35, 1500),
    volume: 31_600,
    history: walk(0.35, 0.3, 2.6),
    rules: `YES if NASA launches the Artemis III mission before 00:00 UTC on January 1, 2027. ${placeholderRules}`,
    source: { label: 'NASA Artemis', url: 'https://www.nasa.gov/humans-in-space/artemis/' },
  },
  {
    id: 6,
    address: MARKET_ADDRESS,
    question: 'Will New York reach 32°C on June 1, 2027?',
    category: 'Climate',
    closesAt: '2027-06-02T04:00:00Z',
    status: 'open',
    ...pool(0.26, 1000),
    volume: 18_900,
    history: walk(0.26, 0.3, 1.1),
    rules: `YES if the NOAA Central Park station records a maximum of 32°C or higher on June 1, 2027. ${placeholderRules}`,
    source: { label: 'NOAA Climate Data', url: 'https://www.ncei.noaa.gov/' },
  },
  {
    id: 7,
    address: MARKET_ADDRESS,
    question: 'Will the Sooth testnet launch before November 1, 2026?',
    category: 'Crypto',
    closesAt: '2026-10-01T00:00:00Z',
    status: 'resolved',
    resolvedOutcome: 'YES',
    ...pool(0.99, 800),
    volume: 5_400,
    history: walk(0.99, 0.5, 3.1),
    rules: `YES if the Sooth market contract is deployed to Base Sepolia before November 1, 2026. ${placeholderRules}`,
    source: { label: 'Basescan (Base Sepolia)', url: 'https://sepolia.basescan.org/' },
  },
]

export const positions: Position[] = [
  { marketId: 1, outcome: 'YES', shares: 97.4, avgPrice: 0.66 },
  { marketId: 3, outcome: 'NO', shares: 40, avgPrice: 0.25 },
  { marketId: 7, outcome: 'YES', shares: 50, avgPrice: 0.42 },
]

const me = WALLET.address
export const trades: Trade[] = [
  { marketId: 1, trader: '0x3fA1c2B7e8D94a0b5C6d7E8f9A0b1C2d3E4f5A6b', side: 'Buy', outcome: 'NO', amount: 20, shares: 55.1, at: '2026-10-14T09:12:00Z', tx: '0x9c1e' },
  { marketId: 1, trader: me, side: 'Buy', outcome: 'YES', amount: 64.32, shares: 97.4, at: '2026-10-12T14:03:00Z', tx: '0x4b7a' },
  { marketId: 3, trader: me, side: 'Buy', outcome: 'NO', amount: 10, shares: 40, at: '2026-10-08T11:40:00Z', tx: '0x77d2' },
  { marketId: 1, trader: '0xA9b8C7d6E5f4A3b2C1d0E9f8A7b6C5d4E3f2A1b0', side: 'Sell', outcome: 'YES', amount: 31.5, shares: 50, at: '2026-10-06T08:21:00Z', tx: '0x1f0c' },
  { marketId: 7, trader: me, side: 'Buy', outcome: 'YES', amount: 21, shares: 50, at: '2026-09-20T16:55:00Z', tx: '0xe3a9' },
]

export const marketById = (id: number) => markets.find((m) => m.id === id)

export const priceYes = (m: Market) => m.noReserve / (m.yesReserve + m.noReserve)
export const priceOf = (m: Market, o: Outcome) => (o === 'YES' ? priceYes(m) : 1 - priceYes(m))
export const change30d = (m: Market) => m.history[m.history.length - 1] - m.history[Math.max(0, m.history.length - 31)]

// Value of a position now: resolved markets pay 1 per winning share, 0 per losing share.
export function positionValue(p: Position) {
  const m = marketById(p.marketId)!
  if (m.status === 'resolved') return m.resolvedOutcome === p.outcome ? p.shares : 0
  return p.shares * priceOf(m, p.outcome)
}

// CPMM (fixed product) quotes, same model the contract will use.
// Buy: the net amount mints `net` YES + `net` NO into the pool, then the pool pays out
// enough of the chosen outcome to keep yes * no constant.
export function quoteBuy(m: Market, o: Outcome, amount: number) {
  const fee = amount * FEE
  const net = amount - fee
  const [pool, other] = o === 'YES' ? [m.yesReserve, m.noReserve] : [m.noReserve, m.yesReserve]
  const shares = pool + net - (pool * other) / (other + net)
  const spot = priceOf(m, o)
  return { shares, fee, avgPrice: amount / shares, impact: net / shares / spot - 1 }
}

// Sell: the pool takes `shares` of the outcome and returns R collateral, where
// (pool + shares - R) * (other - R) = pool * other, solved for R.
export function quoteSell(m: Market, o: Outcome, shares: number) {
  const [pool, other] = o === 'YES' ? [m.yesReserve, m.noReserve] : [m.noReserve, m.yesReserve]
  const b = pool + shares + other
  const gross = (b - Math.sqrt(b * b - 4 * shares * other)) / 2
  const fee = gross * FEE
  const spot = priceOf(m, o)
  return { received: gross - fee, fee, avgPrice: (gross - fee) / shares, impact: 1 - gross / shares / spot }
}

export const usdc = (n: number) =>
  n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
export const compact = (n: number) =>
  n.toLocaleString('en-US', { notation: 'compact', maximumFractionDigits: 1 }).toLowerCase()
export const pct = (p: number) => `${Math.round(p * 100)}%`
// Share price in cents: 1 USDC = 100¢, so a 0.64 USDC share reads as 64¢.
export const cents = (p: number, digits = 0) => `${(p * 100).toFixed(digits)}¢`
export const signed = (n: number) => `${n >= 0 ? '+' : '−'}${usdc(Math.abs(n))}`
export const shortAddr = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`
export const date = (iso: string) =>
  new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' })
export const basescanTx = (tx: string) => `https://sepolia.basescan.org/tx/${tx}`
export const basescanAddr = (a: string) => `https://sepolia.basescan.org/address/${a}`
