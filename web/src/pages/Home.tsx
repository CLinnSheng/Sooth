import { Search, SearchX } from 'lucide-react'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router'
import { CategoryLabel, Change, MarketCard, OutcomeButton, PriceChart } from '../components'
import { change30d, compact, date, markets, pct, priceYes, type Category, type Outcome } from '../mock'

const categories: ('All' | Category)[] = ['All', 'Crypto', 'Economics', 'Science', 'Climate', 'Sports']
const sorts = {
  Volume: (a: (typeof markets)[number], b: (typeof markets)[number]) => b.volume - a.volume,
  'Closing soon': (a: (typeof markets)[number], b: (typeof markets)[number]) => a.closesAt.localeCompare(b.closesAt),
  Newest: (a: (typeof markets)[number], b: (typeof markets)[number]) => b.id - a.id,
}

export default function Home() {
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const [category, setCategory] = useState<'All' | Category>('All')
  const [sort, setSort] = useState<keyof typeof sorts>('Volume')

  const open = markets.filter((m) => m.status === 'open')
  const featured = [...open].sort(sorts.Volume)[0]
  const pick = (id: number) => (o: Outcome) => navigate(`/market/${id}?outcome=${o}`)

  const list = markets
    .filter((m) => m.id !== featured.id)
    .filter((m) => category === 'All' || m.category === category)
    .filter((m) => m.question.toLowerCase().includes(query.trim().toLowerCase()))
    .sort(sorts[sort])
  const p = priceYes(featured)

  return (
    <div className="flex flex-col gap-8">
      <section className="grid gap-6 rounded-2xl border border-zinc-200 bg-white p-6 md:grid-cols-2">
        <div className="flex flex-col gap-4">
          <div className="flex items-center justify-between">
            <CategoryLabel category={featured.category} />
            <span className="text-xs text-zinc-500">Closes {date(featured.closesAt)}</span>
          </div>
          <h1 className="text-2xl font-semibold tracking-tight md:text-3xl">
            <Link to={`/market/${featured.id}`} className="hover:underline hover:underline-offset-4">
              {featured.question}
            </Link>
          </h1>
          <div className="mt-auto flex gap-2">
            <OutcomeButton outcome="YES" price={p} onClick={() => pick(featured.id)('YES')} />
            <OutcomeButton outcome="NO" price={1 - p} onClick={() => pick(featured.id)('NO')} />
          </div>
          <span className="text-xs text-zinc-500">{compact(featured.volume)} USDC vol</span>
        </div>
        <div className="flex flex-col gap-2">
          <div className="flex items-baseline gap-2">
            <span className="text-4xl font-semibold tracking-tight text-yes">{pct(p)}</span>
            <span className="text-sm text-zinc-500">chance of YES</span>
            <span className="ml-auto"><Change value={change30d(featured)} /></span>
          </div>
          <PriceChart points={featured.history.slice(-30)} height={140} />
          <div className="flex justify-between text-xs text-zinc-400">
            <span>30 days ago</span>
            <span>Today</span>
          </div>
        </div>
      </section>

      <section className="flex flex-col gap-4">
        <label className="flex items-center gap-2 rounded-xl border border-zinc-200 bg-white px-4 focus-within:border-zinc-900">
          <Search size={16} className="text-zinc-400" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search markets"
            className="w-full bg-transparent py-3 text-sm outline-none"
          />
        </label>
        <div className="flex flex-wrap items-center gap-2">
          {categories.map((c) => (
            <button
              key={c}
              aria-pressed={category === c}
              onClick={() => setCategory(c)}
              className={`rounded-full border px-3 py-1 text-sm transition active:scale-95 ${
                category === c ? 'border-zinc-900 bg-zinc-900 text-white' : 'border-zinc-200 bg-white hover:border-zinc-300'
              }`}
            >
              {c}
            </button>
          ))}
          <select
            value={sort}
            onChange={(e) => setSort(e.target.value as keyof typeof sorts)}
            aria-label="Sort markets"
            className="ml-auto rounded-md bg-transparent py-1 text-sm text-zinc-600"
          >
            {Object.keys(sorts).map((s) => (
              <option key={s}>{s}</option>
            ))}
          </select>
        </div>

        {list.length ? (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {list.map((m) => (
              <MarketCard key={m.id} market={m} onPick={pick(m.id)} />
            ))}
          </div>
        ) : (
          <div className="flex flex-col items-center gap-2 rounded-2xl border border-dashed border-zinc-300 py-16 text-zinc-500">
            <SearchX size={20} />
            <p className="text-sm">
              No markets{query && ` match "${query}"`}{category !== 'All' && ` in ${category}`}.
            </p>
            <button onClick={() => { setQuery(''); setCategory('All') }} className="text-sm font-medium text-zinc-900 underline underline-offset-4">
              Clear filters
            </button>
          </div>
        )}
      </section>
    </div>
  )
}
