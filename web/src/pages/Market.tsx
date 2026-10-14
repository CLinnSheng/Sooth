import { ArrowLeft, ArrowUpRight, ChevronDown } from 'lucide-react'
import { useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router'
import { Change, PriceChart, StatusBadge, TradePanel } from '../components'
import { useWallet } from '../wallet'
import {
  MARKET_ADDRESS,
  basescanAddr,
  basescanTx,
  cents,
  change30d,
  compact,
  date,
  marketById,
  pct,
  positionValue,
  positions,
  priceOf,
  priceYes,
  shortAddr,
  signed,
  trades,
  usdc,
  type Outcome,
} from '../mock'

const ranges = { '1W': 7, '1M': 30, All: 90 }

export default function Market() {
  const { id } = useParams()
  const [params] = useSearchParams()
  const { wallet } = useWallet()
  const market = marketById(Number(id))
  const [outcome, setOutcome] = useState<Outcome>(params.get('outcome') === 'NO' ? 'NO' : 'YES')
  const [range, setRange] = useState<keyof typeof ranges>('1M')

  if (!market)
    return (
      <p className="text-zinc-500">
        Market not found. <Link to="/" className="text-zinc-900 underline">Back to Explore</Link>
      </p>
    )

  const p = priceYes(market)
  const mine = wallet ? positions.filter((x) => x.marketId === market.id) : []
  const held = mine.find((x) => x.outcome === outcome)?.shares ?? 0
  const activity = trades.filter((t) => t.marketId === market.id)
  const liquidity = Math.sqrt(market.yesReserve * market.noReserve)

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_360px]">
      <section className="flex flex-col gap-6">
        <div className="flex flex-col gap-3">
          <Link to="/" className="flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-900">
            <ArrowLeft size={14} /> Explore / {market.category}
          </Link>
          <div><StatusBadge market={market} /></div>
          <h1 className="text-2xl font-semibold tracking-tight md:text-3xl">{market.question}</h1>
          <p className="text-sm text-zinc-500">
            {market.status === 'resolved' ? 'Closed' : 'Closes'} {date(market.closesAt)} · Source: {market.source.label}
          </p>
        </div>

        <div className="flex flex-col gap-3 rounded-2xl border border-zinc-200 bg-white p-5">
          <div className="flex items-baseline gap-2">
            <span className="text-4xl font-semibold tracking-tight text-yes">{pct(p)}</span>
            <span className="text-sm text-zinc-500">chance of YES</span>
            <span className="ml-auto"><Change value={change30d(market)} /></span>
          </div>
          <div className="flex justify-end gap-1 text-xs">
            {(Object.keys(ranges) as (keyof typeof ranges)[]).map((r) => (
              <button
                key={r}
                aria-pressed={range === r}
                onClick={() => setRange(r)}
                className={`rounded px-2 py-0.5 ${range === r ? 'bg-zinc-900 text-white' : 'text-zinc-500 hover:bg-zinc-100'}`}
              >
                {r}
              </button>
            ))}
          </div>
          <PriceChart points={market.history.slice(-ranges[range])} height={200} axis />
          <div className="flex justify-between text-xs text-zinc-400">
            <span>{ranges[range]} days ago</span>
            <span>Today</span>
          </div>
          <div className="grid grid-cols-2 border-t border-zinc-100 pt-3 text-sm">
            <div><p className="text-xs text-zinc-500">Volume</p>{compact(market.volume)} USDC</div>
            <div><p className="text-xs text-zinc-500">Liquidity</p>{compact(liquidity)} USDC</div>
          </div>
        </div>
      </section>

      <aside className="lg:sticky lg:top-20 lg:col-start-2 lg:row-span-2 lg:row-start-1 lg:self-start">
        <TradePanel market={market} outcome={outcome} setOutcome={setOutcome} held={held} />
      </aside>

      <section className="flex flex-col gap-6 lg:col-start-1">
        {mine.length > 0 && (
          <div className="flex flex-col gap-3 rounded-2xl border border-zinc-200 bg-white p-5">
            <h2 className="font-semibold">Your position</h2>
            {mine.map((pos) => {
              const value = positionValue(pos)
              const pnl = value - pos.shares * pos.avgPrice
              return (
                <div key={pos.outcome} className="grid grid-cols-2 gap-y-1 text-sm sm:grid-cols-4">
                  <div><p className="text-xs text-zinc-500">Shares</p>{pos.shares} {pos.outcome}</div>
                  <div><p className="text-xs text-zinc-500">Avg / now</p>{cents(pos.avgPrice)} / {cents(priceOf(market, pos.outcome))}</div>
                  <div><p className="text-xs text-zinc-500">Value</p>{usdc(value)} USDC</div>
                  <div>
                    <p className="text-xs text-zinc-500">PnL</p>
                    <span className={pnl >= 0 ? 'text-yes' : 'text-no'}>
                      {signed(pnl)} ({((pnl / (pos.shares * pos.avgPrice)) * 100).toFixed(1)}%)
                    </span>
                  </div>
                </div>
              )
            })}
          </div>
        )}

        <details open className="group rounded-2xl border border-zinc-200 bg-white p-5">
          <summary className="flex cursor-pointer list-none items-center justify-between font-semibold">
            Resolution rules <ChevronDown size={16} className="transition group-open:rotate-180" />
          </summary>
          <div className="mt-3 flex flex-col gap-3 text-sm text-zinc-600">
            <p>{market.rules}</p>
            <a href={market.source.url} target="_blank" rel="noreferrer" className="flex w-fit items-center gap-1 font-medium text-zinc-900 hover:underline">
              {market.source.label} <ArrowUpRight size={14} />
            </a>
            <a href={basescanAddr(MARKET_ADDRESS)} target="_blank" rel="noreferrer" className="flex w-fit items-center gap-1 text-zinc-500 hover:underline">
              Market contract {shortAddr(MARKET_ADDRESS)} on Basescan <ArrowUpRight size={14} />
            </a>
          </div>
        </details>

        <div className="flex flex-col gap-3 rounded-2xl border border-zinc-200 bg-white p-5">
          <h2 className="font-semibold">Recent activity</h2>
          {activity.length ? (
            <ul className="divide-y divide-zinc-100 text-sm">
              {activity.map((t) => (
                <li key={t.tx} className="flex items-center gap-3 py-2">
                  <span className="w-28 text-zinc-500">{shortAddr(t.trader)}</span>
                  <span className={t.outcome === 'YES' ? 'text-yes' : 'text-no'}>{t.side} {t.outcome}</span>
                  <span className="ml-auto">{usdc(t.amount)} USDC</span>
                  <span className="hidden w-24 text-right text-zinc-500 sm:block">{date(t.at)}</span>
                  <a href={basescanTx(t.tx)} target="_blank" rel="noreferrer" aria-label="View transaction" className="text-zinc-400 hover:text-zinc-900">
                    <ArrowUpRight size={14} />
                  </a>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-zinc-500">No trades yet.</p>
          )}
        </div>
      </section>
    </div>
  )
}
