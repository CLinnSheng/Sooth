import { Link } from 'react-router'
import { encodeFunctionData, formatUnits, multicall3Abi, type Address } from 'viem'
import { useAccount, useReadContracts } from 'wagmi'
import { baseSepolia } from 'wagmi/chains'
import { useIsAdmin, useMarkets } from '../chain'
import { AdminTabs } from '../components'
import { marketAbi } from '../contracts'
import { isSettled, poolPayout, shortAddr, usdc, type Market } from '../mock'
import { useTransaction } from '../tx'
import { useWallet } from '../wallet'

const MULTICALL3 = baseSepolia.contracts.multicall3.address

// Named by what the admin can do, not by contract state. The order is the table's sort order.
const STATUSES = {
  ready: { label: 'Ready', dot: 'bg-yes' },
  awaiting: { label: 'Awaiting result', dot: 'bg-muted' },
  trading: { label: 'Trading', dot: 'bg-muted' },
  collected: { label: 'Collected', dot: 'bg-muted' },
} as const
type Status = keyof typeof STATUSES

type Row = { market: Market; fees: number; liquidity: number; status: Status }

// Withdrawals pay the market's creator whoever sends them, so one multicall can sweep every market.
// Each call may fail on its own (someone collected first); what is left stays listed after the refetch.
// shortcut: one transaction for every market, ~60k gas each; batch by ~100 markets if the list ever grows that long.
const calls = (rows: Row[]) =>
  rows.flatMap(({ market, fees, liquidity }) =>
    [
      ...(fees > 0 && market.status !== 'open' ? (['withdrawFees'] as const) : []),
      ...(liquidity > 0 ? (['withdrawLiquidity'] as const) : []),
    ].map((functionName) => ({
      target: market.address as Address,
      allowFailure: true,
      callData: encodeFunctionData({ abi: marketAbi, functionName }),
    })),
  )

const collectable = (row: Row) => (row.market.status === 'open' ? 0 : row.fees) + row.liquidity

export default function Collect() {
  const { wallet, connect } = useWallet()
  const { address } = useAccount()
  const { data: isAdmin, isPending: isCheckingRole } = useIsAdmin(address)
  const { data } = useMarkets()
  const markets = data?.markets ?? []
  const { data: accruedFees } = useReadContracts({
    allowFailure: false,
    contracts: markets.map((m) => ({ address: m.address as Address, abi: marketAbi, functionName: 'accruedFees' }) as const),
    query: { enabled: markets.length > 0 },
  })

  if (!wallet)
    return (
      <p className="text-muted">
        Connect the admin wallet to collect. <button onClick={connect} className="text-white underline">Connect</button>
      </p>
    )
  if (isCheckingRole) return <p className="text-muted">Checking admin role…</p>
  if (!isAdmin) return <p className="text-muted">Admin only. {wallet.address} cannot collect.</p>
  if (!data || (markets.length > 0 && !accruedFees)) return <p className="text-muted">Loading markets…</p>

  const rows = markets
    .map((market, i): Row => {
      const fees = Number(formatUnits(accruedFees?.[i] ?? 0n, 6))
      const liquidity = isSettled(market) && !market.liquidityWithdrawn ? poolPayout(market) : 0
      const status: Status =
        market.status === 'open' ? 'trading' : !isSettled(market) ? 'awaiting' : fees + liquidity > 0 ? 'ready' : 'collected'
      return { market, fees, liquidity, status }
    })
    .toSorted((a, b) => Object.keys(STATUSES).indexOf(a.status) - Object.keys(STATUSES).indexOf(b.status))
  const pending = rows.filter((row) => collectable(row) > 0)
  const ready = pending.reduce((sum, row) => sum + collectable(row), 0)
  const collected = markets.reduce((sum, m) => sum + m.collected.fees + m.collected.liquidity, 0)

  const stat = (label: string, value: string) => (
    <div className="flex flex-col gap-1 rounded-3xl bg-surface p-5">
      <span className="text-xs text-muted">{label}</span>
      <span className="text-3xl font-extrabold tracking-tight tabular-nums">{value}</span>
    </div>
  )

  return (
    <div className="flex flex-col gap-6">
      <AdminTabs />
      <div className="grid gap-4 sm:grid-cols-3">
        {stat('Ready to collect', `${usdc(ready)} USDC`)}
        {stat('Collected so far', `${usdc(collected)} USDC`)}
        {stat('Markets', String(markets.length))}
      </div>

      <div className="overflow-x-auto rounded-3xl bg-surface">
        <table className="w-full min-w-[720px] text-sm tabular-nums">
          <thead className="text-left text-xs text-muted">
            <tr className="border-b border-line">
              <th className="p-4 font-normal">Market</th>
              <th className="p-4 font-normal">Status</th>
              <th className="p-4 text-right font-normal">Fees</th>
              <th className="p-4 text-right font-normal">Liquidity</th>
              <th className="p-4 text-right font-normal"><span className="sr-only">Action</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-line">
            {rows.map((row) => {
              const { market, status } = row
              const done = status === 'collected'
              // Collected rows show what was paid; the rest show what is waiting (or still accruing while trading).
              const fees = done ? market.collected.fees : row.fees
              const liquidity = done ? market.collected.liquidity : row.liquidity
              const isOthers = market.creator.toLowerCase() !== address?.toLowerCase()
              return (
                <tr key={market.id} className={done ? 'text-muted' : ''}>
                  <td className="max-w-xs p-4"><Link to={`/market/${market.id}`} className="hover:underline">{market.question}</Link></td>
                  <td className="p-4">
                    <span className="inline-flex items-center gap-1.5 whitespace-nowrap">
                      <span className={`size-1.5 rounded-full ${STATUSES[status].dot}`} /> {STATUSES[status].label}
                    </span>
                  </td>
                  <td className="p-4 text-right">
                    {fees > 0 ? usdc(fees) : '—'}
                    {status === 'trading' && fees > 0 && <span className="block text-xs text-muted">accruing</span>}
                  </td>
                  <td className="p-4 text-right">{liquidity > 0 ? usdc(liquidity) : '—'}</td>
                  <td className="p-4 text-right">
                    {collectable(row) > 0 ? (
                      <span className="inline-flex flex-col items-end gap-1">
                        <CollectButton rows={[row]} label={`Collect ${usdc(collectable(row))}`} />
                        {isOthers && <span className="text-xs text-muted">pays {shortAddr(market.creator)}</span>}
                      </span>
                    ) : done ? 'Collected' : '—'}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
        {rows.length === 0 && <p className="p-4 text-sm text-muted">No markets yet.</p>}
      </div>

      {pending.length > 1 && (
        <div className="flex justify-end">
          <CollectButton rows={pending} label={`Collect all · ${usdc(ready)} USDC`} primary />
        </div>
      )}
    </div>
  )
}

function CollectButton({ rows, label, primary = false }: { rows: Row[]; label: string; primary?: boolean }) {
  const tx = useTransaction()
  const collect = () =>
    tx.run(() => tx.confirm('Collecting…', tx.write({ address: MULTICALL3, abi: multicall3Abi, functionName: 'aggregate3', args: [calls(rows)] })))
  const size = primary ? 'rounded-xl px-5 py-3 text-sm' : 'rounded-full px-3 py-1 text-xs'
  return (
    <span className="inline-flex flex-col items-end gap-1">
      <button
        onClick={collect}
        disabled={tx.pending !== null}
        className={`${size} bg-white font-semibold text-black hover:bg-zinc-200 active:scale-[0.98] disabled:cursor-not-allowed disabled:bg-raised disabled:text-muted`}
      >
        {tx.pending ?? label}
      </button>
      {tx.error && <span role="alert" className="text-xs text-no">{tx.error}</span>}
    </span>
  )
}
