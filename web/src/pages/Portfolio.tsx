import { ArrowUpRight, LoaderCircle, Wallet } from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { Link, useParams } from 'react-router'
import { erc20Abi, formatUnits, isAddress, zeroAddress } from 'viem'
import { useWallet } from '../wallet'
import { useAccount, useReadContract } from 'wagmi'
import { useMarkets, usePositions } from '../chain'
import { ClaimButton, PAGE_SIZE, ShowMore } from '../components'
import { USDC } from '../contracts'
import { ago, basescanAddr, basescanTx, cents, isSettled, positionValue, priceOf, shortAddr, signed, usdc } from '../mock'

// /portfolio is the connected wallet; /portfolio/:address is anyone's, read-only from public chain data.
export default function Portfolio() {
  const { address: viewed } = useParams()
  const { wallet, connect } = useWallet()
  const { address, isConnecting, isReconnecting } = useAccount()
  const isOwn = !viewed || viewed.toLowerCase() === address?.toLowerCase()
  const owner = viewed ? (isAddress(viewed) ? viewed : undefined) : address
  const { data } = useMarkets()
  const positions = usePositions(owner)
  const { data: viewedCash } = useReadContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [owner ?? zeroAddress],
    query: { enabled: Boolean(owner && !isOwn) },
  })
  const connecting = isConnecting || isReconnecting
  const [tab, setTab] = useState<'Positions' | 'History'>('Positions')
  const [historyShown, setHistoryShown] = useState(PAGE_SIZE)

  if (viewed && !owner) return <p className="text-muted">Not a valid address.</p>
  if (!owner)
    return (
      <div className="flex flex-col items-center gap-3 rounded-3xl border border-dashed border-line py-20 text-muted">
        <Wallet size={22} />
        <p className="text-sm">Connect your wallet to see your positions and history.</p>
        <button
          onClick={connect}
          disabled={connecting}
          className="flex items-center gap-2 rounded-full bg-white px-4 py-2 text-sm font-semibold text-black hover:bg-zinc-200 active:scale-[0.98] disabled:cursor-not-allowed disabled:bg-raised disabled:text-muted"
        >
          {connecting && <LoaderCircle size={15} className="animate-spin" />}
          {connecting ? 'Connecting…' : 'Connect wallet'}
        </button>
      </div>
    )

  if (!data) return <p className="text-muted">Loading portfolio…</p>

  const marketById = (id: number) => data.markets.find((m) => m.id === id)!
  const rows = positions
    .map((p) => {
      const m = marketById(p.marketId)
      const value = positionValue(p, m)
      return { p, m, value, pnl: value - p.shares * p.avgPrice }
    })
    .toSorted((a, b) => b.value - a.value)
  const total = rows.reduce((s, r) => s + r.value, 0)
  const pnl = rows.reduce((s, r) => s + r.pnl, 0)
  const cost = rows.reduce((s, r) => s + r.p.shares * r.p.avgPrice, 0)
  // redeem() pays both sides at once, so each row's button shows its market's total.
  const payout = (marketId: number) => rows.filter((r) => r.m.id === marketId).reduce((s, r) => s + r.value, 0)
  const history = data.trades.filter((t) => t.trader.toLowerCase() === owner.toLowerCase()).toReversed()
  const cash = isOwn ? wallet?.usdc : viewedCash === undefined ? null : Number(formatUnits(viewedCash, 6))

  const stat = (label: string, value: ReactNode, extra?: ReactNode) => (
    <div className="flex flex-col gap-1 rounded-3xl bg-surface p-5">
      <span className="text-xs text-muted">{label}</span>
      <span className="text-3xl font-extrabold tracking-tight">{value}</span>
      {extra}
    </div>
  )

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-3xl font-bold tracking-tight">
        {isOwn ? (
          'Portfolio'
        ) : (
          <a href={basescanAddr(owner)} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 hover:underline">
            {shortAddr(owner)} <ArrowUpRight size={20} />
          </a>
        )}
      </h1>
      <div className="grid gap-4 sm:grid-cols-3">
        {stat('Positions value', `${usdc(total)} USDC`)}
        {stat(
          'Profit / loss',
          <span className={pnl >= 0 ? 'text-yes' : 'text-no'}>{signed(pnl)}</span>,
          cost > 0 && <span className="text-xs text-muted">{((pnl / cost) * 100).toFixed(1)}% on {usdc(cost)} USDC cost</span>,
        )}
        {stat(
          'Cash',
          cash == null ? <span className="text-muted">— USDC</span> : `${usdc(cash)} USDC`,
        )}
      </div>

      <div className="flex gap-1 text-sm">
        {(['Positions', 'History'] as const).map((t) => (
          <button
            key={t}
            aria-pressed={tab === t}
            onClick={() => setTab(t)}
            className={`rounded-full px-3.5 py-1.5 font-medium ${tab === t ? 'bg-white text-black' : 'text-muted hover:bg-raised'}`}
          >
            {t}
          </button>
        ))}
      </div>

      <div className="overflow-x-auto rounded-3xl bg-surface">
        {tab === 'Positions' ? (
          <table className="w-full min-w-[640px] text-sm">
            <thead className="text-left text-xs text-muted">
              <tr className="border-b border-line">
                <th className="p-4 font-normal">Market</th>
                <th className="p-4 font-normal">Side</th>
                <th className="p-4 text-right font-normal">Shares</th>
                <th className="p-4 text-right font-normal">Avg</th>
                <th className="p-4 text-right font-normal">Now</th>
                <th className="p-4 text-right font-normal">Value</th>
                <th className="p-4 text-right font-normal">PnL</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {rows.map(({ p, m, value, pnl }) => (
                <tr key={`${p.marketId}-${p.outcome}`}>
                  <td className="max-w-xs p-4"><Link to={`/market/${m.id}`} className="hover:underline">{m.question}</Link></td>
                  <td className={`p-4 ${p.outcome === 'YES' ? 'text-yes' : 'text-no'}`}>{p.outcome}</td>
                  <td className="p-4 text-right">{usdc(p.shares)}</td>
                  <td className="p-4 text-right">{cents(p.avgPrice)}</td>
                  <td className="p-4 text-right">
                    {m.status === 'resolved' ? (
                      <span className="text-xs text-muted">Resolved {m.resolvedOutcome}</span>
                    ) : m.status === 'cancelled' ? (
                      <span className="text-xs text-muted">Cancelled</span>
                    ) : (
                      cents(priceOf(m, p.outcome))
                    )}
                  </td>
                  <td className="p-4 text-right">{usdc(value)}</td>
                  <td className="p-4 text-right">
                    {isOwn && isSettled(m) && value > 0 ? (
                      <ClaimButton market={m} claim="redeem" payout={payout(m.id)} />
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
            <thead className="text-left text-xs text-muted">
              <tr className="border-b border-line">
                <th className="p-4 font-normal">Date</th>
                <th className="p-4 font-normal">Action</th>
                <th className="p-4 font-normal">Market</th>
                <th className="p-4 text-right font-normal">Shares</th>
                <th className="p-4 text-right font-normal">Amount</th>
                <th className="p-4 font-normal"><span className="sr-only">Transaction</span></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {history.slice(0, historyShown).map((t, i) => (
                <tr key={`${t.tx}-${i}`}>
                  <td className="p-4 text-muted" title={new Date(t.at).toLocaleString()}>{ago(t.at)}</td>
                  <td className={`p-4 ${t.outcome === 'YES' ? 'text-yes' : 'text-no'}`}>{t.side} {t.outcome}</td>
                  <td className="max-w-xs p-4"><Link to={`/market/${t.marketId}`} className="hover:underline">{marketById(t.marketId).question}</Link></td>
                  <td className="p-4 text-right">{usdc(t.shares)} @ {cents(t.amount / t.shares)}</td>
                  <td className="p-4 text-right">{usdc(t.amount)} USDC</td>
                  <td className="p-4">
                    <a href={basescanTx(t.tx)} target="_blank" rel="noreferrer" aria-label="View transaction" className="text-muted hover:text-white">
                      <ArrowUpRight size={14} />
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        {tab === 'History' && (
          <ShowMore shown={historyShown} total={history.length} onClick={() => setHistoryShown((n) => n + PAGE_SIZE)} />
        )}
      </div>
    </div>
  )
}
