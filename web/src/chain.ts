import { useQuery } from '@tanstack/react-query'
import {
  encodeAbiParameters,
  formatUnits,
  getAbiItem,
  hexToBigInt,
  keccak256,
  parseAbiParameters,
  zeroAddress,
  zeroHash,
  type Address,
} from 'viem'
import { useReadContract } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { baseSepolia } from 'wagmi/chains'
import {
  CHAINLINK_RESOLVER,
  DEPLOY_BLOCK,
  FACTORY,
  OPTIMISTIC_RESOLVER,
  ORDER_BOOK,
  OUTCOME_TOKEN,
  chainlinkResolverAbi,
  factoryAbi,
  marketAbi,
  optimisticResolverAbi,
  orderBookAbi,
  outcomeTokenAbi,
} from './contracts'
import {
  categories,
  DAY_SECS,
  type Category,
  type Market,
  type Outcome,
  type Position,
  type PricePoint,
  type Redemption,
  type ResolutionRequest,
  type Trade,
} from './mock'
import { config } from './wagmi'

const client = getPublicClient(config, { chainId: baseSepolia.id })

// Tenderly takes 1M+ blocks per getLogs but rate-limits bursts (429 at ~10 at once), so one call spans
// everything since deploy; 10M blocks is about 230 days of Base blocks. Each call returns at most 3,000 logs.
const MAX_LOG_RANGE = 10_000_000n
const REFETCH_MS = 30_000
const STATE_OPEN = 0
// Mirrors IMarket.State. Proposed (2) is never set by Market; Closed and Proposed both show as closed.
const STATE_RESOLVED = 3
const STATE_CANCELLED = 4
const OUTCOME_YES = 0
const OUTCOME_NO = 1
const OUTCOMES: Outcome[] = ['YES', 'NO']
// The factory only seeds equal pools, so every market opens at 50/50.
const OPENING_PRICE = 0.5
// Mirrors Market.RESOLUTION_WINDOW: a market unresolved this long after close cancels.
const RESOLUTION_WINDOW_SECS = 7 * DAY_SECS
const INVALID_SPEC_RULES = 'This market was created with a spec that is not in the expected format.'

const soothEvents = [
  getAbiItem({ abi: factoryAbi, name: 'MarketCreated' }),
  getAbiItem({ abi: marketAbi, name: 'Bought' }),
  getAbiItem({ abi: marketAbi, name: 'Sold' }),
  getAbiItem({ abi: marketAbi, name: 'FeesWithdrawn' }),
  getAbiItem({ abi: marketAbi, name: 'LiquidityWithdrawn' }),
  getAbiItem({ abi: marketAbi, name: 'Redeemed' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Proposed' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Disputed' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Finalized' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Ruled' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Refunded' }),
  getAbiItem({ abi: chainlinkResolverAbi, name: 'PriceResolved' }),
  getAbiItem({ abi: orderBookAbi, name: 'Listed' }),
  getAbiItem({ abi: orderBookAbi, name: 'Filled' }),
  getAbiItem({ abi: orderBookAbi, name: 'Cancelled' }),
]

type Spec = Pick<Market, 'question' | 'category' | 'rules' | 'source'>
type MarketState = Awaited<ReturnType<typeof readMarket>>
type SoothLog = Awaited<ReturnType<typeof scanLogs>>[number]
type CreatedLog = Extract<SoothLog, { eventName: 'MarketCreated' }>
type TradeLog = Extract<SoothLog, { eventName: 'Bought' | 'Sold' }>
type PriceLog = Extract<SoothLog, { eventName: 'PriceResolved' }>
type PayoutLog = Extract<SoothLog, { eventName: 'FeesWithdrawn' | 'LiquidityWithdrawn' }>
type RedeemLog = Extract<SoothLog, { eventName: 'Redeemed' }>
type BookLog = Extract<SoothLog, { eventName: 'Listed' | 'Filled' | 'Cancelled' }>
type ResolverLog = Exclude<SoothLog, CreatedLog | TradeLog | PriceLog | PayoutLog | RedeemLog | BookLog>
// An order-book listing, rebuilt from its Listed, Filled and Cancelled events.
type OpenListing = { marketId: number; outcome: Outcome; seller: string; price: number; remaining: number }
// Everything the scan found for one market, besides its MarketCreated.
type MarketLogs = { trades: TradeLog[]; request: ResolverLog[]; price?: PriceLog; payouts: PayoutLog[] }

// Outcome shares use the collateral's 6 decimals.
const toUnits = (raw: bigint) => Number(formatUnits(raw, 6))

// shortcut: logs are scanned in the browser, one getLogs call per 50k blocks since deploy, and logs
// from a reorg stay cached until reload. Move to an indexer (Ponder) once first load gets slow.
const scan: { toBlock: bigint; logs: SoothLog[] } = { toBlock: DEPLOY_BLOCK - 1n, logs: [] }
const blockTimes = new Map<bigint, number>()

export function useMarkets() {
  return useQuery({ queryKey: ['markets'], queryFn: loadMarkets, refetchInterval: REFETCH_MS })
}

// DEFAULT_ADMIN_ROLE is bytes32(0) in OpenZeppelin AccessControl.
export function useIsAdmin(account: Address | undefined) {
  return useReadContract({
    address: FACTORY,
    abi: factoryAbi,
    functionName: 'hasRole',
    args: [zeroHash, account ?? zeroAddress],
    chainId: baseSepolia.id,
    query: { enabled: Boolean(account) },
  })
}

// Mirrors OutcomeTokenId.compute: keccak256(abi.encode(marketId, outcome)).
const tokenId = (marketId: number, outcome: Outcome) =>
  hexToBigInt(
    keccak256(encodeAbiParameters(parseAbiParameters('uint256, uint8'), [BigInt(marketId), outcome === 'YES' ? OUTCOME_YES : OUTCOME_NO])),
  )

export function usePositions(owner: Address | undefined): Position[] {
  const { data } = useMarkets()
  const keys = (data?.markets ?? []).flatMap((m) => OUTCOMES.map((outcome) => ({ marketId: m.id, outcome })))
  const { data: balances } = useReadContract({
    address: OUTCOME_TOKEN,
    abi: outcomeTokenAbi,
    functionName: 'balanceOfBatch',
    args: [keys.map(() => owner ?? zeroAddress), keys.map((k) => tokenId(k.marketId, k.outcome))],
    query: { enabled: Boolean(owner && keys.length) },
  })
  if (!data || !balances || !owner) return []
  const listedOf = (key: { marketId: number; outcome: Outcome }) =>
    data.listings
      .filter((l) => l.marketId === key.marketId && l.outcome === key.outcome && l.seller.toLowerCase() === owner.toLowerCase())
      .reduce((sum, l) => sum + l.remaining, 0)
  return keys.flatMap((key, i) => {
    const listed = listedOf(key)
    if (balances[i] === 0n && listed === 0) return []
    const buys = data.trades.filter(
      (t) => t.marketId === key.marketId && t.outcome === key.outcome && t.side === 'Buy' && t.trader.toLowerCase() === owner.toLowerCase(),
    )
    const cost = buys.reduce((sum, t) => sum + t.amount, 0)
    const bought = buys.reduce((sum, t) => sum + t.shares, 0)
    // Average cost over every buy; sells don't move it, so PnL is the gain on what's still held.
    return [{ ...key, shares: toUnits(balances[i]) + listed, listed, avgPrice: bought > 0 ? cost / bought : 0 }]
  })
}

async function loadMarkets(): Promise<{ markets: Market[]; trades: Trade[]; redemptions: Redemption[]; listings: OpenListing[] }> {
  // Pin every read to one block, so state and logs describe the same moment.
  const blockNumber = await client.getBlockNumber()
  const count = await client.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'marketCount', blockNumber })
  const addresses = await Promise.all(
    Array.from({ length: Number(count) }, (_, i) =>
      client.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'markets', args: [BigInt(i + 1)], blockNumber }),
    ),
  )
  const [states] = await Promise.all([
    Promise.all(addresses.map((address) => readMarket(address, blockNumber))),
    // The order book is scanned only once it is deployed (ORDER_BOOK set in contracts.ts).
    extendScan([FACTORY, OPTIMISTIC_RESOLVER, CHAINLINK_RESOLVER, ...(ORDER_BOOK === zeroAddress ? [] : [ORDER_BOOK]), ...addresses], blockNumber),
  ])
  await cacheBlockTimes(scan.logs)

  const idByAddress = new Map(addresses.map((address, i) => [address.toLowerCase(), i + 1]))
  const created = new Map<number, CreatedLog>()
  const tradeLogs: TradeLog[] = []
  const resolverLogs: ResolverLog[] = []
  const priceLogs: PriceLog[] = []
  const payoutLogs: PayoutLog[] = []
  const redeemLogs: RedeemLog[] = []
  // AMM trades and order-book activity, in the order the chain emitted them.
  const trades: Trade[] = []
  const listings = new Map<bigint, OpenListing>()
  for (const log of scan.logs) {
    if (log.eventName === 'MarketCreated') created.set(Number(log.args.marketId), log)
    else if (log.eventName === 'Bought' || log.eventName === 'Sold') {
      tradeLogs.push(log)
      trades.push(toTrade(log, idByAddress.get(log.address.toLowerCase())!))
    } else if (log.eventName === 'Listed' || log.eventName === 'Filled' || log.eventName === 'Cancelled') {
      const marketId = idByAddress.get(log.args.market.toLowerCase())
      if (marketId !== undefined) trades.push(...toBookTrades(log, marketId, listings))
    }
    else if (log.eventName === 'PriceResolved') priceLogs.push(log)
    else if (log.eventName === 'FeesWithdrawn' || log.eventName === 'LiquidityWithdrawn') payoutLogs.push(log)
    else if (log.eventName === 'Redeemed') redeemLogs.push(log)
    else resolverLogs.push(log)
  }

  const markets = states.map((state, i) => {
    const id = i + 1
    const createdLog = created.get(id)
    if (!createdLog) throw new Error(`MarketCreated log missing for market ${id}`)
    const emittedHere = (log: SoothLog) => idByAddress.get(log.address.toLowerCase()) === id
    // Resolver events name the market in an argument; the log's own address is the resolver.
    const aboutHere = (log: ResolverLog | PriceLog) => log.args.market.toLowerCase() === state.address.toLowerCase()
    const logs: MarketLogs = {
      trades: tradeLogs.filter(emittedHere),
      request: resolverLogs.filter(aboutHere),
      price: priceLogs.find(aboutHere),
      payouts: payoutLogs.filter(emittedHere),
    }
    return toMarket(id, state, createdLog, logs, parseSpec(createdLog.args.spec))
  })
  const redemptions = redeemLogs.map((log) => ({
    marketId: idByAddress.get(log.address.toLowerCase())!,
    holder: log.args.holder,
    payout: toUnits(log.args.payout),
  }))
  return { markets, trades, redemptions, listings: [...listings.values()].filter((l) => l.remaining > 0) }
}

async function readMarket(address: Address, blockNumber: bigint) {
  const call = { address, abi: marketAbi, blockNumber } as const
  const [yesPool, noPool, closeTime, state, winningOutcome, liquidityWithdrawn] = await Promise.all([
    client.readContract({ ...call, functionName: 'yesPool' }),
    client.readContract({ ...call, functionName: 'noPool' }),
    client.readContract({ ...call, functionName: 'closeTime' }),
    client.readContract({ ...call, functionName: 'state' }),
    client.readContract({ ...call, functionName: 'winningOutcome' }),
    client.readContract({ ...call, functionName: 'liquidityWithdrawn' }),
  ])
  return { address, yesPool, noPool, closeTime, state, winningOutcome, liquidityWithdrawn }
}

// Scans only blocks not seen before. A market created after the last scan has no earlier trades,
// so scanning old ranges without its address loses nothing.
async function extendScan(addresses: Address[], toBlock: bigint) {
  if (toBlock <= scan.toBlock) return
  const logs = await scanLogs(addresses, scan.toBlock + 1n, toBlock)
  scan.logs.push(...logs)
  scan.toBlock = toBlock
}

async function scanLogs(addresses: Address[], fromBlock: bigint, toBlock: bigint) {
  const ranges = []
  for (let start = fromBlock; start <= toBlock; start += MAX_LOG_RANGE) {
    const end = start + MAX_LOG_RANGE - 1n
    ranges.push(
      client.getLogs({ address: addresses, events: soothEvents, fromBlock: start, toBlock: end < toBlock ? end : toBlock, strict: true }),
    )
  }
  return (await Promise.all(ranges)).flat()
}

async function cacheBlockTimes(logs: SoothLog[]) {
  const missing = [...new Set(logs.map((log) => log.blockNumber))].filter((b) => !blockTimes.has(b))
  const blocks = await Promise.all(missing.map((blockNumber) => client.getBlock({ blockNumber })))
  for (const block of blocks) blockTimes.set(block.number, Number(block.timestamp))
}

// The factory hashes whatever text it is given, so the shape is still checked here before rendering.
export function parseSpec(json: string): Spec | null {
  let raw: unknown
  try {
    raw = JSON.parse(json)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null) return null
  const { question, category, rules, source } = raw as Record<string, unknown>
  const { label, url } = (source ?? {}) as Record<string, unknown>
  const isValid =
    typeof question === 'string' &&
    typeof rules === 'string' &&
    categories.includes(category as Category) &&
    typeof label === 'string' &&
    // The URL lands in an href, so only http(s) gets through, never javascript:.
    typeof url === 'string' &&
    /^https?:\/\//.test(url)
  return isValid ? { question, rules, category: category as Category, source: { label, url } } : null
}

function toMarket(id: number, state: MarketState, created: CreatedLog, logs: MarketLogs, spec: Spec | null): Market {
  const yesReserve = toUnits(state.yesPool)
  const noReserve = toUnits(state.noPool)
  const volume = logs.trades.reduce((sum, log) => sum + (log.eventName === 'Bought' ? log.args.collateralIn : log.args.collateralOut), 0n)
  const prices = replayPrices(created.args.initialLiquidity, logs.trades)
  const paid = (event: PayoutLog['eventName']) =>
    toUnits(logs.payouts.filter((log) => log.eventName === event).reduce((sum, log) => sum + log.args.amount, 0n))
  return {
    id,
    address: state.address,
    creator: created.args.creator,
    arbitrator: created.args.arbitrator,
    question: spec?.question ?? `Market #${id}`,
    category: spec?.category,
    rules: spec?.rules ?? INVALID_SPEC_RULES,
    source: spec?.source,
    closesAt: new Date(Number(state.closeTime) * 1000).toISOString(),
    resolutionDeadline: Number(state.closeTime) + RESOLUTION_WINDOW_SECS,
    status: toStatus(state.state),
    // winningOutcome reads as Yes (0) until resolution, so it only counts once Resolved.
    resolvedOutcome: state.state === STATE_RESOLVED ? OUTCOMES[state.winningOutcome] : undefined,
    liquidityWithdrawn: state.liquidityWithdrawn,
    request: replayRequest(logs.request),
    priceResolution: logs.price && { roundId: logs.price.args.roundId, price: logs.price.args.price },
    collected: { fees: paid('FeesWithdrawn'), liquidity: paid('LiquidityWithdrawn') },
    yesReserve,
    noReserve,
    volume: toUnits(volume),
    // Opens at 50/50 on creation, steps at every trade, and ends on the live pool price.
    history: [
      { at: blockTimes.get(created.blockNumber)!, price: OPENING_PRICE },
      ...prices,
      { at: Date.now() / 1000, price: noReserve / (yesReserve + noReserve) },
    ],
  }
}

function toStatus(state: number): Market['status'] {
  if (state === STATE_OPEN) return 'open'
  if (state === STATE_RESOLVED) return 'resolved'
  if (state === STATE_CANCELLED) return 'cancelled'
  return 'closed'
}

// Mirrors the pool updates in Market.buy/sell, so each trade's resulting price comes from its log alone.
function replayPrices(initialLiquidity: bigint, logs: TradeLog[]): PricePoint[] {
  let yes = initialLiquidity
  let no = initialLiquidity
  return logs.map((log) => {
    const isYes = log.args.outcome === OUTCOME_YES
    let [pool, opposite] = isYes ? [yes, no] : [no, yes]
    if (log.eventName === 'Bought') {
      const net = log.args.collateralIn - log.args.fee
      pool += net - log.args.sharesOut
      opposite += net
    } else {
      const gross = log.args.collateralOut + log.args.fee
      pool += log.args.sharesIn - gross
      opposite -= gross
    }
    ;[yes, no] = isYes ? [pool, opposite] : [opposite, pool]
    return { at: blockTimes.get(log.blockNumber)!, price: Number(no) / Number(yes + no) }
  })
}

const SETTLED_BY = { Finalized: 'finalized', Ruled: 'ruled', Refunded: 'refunded' } as const

// The contract allows one request per market, so its events replay in order into one record.
function replayRequest(logs: ResolverLog[]): ResolutionRequest | undefined {
  let request: ResolutionRequest | undefined
  for (const log of logs) {
    if (log.eventName === 'Proposed')
      request = {
        status: 'proposed',
        proposer: log.args.proposer,
        outcome: OUTCOMES[log.args.outcome],
        // The block time is the contract's proposedAt, so the challenge window matches it exactly.
        proposedAt: blockTimes.get(log.blockNumber)!,
        proposalEvidence: log.args.evidenceURI,
      }
    else if (!request) continue
    else if (log.eventName === 'Disputed')
      request = { ...request, status: 'disputed', disputer: log.args.disputer, disputeEvidence: log.args.evidenceURI }
    else request = { ...request, status: 'settled', settledBy: SETTLED_BY[log.eventName] }
  }
  return request
}

// Order-book events as history rows, keeping each listing's remaining shares up to date.
// A fill is a Buy for the buyer and a Sell for the seller at the listing's price; List and Cancel rows only
// appear in the seller's history. Kept out of MarketLogs.trades, so the AMM chart and volume stay pool-only.
function toBookTrades(log: BookLog, marketId: number, listings: Map<bigint, OpenListing>): Trade[] {
  const at = new Date(blockTimes.get(log.blockNumber)! * 1000).toISOString()
  const base = { marketId, at, tx: log.transactionHash, venue: 'book' } as const
  const id = log.args.listingId
  if (log.eventName === 'Listed') {
    const outcome = log.args.outcome === OUTCOME_YES ? 'YES' : 'NO'
    const shares = toUnits(log.args.amount)
    const price = toUnits(log.args.price)
    listings.set(id, { marketId, outcome, seller: log.args.seller, price, remaining: shares })
    return [{ ...base, outcome, trader: log.args.seller, side: 'List', shares, amount: shares * price }]
  }
  const listing = listings.get(id)
  if (log.eventName === 'Filled') {
    const outcome = log.args.outcome === OUTCOME_YES ? 'YES' : 'NO'
    const shares = toUnits(log.args.shares)
    if (listing) listing.remaining -= shares
    const fill = { ...base, outcome, shares, amount: toUnits(log.args.cost) } as const
    return [
      { ...fill, trader: log.args.buyer, side: 'Buy' },
      { ...fill, trader: log.args.seller, side: 'Sell' },
    ]
  }
  // Cancelled carries no outcome or price; both come from the listing's Listed event.
  if (!listing) return []
  listing.remaining = 0
  const shares = toUnits(log.args.returned)
  return [{ ...base, outcome: listing.outcome, trader: log.args.seller, side: 'Cancel', shares, amount: shares * listing.price }]
}

function toTrade(log: TradeLog, marketId: number): Trade {
  const outcome = log.args.outcome === OUTCOME_YES ? 'YES' : 'NO'
  const at = new Date(blockTimes.get(log.blockNumber)! * 1000).toISOString()
  const base = { marketId, trader: log.args.trader, outcome, at, tx: log.transactionHash } as const
  return log.eventName === 'Bought'
    ? { ...base, side: 'Buy', amount: toUnits(log.args.collateralIn), shares: toUnits(log.args.sharesOut) }
    : { ...base, side: 'Sell', amount: toUnits(log.args.collateralOut), shares: toUnits(log.args.sharesIn) }
}
