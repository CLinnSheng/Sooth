import { Search, SearchX } from 'lucide-react'
import { useState } from 'react'
import { useNavigate } from 'react-router'
import { useDashboardMarkets, useMarketList, useMarkets } from '../chain'
import { MarketCard } from '../components'
import { categories, type Category, type Market, type Outcome } from '../mock'

const categoryFilters: ('All' | Category)[] = ['All', ...categories]
const sorts = {
  Volume: (a: Market, b: Market) => b.volume - a.volume,
  Newest: (a: Market, b: Market) => b.id - a.id,
}

export default function Home() {
  const navigate = useNavigate()
  // Three stages, each starting only after the previous one, so no stage
  // blocks the dashboard and no two log scans fire in parallel:
  // 1. Contract reads only: price, status, close time. No log scan, so the
  //    dashboard appears on entry even if the scan is slow or throttled.
  // 2. Dashboard scan: question, category and volume fill in.
  // 3. Full load: history, resolution, payouts, past trades, positions.
  const marketList = useMarketList()
  const summary = useDashboardMarkets(Boolean(marketList.data))
  const full = useMarkets(Boolean(summary.data))
  const [query, setQuery] = useState('')
  const [category, setCategory] = useState<'All' | Category>('All')
  const [sort, setSort] = useState<keyof typeof sorts>('Volume')

  const markets = full.data?.markets ?? summary.data?.markets ?? marketList.data?.markets
  if (!markets) return <p className="text-muted">{marketList.error ? 'Could not load markets from Base Sepolia.' : 'Loading markets…'}</p>

  // Full data replaces the summary when it lands; the summary replaces the
  // contract-read list when its scan lands.
  const detailsPending = Boolean(summary.data && !full.data)
  const summaryPending = Boolean(marketList.data && !summary.data)
  const logScanFailed = summary.data?.logScanFailed && !full.data
  const pick = (id: number) => (o: Outcome) => navigate(`/market/${id}?outcome=${o}`)

  const list = markets
    .filter((m) => category === 'All' || m.category === category)
    .filter((m) => m.question.toLowerCase().includes(query.trim().toLowerCase()))
    .sort((a, b) => Number(a.status !== 'open') - Number(b.status !== 'open') || sorts[sort](a, b))

  return (
    <div className="flex flex-col gap-8">
      <section className="flex flex-col gap-4">
        <label className="flex items-center gap-2 rounded-2xl bg-surface px-4 ring-white/30 focus-within:ring-1">
          <Search size={16} className="text-muted" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search markets"
            className="w-full bg-transparent py-3 text-sm outline-none placeholder:text-muted"
          />
        </label>
        <div className="flex flex-wrap items-center gap-2">
          {categoryFilters.map((c) => (
            <button
              key={c}
              aria-pressed={category === c}
              onClick={() => setCategory(c)}
              className={`rounded-full px-3.5 py-1.5 text-sm font-medium transition active:scale-95 ${
                category === c ? 'bg-white text-black' : 'bg-surface text-zinc-300 hover:bg-raised'
              }`}
            >
              {c}
            </button>
          ))}
          <div role="group" aria-label="Sort markets" className="ml-auto flex rounded-full bg-surface p-1 text-sm">
            {(Object.keys(sorts) as (keyof typeof sorts)[]).map((s) => (
              <button
                key={s}
                aria-pressed={sort === s}
                onClick={() => setSort(s)}
                className={`rounded-full px-3 py-1 font-medium ${sort === s ? 'bg-white text-black' : 'text-muted hover:text-white'}`}
              >
                {s}
              </button>
            ))}
          </div>
        </div>

        {(summaryPending || detailsPending) && (
          <p className="text-xs text-muted">
            {summaryPending
              ? 'Prices are live; questions and volume are still loading.'
              : logScanFailed
                ? 'Prices are live; volume and questions are still loading and will fill in on the next refresh.'
                : 'Prices and volume are live; full details, past trades and positions are still loading.'}
          </p>
        )}

        {list.length ? (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {list.map((m) => (
              <MarketCard key={m.id} market={m} onPick={pick(m.id)} />
            ))}
          </div>
        ) : (
          <div className="flex flex-col items-center gap-2 rounded-3xl border border-dashed border-line py-16 text-muted">
            <SearchX size={20} />
            <p className="text-sm">
              No markets{query && ` match "${query}"`}{category !== 'All' && ` in ${category}`}.
            </p>
            <button onClick={() => { setQuery(''); setCategory('All') }} className="text-sm font-medium text-white underline underline-offset-4">
              Clear filters
            </button>
          </div>
        )}
      </section>
    </div>
  )
}
