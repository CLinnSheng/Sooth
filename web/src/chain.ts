import { useQuery } from '@tanstack/react-query'
import {
  encodeAbiParameters,
  formatUnits,
  getAbiItem,
  type GetLogsReturnType,
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
  OUTCOME_TOKEN,
  chainlinkResolverAbi,
  factoryAbi,
  marketAbi,
  optimisticResolverAbi,
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

// publicnode caps eth_getLogs at 50k blocks, about 1.2 days of Base blocks.
const MAX_LOG_RANGE = 50_000n
// A failing 50k range is retried, then split in half, down to this size. Splitting
// further would only help an RPC that caps ranges far below 50k, at the cost of
// thousands of requests, so a range this small failing is treated as a real outage.
const MIN_LOG_RANGE = 10_000n
// The old scan fired every 50k chunk at once; a burst like that is what gets
// throttled. Dashboard and full scans now run at most this many chunks in parallel.
const LOG_CONCURRENCY = 3
const BLOCK_TIME_CONCURRENCY = 20
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))
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

// Everything the dashboard card needs from logs: the spec (question/category)
// and the trades that make up volume. Prices come from the pool reads, not logs,
// and block timestamps are not needed for volume at all.
const dashboardEvents = [
  getAbiItem({ abi: factoryAbi, name: 'MarketCreated' }),
  getAbiItem({ abi: marketAbi, name: 'Bought' }),
  getAbiItem({ abi: marketAbi, name: 'Sold' }),
]
// Everything else the market, portfolio and collect pages need: resolution,
// payouts, redemptions and past trades with timestamps. This is loaded after
// the dashboard is already visible, never before it.
const otherEvents = [
  getAbiItem({ abi: marketAbi, name: 'FeesWithdrawn' }),
  getAbiItem({ abi: marketAbi, name: 'LiquidityWithdrawn' }),
  getAbiItem({ abi: marketAbi, name: 'Redeemed' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Proposed' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Disputed' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Finalized' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Ruled' }),
  getAbiItem({ abi: optimisticResolverAbi, name: 'Refunded' }),
  getAbiItem({ abi: chainlinkResolverAbi, name: 'PriceResolved' }),
]
const soothEvents = [...dashboardEvents, ...otherEvents]

type Spec = Pick<Market, 'question' | 'category' | 'rules' | 'source'>
type MarketState = Awaited<ReturnType<typeof readMarket>>
// Derived directly from viem's getLogs return type, not from scanLogs:
// deriving it from scanLogs made SoothLog circularly reference itself once
// scanLogs/fetchLogsRange were annotated with SoothLog, which collapsed
// every log arg to a broken type (bigint errors, any event names).
type SoothLog = GetLogsReturnType<undefined, typeof soothEvents, true>[number]
type CreatedLog = Extract<SoothLog, { eventName: 'MarketCreated' }>
type TradeLog = Extract<SoothLog, { eventName: 'Bought' | 'Sold' }>
type PriceLog = Extract<SoothLog, { eventName: 'PriceResolved' }>
type PayoutLog = Extract<SoothLog, { eventName: 'FeesWithdrawn' | 'LiquidityWithdrawn' }>
type RedeemLog = Extract<SoothLog, { eventName: 'Redeemed' }>
type ResolverLog = Exclude<SoothLog, CreatedLog | TradeLog | PriceLog | PayoutLog | RedeemLog>
// Everything the scan found for one market, besides its MarketCreated.
type MarketLogs = { trades: TradeLog[]; request: ResolverLog[]; price?: PriceLog; payouts: PayoutLog[] }

// Outcome shares use the collateral's 6 decimals.
const toUnits = (raw: bigint) => Number(formatUnits(raw, 6))

// Logs are scanned in the browser, one getLogs call per 50k blocks since deploy,
// and logs from a reorg stay cached until reload. Move to an indexer (Ponder)
// once first load gets slow. The two scans are kept separate on purpose: the
// dashboard scan is small and must not wait for, or fail because of, the full
// scan, and the full scan must not re-scan the dashboard range twice in one tick.
type ScanCache = { toBlock: bigint; logs: SoothLog[] }
const dashboardScan: ScanCache = { toBlock: DEPLOY_BLOCK - 1n, logs: [] }
const fullScan: ScanCache = { toBlock: DEPLOY_BLOCK - 1n, logs: [] }
const blockTimes = new Map<bigint, number>()

// Full market data: prices, volume, history, resolution, payouts, past trades
// and (via usePositions) user positions. Loaded in the background on the
// dashboard, and directly on the market/portfolio/collect pages.
export function useMarkets(enabled = true) {
  return useQuery({ queryKey: ['markets'], queryFn: loadMarkets, refetchInterval: REFETCH_MS, enabled })
}

// Stage 0 for the dashboard: markets from contract reads only, no log scan
// at all. Prices, status, close time and liquidity are correct immediately;
// question is a placeholder and volume is 0 until the summary scan fills
// them in. This is what makes the dashboard appear on entry even when the
// log scan itself is slow or throttled.
export function useMarketList() {
  return useQuery({ queryKey: ['markets', 'list'], queryFn: loadMarketList, refetchInterval: REFETCH_MS })
}

// Dashboard-first data: prices from pool reads, plus question/category/volume
// from the small dashboard log scan. No block timestamps, no resolver/payout
// logs, no positions. This is what Home renders, so a slow or failing full
// scan can no longer turn the whole dashboard into "Could not load markets".
export function useDashboardMarkets(enabled = true) {
  return useQuery({ queryKey: ['markets', 'summary'], queryFn: loadMarketSummaries, refetchInterval: REFETCH_MS, enabled })
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
  return keys.flatMap((key, i) => {
    if (balances[i] === 0n) return []
    const buys = data.trades.filter(
      (t) => t.marketId === key.marketId && t.outcome === key.outcome && t.side === 'Buy' && t.trader.toLowerCase() === owner.toLowerCase(),
    )
    const cost = buys.reduce((sum, t) => sum + t.amount, 0)
    const bought = buys.reduce((sum, t) => sum + t.shares, 0)
    // Average cost over every buy; sells don't move it, so PnL is the gain on what's still held.
    return [{ ...key, shares: toUnits(balances[i]), avgPrice: bought > 0 ? cost / bought : 0 }]
  })
}

async function loadMarketStates(blockNumber: bigint) {
  const count = await client.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'marketCount', blockNumber })
  const addresses = await Promise.all(
    Array.from({ length: Number(count) }, (_, i) =>
      client.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'markets', args: [BigInt(i + 1)], blockNumber }),
    ),
  )
  const states = await Promise.all(addresses.map((address) => readMarket(address, blockNumber)))
  return { addresses, states }
}

async function loadMarketList(): Promise<{ markets: Market[] }> {
  const blockNumber = await client.getBlockNumber()
  const { states } = await loadMarketStates(blockNumber)
  return { markets: states.map((state, i) => toMarketSummary(i + 1, state, undefined, [])) }
}

async function loadMarketSummaries(): Promise<{ markets: Market[]; logScanFailed: boolean }> {
  // Pin every read to one block, so state and logs describe the same moment.
  const blockNumber = await client.getBlockNumber()
  const { addresses, states } = await loadMarketStates(blockNumber)
  // If the log scan fails, still show the markets: prices come from the pool
  // reads above, and the next refetch retries the scan (toBlock only advances
  // on success, so a failed range is not skipped). Volume/question then fill
  // in instead of the whole dashboard erroring out.
  let logScanFailed = false
  try {
    await extendScan(dashboardScan, [FACTORY, ...addresses], dashboardEvents, blockNumber)
  } catch (error) {
    console.warn('Dashboard log scan failed; showing markets from contract reads only', error)
    logScanFailed = true
  }

  const idByAddress = new Map(addresses.map((address, i) => [address.toLowerCase(), i + 1]))
  const created = new Map<number, CreatedLog>()
  const tradeLogs: TradeLog[] = []
  for (const log of dashboardScan.logs) {
    if (log.eventName === 'MarketCreated') created.set(Number(log.args.marketId), log)
    else if (log.eventName === 'Bought' || log.eventName === 'Sold') tradeLogs.push(log)
  }
  const markets = states.map((state, i) => {
    const id = i + 1
    const createdLog = created.get(id)
    const emittedHere = (log: SoothLog) => idByAddress.get(log.address.toLowerCase()) === id
    return toMarketSummary(id, state, createdLog, tradeLogs.filter(emittedHere))
  })
  return { markets, logScanFailed }
}

function toMarketSummary(id: number, state: MarketState, created: CreatedLog | undefined, trades: TradeLog[]): Market {
  const yesReserve = toUnits(state.yesPool)
  const noReserve = toUnits(state.noPool)
  const volume = trades.reduce((sum, log) => sum + (log.eventName === 'Bought' ? log.args.collateralIn : log.args.collateralOut), 0n)
  const price = yesReserve + noReserve > 0 ? noReserve / (yesReserve + noReserve) : OPENING_PRICE
  const spec = created ? parseSpec(created.args.spec) : null
  return {
    id,
    address: state.address,
    creator: created?.args.creator ?? zeroAddress,
    arbitrator: created?.args.arbitrator ?? zeroAddress,
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
    // Filled in by the full load, after the dashboard is visible.
    request: undefined,
    priceResolution: undefined,
    collected: { fees: 0, liquidity: 0 },
    yesReserve,
    noReserve,
    volume: toUnits(volume),
    // History (and the 30-day change derived from it) also comes from the
    // full load. Until then a single current-price point makes changeSince 0
    // instead of crashing on a missing history.
    history: [{ at: Date.now() / 1000, price }],
  }
}

async function loadMarkets(): Promise<{ markets: Market[]; trades: Trade[]; redemptions: Redemption[] }> {
  // Pin every read to one block, so state and logs describe the same moment.
  const blockNumber = await client.getBlockNumber()
  const { addresses, states } = await loadMarketStates(blockNumber)
  await extendScan(fullScan, [FACTORY, OPTIMISTIC_RESOLVER, CHAINLINK_RESOLVER, ...addresses], soothEvents, blockNumber)
  await cacheBlockTimes(fullScan.logs)

  const idByAddress = new Map(addresses.map((address, i) => [address.toLowerCase(), i + 1]))
  const created = new Map<number, CreatedLog>()
  const tradeLogs: TradeLog[] = []
  const resolverLogs: ResolverLog[] = []
  const priceLogs: PriceLog[] = []
  const payoutLogs: PayoutLog[] = []
  const redeemLogs: RedeemLog[] = []
  for (const log of fullScan.logs) {
    if (log.eventName === 'MarketCreated') created.set(Number(log.args.marketId), log)
    else if (log.eventName === 'Bought' || log.eventName === 'Sold') tradeLogs.push(log)
    else if (log.eventName === 'PriceResolved') priceLogs.push(log)
    else if (log.eventName === 'FeesWithdrawn' || log.eventName === 'LiquidityWithdrawn') payoutLogs.push(log)
    else if (log.eventName === 'Redeemed') redeemLogs.push(log)
    else resolverLogs.push(log)
  }

  const markets = states.map((state, i) => {
    const id = i + 1
    const createdLog = created.get(id)
    // A missing MarketCreated log used to throw here and turn the whole
    // dashboard into "Could not load markets". The market still exists on
    // chain, so show it with a placeholder spec instead; its trades, pools
    // and status are all read independently of that log.
    const emittedHere = (log: SoothLog) => idByAddress.get(log.address.toLowerCase()) === id
    // Resolver events name the market in an argument; the log's own address is the resolver.
    const aboutHere = (log: ResolverLog | PriceLog) => log.args.market.toLowerCase() === state.address.toLowerCase()
    const logs: MarketLogs = {
      trades: tradeLogs.filter(emittedHere),
      request: resolverLogs.filter(aboutHere),
      price: priceLogs.find(aboutHere),
      payouts: payoutLogs.filter(emittedHere),
    }
    return toMarket(id, state, createdLog, logs, createdLog ? parseSpec(createdLog.args.spec) : null)
  })
  const trades = tradeLogs.map((log) => toTrade(log, idByAddress.get(log.address.toLowerCase())!))
  const redemptions = redeemLogs.map((log) => ({
    marketId: idByAddress.get(log.address.toLowerCase())!,
    holder: log.args.holder,
    payout: toUnits(log.args.payout),
  }))
  return { markets, trades, redemptions }
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
// so scanning old ranges without its address loses nothing. toBlock only
// advances on success, so a failed scan is retried on the next refetch
// instead of silently skipping those blocks.
async function extendScan(cache: ScanCache, addresses: Address[], events: typeof soothEvents, toBlock: bigint) {
  if (toBlock <= cache.toBlock) return
  const logs = await scanLogs(addresses, events, cache.toBlock + 1n, toBlock)
  cache.logs.push(...logs)
  cache.toBlock = toBlock
}

async function scanLogs(addresses: Address[], events: typeof soothEvents, fromBlock: bigint, toBlock: bigint) {
  const ranges: [bigint, bigint][] = []
  for (let start = fromBlock; start <= toBlock; start += MAX_LOG_RANGE) {
    const end = start + MAX_LOG_RANGE - 1n
    ranges.push([start, end < toBlock ? end : toBlock])
  }
  const results: SoothLog[][] = []
  for (let i = 0; i < ranges.length; i += LOG_CONCURRENCY) {
    const batch = ranges.slice(i, i + LOG_CONCURRENCY)
    const logs = await Promise.all(batch.map(([start, end]) => fetchLogsRange(addresses, events, start, end)))
    results.push(...logs)
  }
  return results.flat()
}

// One getLogs range, retried, then split in half on persistent failure. A
// timeout or rate limit on a 50k range should not fail the whole dashboard
// scan when a smaller range would succeed.
async function fetchLogsRange(
  addresses: Address[],
  events: typeof soothEvents,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<SoothLog[]> {
  let lastError: unknown
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return await client.getLogs({ address: addresses, events, fromBlock, toBlock, strict: true })
    } catch (error) {
      lastError = error
      await sleep(500 * (attempt + 1))
    }
  }
  if (toBlock - fromBlock + 1n > MIN_LOG_RANGE) {
    const mid = (fromBlock + toBlock) / 2n
    const first = await fetchLogsRange(addresses, events, fromBlock, mid)
    const second = await fetchLogsRange(addresses, events, mid + 1n, toBlock)
    return [...first, ...second]
  }
  throw lastError
}

async function cacheBlockTimes(logs: SoothLog[]) {
  const missing = [...new Set(logs.map((log) => log.blockNumber))].filter((b) => !blockTimes.has(b))
  // The old code fired one getBlock per distinct log block all at once, the
  // same burst pattern as the log scan. Fetch in bounded batches instead.
  for (let i = 0; i < missing.length; i += BLOCK_TIME_CONCURRENCY) {
    const batch = missing.slice(i, i + BLOCK_TIME_CONCURRENCY)
    const blocks = await Promise.all(
      batch.map(async (blockNumber) => {
        let lastError: unknown
        for (let attempt = 0; attempt < 3; attempt++) {
          try {
            return await client.getBlock({ blockNumber })
          } catch (error) {
            lastError = error
            await sleep(500 * (attempt + 1))
          }
        }
        throw lastError
      }),
    )
    for (const block of blocks) blockTimes.set(block.number, Number(block.timestamp))
  }
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

function toMarket(id: number, state: MarketState, created: CreatedLog | undefined, logs: MarketLogs, spec: Spec | null): Market {
  const yesReserve = toUnits(state.yesPool)
  const noReserve = toUnits(state.noPool)
  const volume = logs.trades.reduce((sum, log) => sum + (log.eventName === 'Bought' ? log.args.collateralIn : log.args.collateralOut), 0n)
  const poolPrice = yesReserve + noReserve > 0 ? noReserve / (yesReserve + noReserve) : OPENING_PRICE
  const prices = created ? replayPrices(created.args.initialLiquidity, logs.trades) : []
  const paid = (event: PayoutLog['eventName']) =>
    toUnits(logs.payouts.filter((log) => log.eventName === event).reduce((sum, log) => sum + log.args.amount, 0n))
  return {
    id,
    address: state.address,
    creator: created?.args.creator ?? zeroAddress,
    arbitrator: created?.args.arbitrator ?? zeroAddress,
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
    // Without a MarketCreated log there is no creation block or opening
    // price, so the history is just the live pool price.
    history: created
      ? [
          { at: blockTimes.get(created.blockNumber)!, price: OPENING_PRICE },
          ...prices,
          { at: Date.now() / 1000, price: poolPrice },
        ]
      : [{ at: Date.now() / 1000, price: poolPrice }],
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

function toTrade(log: TradeLog, marketId: number): Trade {
  const outcome = log.args.outcome === OUTCOME_YES ? 'YES' : 'NO'
  const at = new Date(blockTimes.get(log.blockNumber)! * 1000).toISOString()
  const base = { marketId, trader: log.args.trader, outcome, at, tx: log.transactionHash } as const
  return log.eventName === 'Bought'
    ? { ...base, side: 'Buy', amount: toUnits(log.args.collateralIn), shares: toUnits(log.args.sharesOut) }
    : { ...base, side: 'Sell', amount: toUnits(log.args.collateralOut), shares: toUnits(log.args.sharesIn) }
}
