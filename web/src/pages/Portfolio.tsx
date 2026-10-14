import { ArrowUpRight, LoaderCircle, Wallet } from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { Link } from 'react-router'
import { useWallet } from '../wallet'
import { useAccount } from 'wagmi'
import { basescanTx, cents, date, marketById, positionValue, positions, priceOf, signed, trades, usdc } from '../mock'

export default function Portfolio() {
  const { wallet, connect } = useWallet()
  const { isConnecting, isReconnecting } = useAccount()
  const connecting = isConnecting || isReconnecting
  const [tab, setTab] = useState<'Positions' | 'History'>('Positions')

  if (!wallet)
    return (
      <div className="flex flex-col items-center gap-3 rounded-2xl border border-dashed border-zinc-300 py-20 text-zinc-500">
        <Wallet size={22} />
        <p className="text-sm">Connect your wallet to see your positions and history.</p>
        <button
          onClick={connect}
          disabled={connecting}
          className="flex items-center gap-2 rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-700 active:scale-[0.98] disabled:cursor-not-allowed disabled:bg-zinc-200 disabled:text-zinc-500"
        >
          {connecting && <LoaderCircle size={15} className="animate-spin" />}
          {connecting ? 'Connecting…' : 'Connect wallet'}
        </button>
      </div>
    )

  const rows = positions.map((p) => {
    const m = marketById(p.marketId)!
    const value = positionValue(p)
    return { p, m, value, pnl: value - p.shares * p.avgPrice }
  })
  const total = rows.reduce((s, r) => s + r.value, 0)
  const pnl = rows.reduce((s, r) => s + r.pnl, 0)
  const cost = rows.reduce((s, r) => s + r.p.shares * r.p.avgPrice, 0)
  const history = trades.filter((t) => t.trader === wallet.address)

  const stat = (label: string, value: ReactNode, extra?: ReactNode) => (
    <div className="flex flex-col gap-1 rounded-2xl border border-zinc-200 bg-white p-5">
      <span className="text-xs text-zinc-500">{label}</span>
      <span className="text-2xl font-semibold tracking-tight">{value}</span>
      {extra}
    </div>
  )

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-2xl font-semibold tracking-tight">Portfolio</h1>
      <div className="grid gap-4 sm:grid-cols-3">
        {stat('Positions value', `${usdc(total)} USDC`)}
        {stat(
          'Profit / loss',
          <span className={pnl >= 0 ? 'text-yes' : 'text-no'}>{signed(pnl)}</span>,
          <span className="text-xs text-zinc-500">{((pnl / cost) * 100).toFixed(1)}% on {usdc(cost)} USDC cost</span>,
        )}
        {stat(
          'Cash',
          wallet.usdc == null ? <span className="text-zinc-400">— USDC</span> : `${usdc(wallet.usdc)} USDC`,
        )}
      </div>

      <div className="flex gap-1 text-sm">
        {(['Positions', 'History'] as const).map((t) => (
          <button
            key={t}
            aria-pressed={tab === t}
            onClick={() => setTab(t)}
            className={`rounded-md px-3 py-1.5 ${tab === t ? 'bg-zinc-900 text-white' : 'text-zinc-500 hover:bg-zinc-100'}`}
          >
            {t}
          </button>
        ))}
      </div>

      <div className="overflow-x-auto rounded-2xl border border-zinc-200 bg-white">
        {tab === 'Positions' ? (
          <table className="w-full min-w-[640px] text-sm">
            <thead className="text-left text-xs text-zinc-500">
              <tr className="border-b border-zinc-100">
                <th className="p-4 font-normal">Market</th>
                <th className="p-4 font-normal">Side</th>
                <th className="p-4 text-right font-normal">Shares</th>
                <th className="p-4 text-right font-normal">Avg</th>
                <th className="p-4 text-right font-normal">Now</th>
                <th className="p-4 text-right font-normal">Value</th>
                <th className="p-4 text-right font-normal">PnL</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100">
              {rows.map(({ p, m, value, pnl }) => (
                <tr key={`${p.marketId}-${p.outcome}`}>
                  <td className="max-w-xs p-4"><Link to={`/market/${m.id}`} className="hover:underline">{m.question}</Link></td>
                  <td className={`p-4 ${p.outcome === 'YES' ? 'text-yes' : 'text-no'}`}>{p.outcome}</td>
                  <td className="p-4 text-right">{p.shares}</td>
                  <td className="p-4 text-right">{cents(p.avgPrice)}</td>
                  <td className="p-4 text-right">
                    {m.status === 'resolved' ? <span className="text-xs text-zinc-500">Resolved {m.resolvedOutcome}</span> : cents(priceOf(m, p.outcome))}
                  </td>
                  <td className="p-4 text-right">{usdc(value)}</td>
                  <td className="p-4 text-right">
                    {m.status === 'resolved' && value > 0 ? (
                      <button className="rounded-md bg-zinc-900 px-3 py-1 text-xs font-medium text-white hover:bg-zinc-700 active:scale-[0.98]">
                        Redeem {usdc(value)}
                      </button>
                    ) : (
                      <span className={pnl >= 0 ? 'text-yes' : 'text-no'}>{signed(pnl)}</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <table className="w-full min-w-[640px] text-sm">
            <thead className="text-left text-xs text-zinc-500">
              <tr className="border-b border-zinc-100">
                <th className="p-4 font-normal">Date</th>
                <th className="p-4 font-normal">Action</th>
                <th className="p-4 font-normal">Market</th>
                <th className="p-4 text-right font-normal">Shares</th>
                <th className="p-4 text-right font-normal">Amount</th>
                <th className="p-4 font-normal"><span className="sr-only">Transaction</span></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100">
              {history.map((t) => (
                <tr key={t.tx}>
                  <td className="p-4 text-zinc-500">{date(t.at)}</td>
                  <td className={`p-4 ${t.outcome === 'YES' ? 'text-yes' : 'text-no'}`}>{t.side} {t.outcome}</td>
                  <td className="max-w-xs p-4"><Link to={`/market/${t.marketId}`} className="hover:underline">{marketById(t.marketId)!.question}</Link></td>
                  <td className="p-4 text-right">{t.shares}</td>
                  <td className="p-4 text-right">{usdc(t.amount)} USDC</td>
                  <td className="p-4">
                    <a href={basescanTx(t.tx)} target="_blank" rel="noreferrer" aria-label="View transaction" className="text-zinc-400 hover:text-zinc-900">
                      <ArrowUpRight size={14} />
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  )
}
