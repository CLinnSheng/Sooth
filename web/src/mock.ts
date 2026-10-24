// Shared types and formatting helpers.

export type Category = 'Crypto' | 'Economics' | 'Science' | 'Climate' | 'Sports'
export const categories: Category[] = ['Crypto', 'Economics', 'Science', 'Climate', 'Sports']
export type Outcome = 'YES' | 'NO'

export type Market = {
  id: number
  address: string
  question: string
  category?: Category // unset when the on-chain spec is malformed
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

export const FEE = 0.01 // Market.FEE_BPS = 100

export const priceYes = (m: Market) => m.noReserve / (m.yesReserve + m.noReserve)
export const priceOf = (m: Market, o: Outcome) => (o === 'YES' ? priceYes(m) : 1 - priceYes(m))
export const change30d = (m: Market) => m.history[m.history.length - 1] - m.history[Math.max(0, m.history.length - 31)]

// Value of a position now: resolved markets pay 1 per winning share, 0 per losing share.
export function positionValue(p: Position, m: Market) {
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
