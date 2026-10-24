import { useQuery } from '@tanstack/react-query'
import { formatUnits, getAbiItem, keccak256, type Address, type Hex } from 'viem'
import { getPublicClient } from 'wagmi/actions'
import { baseSepolia } from 'wagmi/chains'
import { DEPLOY_BLOCK, FACTORY, factoryAbi, marketAbi } from './contracts'
import { categories, type Category, type Market, type Trade } from './mock'
import { config } from './wagmi'

const client = getPublicClient(config, { chainId: baseSepolia.id })

// publicnode caps eth_getLogs at 50k blocks, about 1.2 days of Base blocks.
const MAX_LOG_RANGE = 50_000n
const IPFS_GATEWAYS = ['https://ipfs.io/ipfs/', 'https://dweb.link/ipfs/']
const SPEC_TIMEOUT_MS = 8_000
const REFETCH_MS = 30_000
const DAY_SECS = 86_400
const STATE_OPEN = 0
const OUTCOME_YES = 0
// The factory only seeds equal pools, so every market opens at 50/50.
const OPENING_PRICE = 0.5
const UNVERIFIED_RULES =
  'The rules file for this market could not be fetched, or it does not match the hash committed on-chain.'

const soothEvents = [
  getAbiItem({ abi: factoryAbi, name: 'MarketCreated' }),
  getAbiItem({ abi: marketAbi, name: 'Bought' }),
  getAbiItem({ abi: marketAbi, name: 'Sold' }),
]

type Spec = Pick<Market, 'question' | 'category' | 'rules' | 'source'>
type MarketState = Awaited<ReturnType<typeof readMarket>>
type SoothLog = Awaited<ReturnType<typeof scanLogs>>[number]
type CreatedLog = Extract<SoothLog, { eventName: 'MarketCreated' }>
type TradeLog = Extract<SoothLog, { eventName: 'Bought' | 'Sold' }>
type PricePoint = { at: number; price: number }

// Outcome shares use the collateral's 6 decimals.
const toUnits = (raw: bigint) => Number(formatUnits(raw, 6))

// shortcut: logs are scanned in the browser, one getLogs call per 50k blocks since deploy, and logs
// from a reorg stay cached until reload. Move to an indexer (Ponder) once first load gets slow.
const scan: { toBlock: bigint; logs: SoothLog[] } = { toBlock: DEPLOY_BLOCK - 1n, logs: [] }
const blockTimes = new Map<bigint, number>()
// Keyed by specHash, so an entry never goes stale. Failures are cached too, until reload,
// so a dead CID doesn't stall every refetch on gateway timeouts.
const specs = new Map<Hex, Spec | null>()

export function useMarkets() {
  return useQuery({ queryKey: ['markets'], queryFn: loadMarkets, refetchInterval: REFETCH_MS })
}

async function loadMarkets(): Promise<{ markets: Market[]; trades: Trade[] }> {
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
    extendScan([FACTORY, ...addresses], blockNumber),
  ])
  await cacheBlockTimes(scan.logs)

  const idByAddress = new Map(addresses.map((address, i) => [address.toLowerCase(), i + 1]))
  const created = new Map<number, CreatedLog>()
  const tradeLogs: TradeLog[] = []
  for (const log of scan.logs) {
    if (log.eventName === 'MarketCreated') created.set(Number(log.args.marketId), log)
    else tradeLogs.push(log)
  }

  const markets = await Promise.all(
    states.map(async (state, i) => {
      const id = i + 1
      const createdLog = created.get(id)
      if (!createdLog) throw new Error(`MarketCreated log missing for market ${id}`)
      const spec = await fetchSpec(createdLog.args.specCID, state.specHash)
      const logs = tradeLogs.filter((log) => idByAddress.get(log.address.toLowerCase()) === id)
      return toMarket(id, state, createdLog, logs, spec)
    }),
  )
  const trades = tradeLogs.map((log) => toTrade(log, idByAddress.get(log.address.toLowerCase())!))
  return { markets, trades }
}

async function readMarket(address: Address, blockNumber: bigint) {
  const call = { address, abi: marketAbi, blockNumber } as const
  const [yesPool, noPool, closeTime, state, specHash] = await Promise.all([
    client.readContract({ ...call, functionName: 'yesPool' }),
    client.readContract({ ...call, functionName: 'noPool' }),
    client.readContract({ ...call, functionName: 'closeTime' }),
    client.readContract({ ...call, functionName: 'state' }),
    client.readContract({ ...call, functionName: 'specHash' }),
  ])
  return { address, yesPool, noPool, closeTime, state, specHash }
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

async function fetchSpec(cid: string, specHash: Hex): Promise<Spec | null> {
  if (specs.has(specHash)) return specs.get(specHash)!
  let spec: Spec | null = null
  for (const gateway of IPFS_GATEWAYS) {
    try {
      const res = await fetch(gateway + cid, { signal: AbortSignal.timeout(SPEC_TIMEOUT_MS) })
      if (!res.ok) continue
      const bytes = new Uint8Array(await res.arrayBuffer())
      // Gateways are untrusted: only bytes matching the on-chain hash are the committed rules.
      if (keccak256(bytes) !== specHash) continue
      spec = parseSpec(JSON.parse(new TextDecoder().decode(bytes)))
      break
    } catch {
      // Timeout, network error or invalid JSON: try the next gateway.
    }
  }
  specs.set(specHash, spec)
  return spec
}

function parseSpec(raw: unknown): Spec | null {
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

function toMarket(id: number, state: MarketState, created: CreatedLog, logs: TradeLog[], spec: Spec | null): Market {
  const yesReserve = toUnits(state.yesPool)
  const noReserve = toUnits(state.noPool)
  const volume = logs.reduce((sum, log) => sum + (log.eventName === 'Bought' ? log.args.collateralIn : log.args.collateralOut), 0n)
  const prices = replayPrices(created.args.initialLiquidity, logs)
  return {
    id,
    address: state.address,
    question: spec?.question ?? `Market #${id}`,
    category: spec?.category,
    rules: spec?.rules ?? UNVERIFIED_RULES,
    source: spec?.source,
    closesAt: new Date(Number(state.closeTime) * 1000).toISOString(),
    // The contract has no resolution yet, so every state past Open shows as closed.
    status: state.state === STATE_OPEN ? 'open' : 'closed',
    yesReserve,
    noReserve,
    volume: toUnits(volume),
    history: dailyHistory(blockTimes.get(created.blockNumber)!, prices, noReserve / (yesReserve + noReserve)),
  }
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

// One YES price per day since creation, each the last trade price at or before that day's end.
// Ends on the live pool price, so the chart always agrees with the headline number.
function dailyHistory(createdAt: number, prices: PricePoint[], current: number): number[] {
  const days = Math.max(1, Math.ceil((Date.now() / 1000 - createdAt) / DAY_SECS))
  const history = [OPENING_PRICE]
  let price = OPENING_PRICE
  let next = 0
  for (let day = 1; day <= days; day++) {
    const dayEnd = createdAt + day * DAY_SECS
    while (next < prices.length && prices[next].at <= dayEnd) price = prices[next++].price
    history.push(price)
  }
  history[history.length - 1] = current
  return history
}

function toTrade(log: TradeLog, marketId: number): Trade {
  const outcome = log.args.outcome === OUTCOME_YES ? 'YES' : 'NO'
  const at = new Date(blockTimes.get(log.blockNumber)! * 1000).toISOString()
  const base = { marketId, trader: log.args.trader, outcome, at, tx: log.transactionHash } as const
  return log.eventName === 'Bought'
    ? { ...base, side: 'Buy', amount: toUnits(log.args.collateralIn), shares: toUnits(log.args.sharesOut) }
    : { ...base, side: 'Sell', amount: toUnits(log.args.collateralOut), shares: toUnits(log.args.sharesIn) }
}
