import { ArrowLeft, ArrowUpRight, ChevronDown } from 'lucide-react'
import { useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router'
import { useAccount } from 'wagmi'
import { useDashboardMarkets, useMarkets, usePositions } from '../chain'
import { Change, ClaimButton, PAGE_SIZE, PriceChart, ProbabilityBar, ShowMore, StatusBadge, TradePanel } from '../components'
import { ResolutionPanel } from '../resolution'
import {
  ago,
  basescanAddr,
  basescanTx,
  cents,
  DAY_SECS,
  changeSince,
  compact,
  date,
  dateTime,
  isSettled,
  pct,
  poolPayout,
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
  // Same split as Home: the summary (price, volume, question, status) renders
  // first, and the full load (history, past trades, positions, resolution)
  // only starts after it. The old code waited for the full load before
  // rendering anything, so a direct landing on /market/:id took as long as
  // the dashboard did, even though this page only needs one market.
  const summary = useDashboardMarkets()
  const full = useMarkets(Boolean(summary.data))
  const { address } = useAccount()
  const positions = usePositions(address)
  const [outcome, setOutcome] = useState<Outcome>(params.get('outcome') === 'NO' ? 'NO' : 'YES')
  const [range, setRange] = useState<keyof typeof ranges>('1M')
  const [activityShown, setActivityShown] = useState(PAGE_SIZE)

  const markets = full.data?.markets ?? summary.data?.markets
  if (!markets) return <p className="text-muted">{summary.error ? 'Could not load market from Base Sepolia.' : 'Loading market…'}</p>

  const market = markets.find((m) => m.id === Number(id))
  if (!market)
    return (
      <p className="text-muted">
        Market not found. <Link to="/" className="text-white underline">Back to Explore</Link>
      </p>
    )

  const p = priceYes(market)
  const mine = positions.filter((pos) => pos.marketId === market.id)
  const payout = mine.reduce((sum, pos) => sum + positionValue(pos, market), 0)
  const canWithdrawLiquidity =
    isSettled(market) && !market.liquidityWithdrawn && address?.toLowerCase() === market.creator.toLowerCase()
  // Past trades (and positions, via usePositions) only exist in the full
  // load. Showing an empty activity list before then would wrongly read as
  // "no trades yet", so activity stays in its loading state until full lands.
  const activity = (full.data?.trades ?? []).filter((t) => t.marketId === market.id).toReversed()
  const detailsPending = !full.data
  const liquidity = Math.sqrt(market.yesReserve * market.noReserve)
  // The last history point is stamped when markets load, so the page and chart share one clock.
  const now = market.history.at(-1)!.at
  const age = now - market.history[0].at
  // A range at least as long as the market's life would just repeat All.
  const available = (Object.keys(ranges) as (keyof typeof ranges)[]).filter((r) => ranges[r] < age || r === 'All')
  const shownRange = available.includes(range) ? range : 'All'
  const from = Math.max(market.history[0].at, now - ranges[shownRange])

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
            <span className="ml-auto">{detailsPending ? <span className="text-sm text-muted">…</span> : <Change value={changeSince(market, now - from)} />}</span>
          </div>
          <ProbabilityBar p={p} />
          {available.length > 1 && (
            <div className="flex justify-end gap-1 text-xs">
              {available.map((r) => (
                <button
                  key={r}
                  aria-pressed={shownRange === r}
                  onClick={() => setRange(r)}
                  className={`rounded-full px-2.5 py-0.5 font-medium ${shownRange === r ? 'bg-white text-black' : 'text-muted hover:bg-raised'}`}
                >
                  {r}
                </button>
              ))}
            </div>
          )}
          {detailsPending ? (
            <p className="text-sm text-muted">Loading price history…</p>
          ) : (
            <>
              <PriceChart points={market.history} from={from} to={now} height={200} axis />
              <div className="flex justify-between text-xs text-muted">
                <span>{dateTime(from)}</span>
                <span>Now</span>
              </div>
            </>
          )}
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
            {isSettled(market) && payout > 0 && (
              <div className="flex justify-end"><ClaimButton market={market} claim="redeem" payout={payout} /></div>
            )}
          </div>
        )}

        {canWithdrawLiquidity && (
          <div className="flex items-center justify-between gap-4 rounded-3xl bg-surface p-5">
            <div>
              <h2 className="font-semibold">Your liquidity</h2>
              <p className="text-sm text-muted">You seeded this market's pool; its shares pay out like any position.</p>
            </div>
            <ClaimButton market={market} claim="withdrawLiquidity" payout={poolPayout(market)} />
          </div>
        )}

        {detailsPending ? (
          <div className="flex flex-col gap-3 rounded-3xl bg-surface p-5">
            <h2 className="font-semibold">Resolution</h2>
            <p className="text-sm text-muted">Loading resolution…</p>
          </div>
        ) : (
          <ResolutionPanel market={market} now={now} />
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
          {detailsPending ? (
            <p className="text-sm text-muted">Loading past trades…</p>
          ) : activity.length ? (
            <ul className="divide-y divide-line text-sm">
              {activity.slice(0, activityShown).map((t, i) => (
                // Fixed grid columns and tabular digits keep every row's numbers lined up.
                <li
                  key={`${t.tx}-${i}`}
                  className="grid grid-cols-[6.5rem_4.5rem_1fr_4.5rem_1rem] items-center gap-3 whitespace-nowrap py-2 tabular-nums sm:grid-cols-[6.5rem_4.5rem_4.5rem_3.5rem_1fr_4.5rem_1rem]"
                >
                  <Link to={`/portfolio/${t.trader}`} className="text-muted hover:text-white hover:underline">
                    {shortAddr(t.trader)}
                  </Link>
                  <span className={t.outcome === 'YES' ? 'text-yes' : 'text-no'}>{t.side} {t.outcome}</span>
                  <span className="hidden text-right text-muted sm:block">{usdc(t.shares)}</span>
                  <span className="hidden text-muted sm:block">@ {cents(t.amount / t.shares)}</span>
                  <span className="text-right">{usdc(t.amount)} USDC</span>
                  <span className="text-right text-muted" title={new Date(t.at).toLocaleString()}>{ago(t.at)}</span>
                  <a href={basescanTx(t.tx)} target="_blank" rel="noreferrer" aria-label="View transaction" className="text-muted hover:text-white">
                    <ArrowUpRight size={14} />
                  </a>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted">No trades yet.</p>
          )}
          <ShowMore shown={activityShown} total={activity.length} onClick={() => setActivityShown((n) => n + PAGE_SIZE)} />
        </div>
      </section>
    </div>
  )
}
