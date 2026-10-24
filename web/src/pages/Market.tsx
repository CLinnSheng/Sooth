import { ArrowLeft, ArrowUpRight, ChevronDown } from 'lucide-react'
import { useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router'
import { useAccount } from 'wagmi'
import { useMarkets, usePositions } from '../chain'
import { Change, PriceChart, ProbabilityBar, StatusBadge, TradePanel } from '../components'
import {
  basescanAddr,
  basescanTx,
  cents,
  DAY_SECS,
  changeSince,
  compact,
  date,
  dateTime,
  pct,
  positionValue,
  priceOf,
  priceYes,
  shortAddr,
  signed,
  usdc,
  type Outcome,
} from '../mock'

const ranges = { '1D': DAY_SECS, '1W': 7 * DAY_SECS, '1M': 30 * DAY_SECS, All: Infinity }

export default function Market() {
  const { id } = useParams()
  const [params] = useSearchParams()
  const { data, error } = useMarkets()
  const { address } = useAccount()
  const positions = usePositions(address)
  const [outcome, setOutcome] = useState<Outcome>(params.get('outcome') === 'NO' ? 'NO' : 'YES')
  const [range, setRange] = useState<keyof typeof ranges>('1M')

  if (!data) return <p className="text-muted">{error ? 'Could not load market from Base Sepolia.' : 'Loading market…'}</p>

  const market = data.markets.find((m) => m.id === Number(id))
  if (!market)
    return (
      <p className="text-muted">
        Market not found. <Link to="/" className="text-white underline">Back to Explore</Link>
      </p>
    )

  const p = priceYes(market)
  const mine = positions.filter((pos) => pos.marketId === market.id)
  const activity = data.trades.filter((t) => t.marketId === market.id).toReversed()
  const liquidity = Math.sqrt(market.yesReserve * market.noReserve)
  const now = Date.now() / 1000
  // A range longer than the market's life starts at creation.
  const from = Math.max(market.history[0].at, now - ranges[range])

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_360px]">
      <section className="flex flex-col gap-6">
        <div className="flex flex-col gap-3">
          <Link to="/" className="flex items-center gap-1 text-sm text-muted hover:text-white">
            <ArrowLeft size={14} /> Explore{market.category && ` / ${market.category}`}
          </Link>
          <div><StatusBadge market={market} /></div>
          <h1 className="text-3xl font-bold tracking-tight md:text-4xl">{market.question}</h1>
          <p className="text-sm text-muted">
            {market.status === 'open' ? 'Closes' : 'Closed'} {date(market.closesAt)}
            {market.source && ` · Source: ${market.source.label}`}
          </p>
        </div>

        <div className="flex flex-col gap-3 rounded-3xl bg-surface p-6">
          <div className="flex items-baseline gap-2">
            <span className="text-6xl font-extrabold leading-none tracking-tighter text-yes">{pct(p)}</span>
            <span className="text-sm text-muted">chance of Yes</span>
            <span className="ml-auto"><Change value={changeSince(market, now - from)} /></span>
          </div>
          <ProbabilityBar p={p} />
          <div className="flex justify-end gap-1 text-xs">
            {(Object.keys(ranges) as (keyof typeof ranges)[]).map((r) => (
              <button
                key={r}
                aria-pressed={range === r}
                onClick={() => setRange(r)}
                className={`rounded-full px-2.5 py-0.5 font-medium ${range === r ? 'bg-white text-black' : 'text-muted hover:bg-raised'}`}
              >
                {r}
              </button>
            ))}
          </div>
          <PriceChart points={market.history} from={from} to={now} height={200} axis />
          <div className="flex justify-between text-xs text-muted">
            <span>{dateTime(from)}</span>
            <span>Now</span>
          </div>
          <div className="grid grid-cols-2 border-t border-line pt-3 text-sm">
            <div><p className="text-xs text-muted">Volume</p>{compact(market.volume)} USDC</div>
            <div><p className="text-xs text-muted">Liquidity</p>{compact(liquidity)} USDC</div>
          </div>
        </div>
      </section>

      <aside className="lg:sticky lg:top-20 lg:col-start-2 lg:row-span-2 lg:row-start-1 lg:self-start">
        <TradePanel market={market} outcome={outcome} setOutcome={setOutcome} />
      </aside>

      <section className="flex flex-col gap-6 lg:col-start-1">
        {mine.length > 0 && (
          <div className="flex flex-col gap-3 rounded-3xl bg-surface p-5">
            <h2 className="font-semibold">Your position</h2>
            {mine.map((pos) => {
              const value = positionValue(pos, market)
              const pnl = value - pos.shares * pos.avgPrice
              return (
                <div key={pos.outcome} className="grid grid-cols-2 gap-y-1 text-sm sm:grid-cols-4">
                  <div><p className="text-xs text-muted">Shares</p>{pos.shares} {pos.outcome}</div>
                  <div><p className="text-xs text-muted">Avg / now</p>{cents(pos.avgPrice)} / {cents(priceOf(market, pos.outcome))}</div>
                  <div><p className="text-xs text-muted">Value</p>{usdc(value)} USDC</div>
                  <div>
                    <p className="text-xs text-muted">PnL</p>
                    <span className={pnl >= 0 ? 'text-yes' : 'text-no'}>
                      {signed(pnl)} ({((pnl / (pos.shares * pos.avgPrice)) * 100).toFixed(1)}%)
                    </span>
                  </div>
                </div>
              )
            })}
          </div>
        )}

        <details open className="group rounded-3xl bg-surface p-5">
          <summary className="flex cursor-pointer list-none items-center justify-between font-semibold">
            Resolution rules <ChevronDown size={16} className="transition group-open:rotate-180" />
          </summary>
          <div className="mt-3 flex flex-col gap-3 text-sm text-zinc-300">
            <p>{market.rules}</p>
            {market.source && (
              <a href={market.source.url} target="_blank" rel="noreferrer" className="flex w-fit items-center gap-1 font-medium text-white hover:underline">
                {market.source.label} <ArrowUpRight size={14} />
              </a>
            )}
            <a href={basescanAddr(market.address)} target="_blank" rel="noreferrer" className="flex w-fit items-center gap-1 text-muted hover:underline">
              Market contract {shortAddr(market.address)} on Basescan <ArrowUpRight size={14} />
            </a>
          </div>
        </details>

        <div className="flex flex-col gap-3 rounded-3xl bg-surface p-5">
          <h2 className="font-semibold">Recent activity</h2>
          {activity.length ? (
            <ul className="divide-y divide-line text-sm">
              {activity.map((t) => (
                <li key={t.tx} className="flex items-center gap-3 py-2">
                  <span className="w-28 text-muted">{shortAddr(t.trader)}</span>
                  <span className={t.outcome === 'YES' ? 'text-yes' : 'text-no'}>{t.side} {t.outcome}</span>
                  <span className="ml-auto">{usdc(t.amount)} USDC</span>
                  <span className="hidden w-24 text-right text-muted sm:block">{date(t.at)}</span>
                  <a href={basescanTx(t.tx)} target="_blank" rel="noreferrer" aria-label="View transaction" className="text-muted hover:text-white">
                    <ArrowUpRight size={14} />
                  </a>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted">No trades yet.</p>
          )}
        </div>
      </section>
    </div>
  )
}
