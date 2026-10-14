import {
  ArrowUpRight,
  Bitcoin,
  Check,
  CloudSun,
  Landmark,
  LoaderCircle,
  Rocket,
  TrendingUp,
  Trophy,
  Wallet,
} from 'lucide-react'
import { useState, type ButtonHTMLAttributes, type ReactNode } from 'react'
import { Link, NavLink } from 'react-router'
import {
  FEE,
  change30d,
  compact,
  date,
  pct,
  priceYes,
  quoteBuy,
  quoteSell,
  shortAddr,
  usdc,
  type Category,
  type Market,
  type Outcome,
} from './mock'
import { useWallet } from './wallet'

const press = 'transition active:scale-[0.98] motion-reduce:transition-none motion-reduce:active:scale-100'
const focus = 'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-zinc-900'

export function Nav() {
  const { wallet, connect, disconnect } = useWallet()
  const link = ({ isActive }: { isActive: boolean }) =>
    `rounded-md px-3 py-1.5 text-sm ${focus} ${isActive ? 'font-medium text-zinc-900' : 'text-zinc-500 hover:text-zinc-900'}`
  return (
    <header className="sticky top-0 z-20 border-b border-zinc-200 bg-white/80 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-6xl items-center gap-2 px-4">
        <Link to="/" className={`mr-4 flex items-center gap-2 rounded-md font-semibold ${focus}`}>
          <span className="grid size-7 place-items-center rounded-md bg-zinc-900 text-white">
            <TrendingUp size={16} />
          </span>
          Sooth
        </Link>
        <NavLink to="/" end className={link}>
          Explore
        </NavLink>
        <NavLink to="/portfolio" className={link}>
          Portfolio
        </NavLink>
        <div className="ml-auto flex items-center gap-2">
          {wallet && (
            <span className="hidden items-center gap-1.5 rounded-full bg-zinc-100 px-2.5 py-1 text-xs text-zinc-600 sm:flex">
              <span className="size-1.5 rounded-full bg-yes" /> Base Sepolia
            </span>
          )}
          <button
            onClick={wallet ? disconnect : connect}
            title={wallet ? 'Disconnect' : undefined}
            className={`flex items-center gap-2 rounded-lg px-3 py-1.5 text-sm font-medium ${press} ${focus} ${
              wallet ? 'border border-zinc-200 bg-white hover:bg-zinc-50' : 'bg-zinc-900 text-white hover:bg-zinc-700'
            }`}
          >
            <Wallet size={15} />
            {wallet ? shortAddr(wallet.address) : 'Connect wallet'}
          </button>
        </div>
      </div>
    </header>
  )
}

const categoryIcons: Record<Category, typeof Bitcoin> = {
  Crypto: Bitcoin,
  Economics: Landmark,
  Science: Rocket,
  Climate: CloudSun,
  Sports: Trophy,
}

export function CategoryLabel({ category }: { category: Category }) {
  const Icon = categoryIcons[category]
  return (
    <span className="flex items-center gap-1.5 text-xs text-zinc-500">
      <Icon size={14} /> {category}
    </span>
  )
}

export function StatusBadge({ market }: { market: Market }) {
  if (market.status === 'resolved')
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-zinc-900 px-2.5 py-0.5 text-xs font-medium text-white">
        <Check size={12} /> Resolved {market.resolvedOutcome}
      </span>
    )
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full bg-yes-soft px-2.5 py-0.5 text-xs font-medium text-yes">
      <span className="size-1.5 rounded-full bg-yes" /> Trading open
    </span>
  )
}

export function Change({ value }: { value: number }) {
  const pts = Math.round(value * 100)
  if (pts === 0) return <span className="text-xs text-zinc-400">0 pts</span>
  return (
    <span className={`text-xs font-medium ${pts > 0 ? 'text-yes' : 'text-no'}`}>
      {pts > 0 ? '▲' : '▼'} {Math.abs(pts)} pts
    </span>
  )
}

// Inline SVG line of YES probability. No chart library on purpose.
export function PriceChart({ points, height = 160, axis = false }: { points: number[]; height?: number; axis?: boolean }) {
  const w = 600
  const xy = points.map((p, i) => `${(i / (points.length - 1)) * w},${(1 - p) * height}`).join(' ')
  return (
    <svg viewBox={`0 0 ${w} ${height}`} preserveAspectRatio="none" className="w-full" style={{ height }} aria-hidden>
      {axis &&
        [0.25, 0.5, 0.75].map((g) => (
          <line key={g} x1={0} x2={w} y1={(1 - g) * height} y2={(1 - g) * height} className="stroke-zinc-200" strokeDasharray="4 4" vectorEffect="non-scaling-stroke" />
        ))}
      <polyline points={xy} fill="none" className="stroke-yes" strokeWidth={2} vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
    </svg>
  )
}

// Neutral outline button; outcome colour only shows on hover / when selected.
export function OutcomeButton({
  outcome,
  price,
  selected,
  ...rest
}: { outcome: Outcome; price: number; selected?: boolean } & ButtonHTMLAttributes<HTMLButtonElement>) {
  const tone =
    outcome === 'YES'
      ? selected
        ? 'border-yes bg-yes-soft text-yes'
        : 'hover:border-yes hover:bg-yes-soft hover:text-yes'
      : selected
        ? 'border-no bg-no-soft text-no'
        : 'hover:border-no hover:bg-no-soft hover:text-no'
  return (
    <button
      type="button"
      aria-pressed={selected}
      {...rest}
      className={`flex flex-1 items-center justify-between rounded-lg border border-zinc-200 bg-white px-3 py-2 text-sm font-medium ${press} ${focus} ${tone}`}
    >
      <span>{outcome === 'YES' ? 'Yes' : 'No'}</span>
      <span>{usdc(price)}</span>
    </button>
  )
}

export function MarketCard({ market, onPick }: { market: Market; onPick: (o: Outcome) => void }) {
  const p = priceYes(market)
  return (
    <article className="relative flex flex-col gap-4 rounded-2xl border border-zinc-200 bg-white p-5 transition hover:border-zinc-300 hover:shadow-sm">
      <CategoryLabel category={market.category} />
      <h3 className="font-medium leading-snug">
        <Link to={`/market/${market.id}`} className={`rounded after:absolute after:inset-0 after:rounded-2xl ${focus}`}>
          {market.question}
        </Link>
      </h3>
      <div className="mt-auto flex items-baseline gap-2">
        {market.status === 'resolved' ? (
          <StatusBadge market={market} />
        ) : (
          <>
            <span className="text-2xl font-semibold tracking-tight">{pct(p)}</span>
            <span className="text-xs text-zinc-500">chance</span>
            <span className="ml-auto">
              <Change value={change30d(market)} />
            </span>
          </>
        )}
      </div>
      {market.status === 'open' && (
        <div className="relative z-10 flex gap-2">
          <OutcomeButton outcome="YES" price={p} onClick={() => onPick('YES')} />
          <OutcomeButton outcome="NO" price={1 - p} onClick={() => onPick('NO')} />
        </div>
      )}
      <div className="flex justify-between text-xs text-zinc-500">
        <span>
          {market.status === 'resolved' ? 'Closed' : 'Closes'} {date(market.closesAt)}
        </span>
        <span>{compact(market.volume)} USDC vol</span>
      </div>
    </article>
  )
}

type Step = 'idle' | 'approving' | 'confirming' | 'done'

// Fully local trade ticket: real CPMM math on mock reserves, fake approve/confirm flow.
export function TradePanel({ market, outcome, setOutcome, held }: {
  market: Market
  outcome: Outcome
  setOutcome: (o: Outcome) => void
  held: number // shares of `outcome` the wallet holds
}) {
  const { wallet, connect, mint } = useWallet()
  const [mode, setMode] = useState<'Buy' | 'Sell'>('Buy')
  const [input, setInput] = useState('')
  const [slippage, setSlippage] = useState(0.01)
  const [approved, setApproved] = useState(false)
  const [step, setStep] = useState<Step>('idle')
  const [result, setResult] = useState('')

  const amount = Number(input) || 0
  const p = priceYes(market)
  const buy = mode === 'Buy' ? quoteBuy(market, outcome, amount) : null
  const sell = mode === 'Sell' ? quoteSell(market, outcome, amount) : null
  const impact = (buy ?? sell)!.impact
  const busy = step === 'approving' || step === 'confirming'

  const run = async () => {
    const wait = (ms: number) => new Promise((r) => setTimeout(r, ms))
    if (mode === 'Buy' && !approved) {
      setStep('approving')
      await wait(1200)
      setApproved(true)
    }
    setStep('confirming')
    await wait(1400)
    setResult(
      mode === 'Buy'
        ? `Bought ${buy!.shares.toFixed(1)} ${outcome} for ${usdc(amount)} USDC`
        : `Sold ${amount} ${outcome} for ${usdc(sell!.received)} USDC`,
    )
    setStep('done')
    setInput('')
  }

  let action: { label: ReactNode; onClick?: () => void; disabled?: boolean }
  if (market.status === 'resolved') action = { label: 'Trading closed', disabled: true }
  else if (!wallet) action = { label: 'Connect wallet to trade', onClick: connect }
  else if (mode === 'Buy' && wallet.usdc === 0) action = { label: 'Get test USDC', onClick: mint }
  else if (amount <= 0) action = { label: 'Enter an amount', disabled: true }
  else if (mode === 'Buy' && amount > wallet.usdc) action = { label: 'Not enough USDC', disabled: true }
  else if (mode === 'Sell' && amount > held) action = { label: `You hold ${held} ${outcome}`, disabled: true }
  else if (step === 'approving') action = { label: <><LoaderCircle size={16} className="animate-spin" /> Approving USDC…</>, disabled: true }
  else if (step === 'confirming') action = { label: <><LoaderCircle size={16} className="animate-spin" /> Confirm in wallet…</>, disabled: true }
  else if (mode === 'Buy' && !approved) action = { label: 'Approve USDC, then buy', onClick: run }
  else action = { label: `${mode} ${outcome === 'YES' ? 'Yes' : 'No'}`, onClick: run }

  const row = (label: string, value: ReactNode, strong = false) => (
    <div className="flex justify-between text-sm">
      <span className="text-zinc-500">{label}</span>
      <span className={strong ? 'font-semibold' : ''}>{value}</span>
    </div>
  )
  const quick = mode === 'Buy' ? [25, 50, 100] : [10, 50, 100]

  return (
    <div className="flex flex-col gap-4 rounded-2xl border border-zinc-200 bg-white p-5">
      <h2 className="font-semibold">Trade</h2>

      <div className="grid grid-cols-2 rounded-lg bg-zinc-100 p-1 text-sm">
        {(['Buy', 'Sell'] as const).map((m) => (
          <button
            key={m}
            aria-pressed={mode === m}
            onClick={() => { setMode(m); setInput(''); setStep('idle') }}
            className={`rounded-md py-1.5 ${focus} ${mode === m ? 'bg-white font-medium shadow-sm' : 'text-zinc-500'}`}
          >
            {m}
          </button>
        ))}
      </div>

      <div className="flex gap-2">
        <OutcomeButton outcome="YES" price={p} selected={outcome === 'YES'} onClick={() => setOutcome('YES')} />
        <OutcomeButton outcome="NO" price={1 - p} selected={outcome === 'NO'} onClick={() => setOutcome('NO')} />
      </div>

      <div className="flex flex-col gap-2">
        <div className="flex justify-between text-xs text-zinc-500">
          <label htmlFor="amount">{mode === 'Buy' ? 'Amount' : 'Shares to sell'}</label>
          {wallet && <span>{mode === 'Buy' ? `Balance ${usdc(wallet.usdc)} USDC` : `You hold ${held} ${outcome}`}</span>}
        </div>
        <div className={`flex items-center rounded-lg border border-zinc-200 px-3 focus-within:border-zinc-900`}>
          <input
            id="amount"
            inputMode="decimal"
            placeholder="0.00"
            value={input}
            onChange={(e) => { if (/^\d*\.?\d{0,6}$/.test(e.target.value)) { setInput(e.target.value); setStep('idle') } }}
            className="w-full bg-transparent py-3 text-2xl font-semibold outline-none"
          />
          <span className="text-sm text-zinc-500">{mode === 'Buy' ? 'USDC' : outcome}</span>
        </div>
        <div className="grid grid-cols-4 gap-2">
          {quick.map((q) => (
            <button key={q} onClick={() => setInput(String(q))} className={`rounded-md bg-zinc-100 py-1.5 text-xs hover:bg-zinc-200 ${press} ${focus}`}>
              {mode === 'Buy' ? `$${q}` : q}
            </button>
          ))}
          <button
            onClick={() => setInput(String(mode === 'Buy' ? (wallet?.usdc ?? 0) : held))}
            className={`rounded-md bg-zinc-100 py-1.5 text-xs hover:bg-zinc-200 ${press} ${focus}`}
          >
            Max
          </button>
        </div>
      </div>

      {amount > 0 && (
        <div className="flex flex-col gap-2 border-t border-zinc-100 pt-4">
          {row('Avg price', usdc((buy ?? sell)!.avgPrice))}
          {row(
            'Price impact',
            <span className={impact > 0.05 ? 'font-medium text-amber-600' : ''}>{(impact * 100).toFixed(1)}%</span>,
          )}
          {buy && row('Est. shares', buy.shares.toFixed(1))}
          {buy && row(`Min received (${slippage * 100}% slippage)`, (buy.shares * (1 - slippage)).toFixed(1))}
          {sell && row('You receive', `${usdc(sell.received)} USDC`)}
          {sell && row(`Min received (${slippage * 100}% slippage)`, `${usdc(sell.received * (1 - slippage))} USDC`)}
          {row(`Fee (${FEE * 100}%, included)`, `${usdc((buy ?? sell)!.fee)} USDC`)}
          {buy && row(`Payout if ${outcome} wins`, <span className="text-yes">{usdc(buy.shares)} USDC</span>, true)}
          <div className="flex items-center justify-between text-xs text-zinc-500">
            <span>Slippage tolerance</span>
            <div className="flex gap-1">
              {[0.005, 0.01, 0.02].map((s) => (
                <button
                  key={s}
                  aria-pressed={slippage === s}
                  onClick={() => setSlippage(s)}
                  className={`rounded px-1.5 py-0.5 ${focus} ${slippage === s ? 'bg-zinc-900 text-white' : 'bg-zinc-100'}`}
                >
                  {s * 100}%
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      {mode === 'Buy' && wallet && !approved && amount > 0 && !busy && (
        <p className="text-xs text-zinc-500">First trade needs two wallet confirmations: approve USDC once, then buy.</p>
      )}

      <button
        onClick={action.onClick}
        disabled={action.disabled}
        className={`flex items-center justify-center gap-2 rounded-lg bg-zinc-900 py-3 text-sm font-medium text-white hover:bg-zinc-700 disabled:cursor-not-allowed disabled:bg-zinc-200 disabled:text-zinc-500 ${press} ${focus}`}
      >
        {action.label}
      </button>

      {step === 'done' && (
        <p className="flex items-center justify-between rounded-lg bg-yes-soft px-3 py-2 text-sm text-yes">
          <span className="flex items-center gap-1.5"><Check size={15} /> {result}</span>
          <a href="https://sepolia.basescan.org/" target="_blank" rel="noreferrer" className="flex items-center gap-0.5 underline-offset-2 hover:underline">
            Basescan <ArrowUpRight size={13} />
          </a>
        </p>
      )}

      <p className="text-xs text-zinc-500">
        Winning shares redeem for 1 USDC each, losing shares for 0. Estimates can change before your wallet confirms.
      </p>
    </div>
  )
}

