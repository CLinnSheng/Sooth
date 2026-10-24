import {
  ArrowUpRight,
  Check,
  CloudSun,
  Coins,
  Landmark,
  LoaderCircle,
  Rocket,
  TrendingUp,
  TriangleAlert,
  Trophy,
  Wallet,
} from 'lucide-react'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useQueryClient } from '@tanstack/react-query'
import { useState, type ButtonHTMLAttributes, type ReactNode } from 'react'
import { Link, NavLink } from 'react-router'
import { BaseError, UserRejectedRequestError, erc20Abi, formatUnits, parseUnits, zeroAddress, type Address, type Hex } from 'viem'
import { useAccount, useReadContract, useReadContracts, useSwitchChain, useWriteContract } from 'wagmi'
import { waitForTransactionReceipt } from 'wagmi/actions'
import { baseSepolia } from 'wagmi/chains'
import { OUTCOME_TOKEN, USDC, marketAbi, outcomeTokenAbi } from './contracts'
import {
  FEE,
  basescanTx,
  cents,
  change30d,
  compact,
  date,
  pct,
  priceYes,
  quoteBuy,
  quoteSell,
  usdc,
  type Category,
  type Market,
  type Outcome,
} from './mock'
import { useWallet } from './wallet'
import { config } from './wagmi'

const press = 'transition active:scale-[0.98] motion-reduce:transition-none motion-reduce:active:scale-100'
// System blue reads on both light and dark surfaces.
const focus = 'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#0a84ff]'

// Deterministic gradient so a wallet is recognisable without reading its hex address.
const avatar = (address: string) => {
  const hue = parseInt(address.slice(2, 8), 16) % 360
  return `linear-gradient(135deg, hsl(${hue} 85% 60%), hsl(${(hue + 70) % 360} 85% 45%))`
}

export function Nav() {
  const { wallet } = useWallet()
  const { isConnecting, isReconnecting } = useAccount()
  const { switchChain, isPending: isSwitchingChain } = useSwitchChain()
  const link = ({ isActive }: { isActive: boolean }) =>
    `rounded-md px-3 py-1.5 text-sm ${focus} ${isActive ? 'font-medium text-white' : 'text-muted hover:text-white'}`
  return (
    <header className="sticky top-0 z-20 border-b border-line bg-canvas/75 backdrop-blur-xl">
      <div className="mx-auto flex h-14 max-w-6xl items-center gap-2 px-4">
        <Link to="/" className={`mr-1 flex items-center gap-2 rounded-md font-semibold sm:mr-4 ${focus}`}>
          <span className="grid size-7 place-items-center rounded-md bg-white text-black">
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
        <ConnectButton.Custom>
          {({ account, chain, mounted, openAccountModal, openConnectModal }) => {
            const connecting = isConnecting || isReconnecting
            return (
              <div
                className={`ml-auto flex items-center gap-2 ${mounted ? '' : 'pointer-events-none opacity-0'}`}
                aria-hidden={!mounted}
              >
                {mounted && account && chain ? (
                  <>
                    {/* Network is only shown when it is wrong. */}
                    {chain.unsupported && (
                      <button
                        type="button"
                        onClick={() => switchChain({ chainId: baseSepolia.id })}
                        disabled={isSwitchingChain}
                        className={`flex items-center gap-2 whitespace-nowrap rounded-full bg-amber-400/15 px-3 py-1.5 text-sm font-medium text-amber-300 hover:bg-amber-400/25 disabled:cursor-not-allowed disabled:opacity-60 ${press} ${focus}`}
                      >
                        {isSwitchingChain ? <LoaderCircle size={15} className="animate-spin" /> : <TriangleAlert size={15} />}
                        {isSwitchingChain ? 'Switching…' : <>Switch<span className="hidden sm:inline"> to Base Sepolia</span></>}
                      </button>
                    )}
                    {/* One pill: balance is the headline, the address lives in the account sheet. */}
                    <div className="flex items-center gap-1 rounded-full bg-raised p-1 text-sm font-semibold">
                      {!chain.unsupported && (
                        <Link
                          to="/portfolio"
                          title="USDC on Base Sepolia · view portfolio"
                          className={`hidden whitespace-nowrap rounded-full py-1 pl-3 pr-2 tracking-tight hover:bg-white/10 sm:block ${focus}`}
                        >
                          {wallet?.usdc == null ? <span className="text-muted">$—</span> : `$${usdc(wallet.usdc)}`}
                        </Link>
                      )}
                      <button
                        type="button"
                        onClick={openAccountModal}
                        title={`${account.displayName} · manage wallet`}
                        aria-label="Manage wallet"
                        style={{ background: avatar(account.address) }}
                        className={`size-7 rounded-full ring-1 ring-white/15 hover:ring-white/40 ${press} ${focus}`}
                      />
                    </div>
                  </>
                ) : (
                  <button
                    type="button"
                    onClick={openConnectModal}
                    disabled={connecting}
                    className={`flex items-center gap-2 whitespace-nowrap rounded-full bg-white px-4 py-1.5 text-sm font-semibold text-black hover:bg-zinc-200 disabled:cursor-not-allowed disabled:bg-raised disabled:text-muted ${press} ${focus}`}
                  >
                    {connecting ? <LoaderCircle size={15} className="animate-spin" /> : <Wallet size={15} />}
                    {connecting ? 'Connecting…' : <>Connect<span className="hidden sm:inline"> wallet</span></>}
                  </button>
                )}
              </div>
            )
          }}
        </ConnectButton.Custom>
      </div>
    </header>
  )
}

const categoryIcons: Record<Category, typeof Coins> = {
  Crypto: Coins,
  Economics: Landmark,
  Science: Rocket,
  Climate: CloudSun,
  Sports: Trophy,
}

export function CategoryLabel({ category }: { category: Category }) {
  const Icon = categoryIcons[category]
  return (
    <span className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-muted">
      <Icon size={13} /> {category}
    </span>
  )
}

export function StatusBadge({ market }: { market: Market }) {
  if (market.status === 'closed')
    return (
      <span className="inline-flex items-center gap-1.5 rounded-full bg-raised px-2.5 py-0.5 text-xs font-medium text-muted">
        <span className="size-1.5 rounded-full bg-muted" /> Trading closed
      </span>
    )
  if (market.status === 'resolved')
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-white px-2.5 py-0.5 text-xs font-semibold text-black">
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
  if (pts === 0) return null
  return (
    <span className={`text-xs font-medium ${pts > 0 ? 'text-yes' : 'text-no'}`}>
      {pts > 0 ? '▲' : '▼'} {Math.abs(pts)} {Math.abs(pts) === 1 ? 'pt' : 'pts'}
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
          <line key={g} x1={0} x2={w} y1={(1 - g) * height} y2={(1 - g) * height} className="stroke-line" strokeDasharray="4 4" vectorEffect="non-scaling-stroke" />
        ))}
      <polyline points={xy} fill="none" className="stroke-yes" strokeWidth={2} vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
    </svg>
  )
}

// YES share of the YES/NO split, like a scoreboard: who is ahead, at a glance.
export function ProbabilityBar({ p }: { p: number }) {
  return (
    <div className="flex h-1.5 gap-0.5" aria-hidden>
      <div className="rounded-full bg-yes" style={{ width: `${p * 100}%` }} />
      <div className="flex-1 rounded-full bg-no" />
    </div>
  )
}

// Tinted by outcome so the action reads as a bet, solid when selected.
export function OutcomeButton({
  outcome,
  price,
  selected,
  verb,
  ...rest
}: { outcome: Outcome; price: number; selected?: boolean; verb?: string } & ButtonHTMLAttributes<HTMLButtonElement>) {
  const tone =
    outcome === 'YES'
      ? selected
        ? 'bg-yes text-black'
        : 'bg-yes-soft text-yes hover:bg-yes/25'
      : selected
        ? 'bg-no text-black'
        : 'bg-no-soft text-no hover:bg-no/25'
  return (
    <button
      type="button"
      aria-pressed={selected}
      {...rest}
      className={`flex flex-1 items-center justify-between rounded-xl px-3.5 py-2.5 text-sm font-semibold ${press} ${focus} ${tone}`}
    >
      {/* The colour already says "buy"; the verb stays for screen readers. */}
      <span>{verb && <span className="sr-only">{verb} </span>}{outcome === 'YES' ? 'Yes' : 'No'}</span>
      <span>{cents(price)}</span>
    </button>
  )
}

export function MarketCard({ market, onPick }: { market: Market; onPick: (o: Outcome) => void }) {
  const p = priceYes(market)
  return (
    <article className="relative flex flex-col gap-4 rounded-3xl bg-surface p-5 transition-colors hover:bg-[#232325]">
      <div className="flex items-center justify-between">
        {market.category && <CategoryLabel category={market.category} />}
        <span className="ml-auto text-xs text-muted">
          {market.status === 'open' ? 'Closes' : 'Closed'} {date(market.closesAt)}
        </span>
      </div>
      <h3 className="font-semibold leading-snug">
        <Link to={`/market/${market.id}`} className={`rounded after:absolute after:inset-0 after:rounded-3xl ${focus}`}>
          {market.question}
        </Link>
      </h3>
      {market.status === 'resolved' ? (
        <div className="mt-auto flex flex-col gap-1">
          <span className="flex items-center gap-2 text-3xl font-extrabold tracking-tight">
            <Check size={26} strokeWidth={3} className={market.resolvedOutcome === 'YES' ? 'text-yes' : 'text-no'} />
            {market.resolvedOutcome === 'YES' ? 'Yes' : 'No'}
          </span>
          <span className="text-xs text-muted">
            Resolved · winning shares paid 1 USDC each
          </span>
        </div>
      ) : (
        <div className="mt-auto flex flex-col gap-3">
          <div className="flex items-baseline gap-2">
            <span className="text-[40px] font-extrabold leading-none tracking-tighter">{pct(p)}</span>
            <span className="text-sm text-muted">chance</span>
            <span className="ml-auto">
              <Change value={change30d(market)} />
            </span>
          </div>
          <ProbabilityBar p={p} />
        </div>
      )}
      {market.status === 'open' && (
        <div className="relative z-10 flex gap-2">
          <OutcomeButton verb="Buy" outcome="YES" price={p} onClick={() => onPick('YES')} />
          <OutcomeButton verb="Buy" outcome="NO" price={1 - p} onClick={() => onPick('NO')} />
        </div>
      )}
      <span className="text-xs text-muted">{compact(market.volume)} USDC vol</span>
    </article>
  )
}

type Step = 'idle' | 'approving' | 'confirming' | 'done' | 'failed'

const DEADLINE_SECS = 600
const SHARE_DECIMALS = 6 // shares are minted 1:1 with 6-decimal USDC

// Trade ticket: local CPMM quotes on live pools, real approve and buy/sell transactions.
export function TradePanel({ market, outcome, setOutcome }: {
  market: Market
  outcome: Outcome
  setOutcome: (o: Outcome) => void
}) {
  const { wallet, connect } = useWallet()
  const { address, chain, isConnecting, isReconnecting } = useAccount()
  const { switchChain, isPending: isSwitchingChain } = useSwitchChain()
  const queryClient = useQueryClient()
  const { writeContractAsync } = useWriteContract()
  const [mode, setMode] = useState<'Buy' | 'Sell'>('Buy')
  const [input, setInput] = useState('')
  const [slippage, setSlippage] = useState(0.01)
  const [step, setStep] = useState<Step>('idle')
  const [result, setResult] = useState<{ text: string; tx?: Hex }>({ text: '' })

  const marketAddress = market.address as Address
  const owner = address ?? zeroAddress
  const { data: tokenId } = useReadContract({
    address: marketAddress,
    abi: marketAbi,
    functionName: outcome === 'YES' ? 'yesTokenId' : 'noTokenId',
  })
  const { data: reads } = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: USDC, abi: erc20Abi, functionName: 'allowance', args: [owner, marketAddress] },
      { address: OUTCOME_TOKEN, abi: outcomeTokenAbi, functionName: 'isApprovedForAll', args: [owner, marketAddress] },
      { address: OUTCOME_TOKEN, abi: outcomeTokenAbi, functionName: 'balanceOf', args: [owner, tokenId ?? 0n] },
    ],
    query: { enabled: Boolean(address && tokenId !== undefined) },
  })
  const [allowance, isSellApproved, heldRaw] = reads ?? [0n, false, 0n]
  const held = Number(formatUnits(heldRaw, SHARE_DECIMALS))

  const amount = Number(input) || 0
  const amountRaw = amount > 0 ? parseUnits(input, SHARE_DECIMALS) : 0n
  const needsApproval = mode === 'Buy' ? allowance < amountRaw : !isSellApproved
  const p = priceYes(market)
  const buy = mode === 'Buy' ? quoteBuy(market, outcome, amount) : null
  const sell = mode === 'Sell' ? quoteSell(market, outcome, amount) : null
  const impact = (buy ?? sell)!.impact
  const busy = step === 'approving' || step === 'confirming'
  const expectedOut = buy ? buy.shares : (sell?.received ?? 0)
  const minOut = BigInt(Math.floor(expectedOut * (1 - slippage) * 10 ** SHARE_DECIMALS))

  const run = async () => {
    const confirm = async (hash: Hex) => (await waitForTransactionReceipt(config, { hash }), hash)
    const side = outcome === 'YES' ? 0 : 1 // IMarket.Outcome: Yes = 0, No = 1
    const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECS)
    try {
      if (needsApproval) {
        setStep('approving')
        await confirm(
          mode === 'Buy'
            ? await writeContractAsync({ address: USDC, abi: erc20Abi, functionName: 'approve', args: [marketAddress, amountRaw] })
            : await writeContractAsync({ address: OUTCOME_TOKEN, abi: outcomeTokenAbi, functionName: 'setApprovalForAll', args: [marketAddress, true] }),
        )
      }
      setStep('confirming')
      const tx = await confirm(
        await writeContractAsync({
          address: marketAddress,
          abi: marketAbi,
          functionName: mode === 'Buy' ? 'buy' : 'sell',
          args: [side, amountRaw, minOut, deadline],
        }),
      )
      setResult({
        text:
          mode === 'Buy'
            ? `Bought ${buy!.shares.toFixed(1)} ${outcome} for ${usdc(amount)} USDC`
            : `Sold ${amount} ${outcome} for ${usdc(sell!.received)} USDC`,
        tx,
      })
      setStep('done')
      setInput('')
    } catch (e) {
      // A wallet rejection is the user's choice, not an error worth showing.
      if (e instanceof BaseError && e.walk((x) => x instanceof UserRejectedRequestError)) return setStep('idle')
      setResult({ text: e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : 'Transaction failed' })
      setStep('failed')
    } finally {
      queryClient.invalidateQueries()
    }
  }

  let action: { label: ReactNode; onClick?: () => void; disabled?: boolean }
  if (market.status !== 'open') action = { label: 'Trading closed', disabled: true }
  else if (isConnecting || isReconnecting)
    action = { label: <><LoaderCircle size={16} className="animate-spin" /> Connecting wallet…</>, disabled: true }
  else if (!wallet) action = { label: 'Connect wallet to trade', onClick: connect }
  else if (!chain)
    action = {
      label: isSwitchingChain ? <><LoaderCircle size={16} className="animate-spin" /> Switching…</> : 'Switch to Base Sepolia',
      onClick: () => switchChain({ chainId: baseSepolia.id }),
      disabled: isSwitchingChain,
    }
  else if (mode === 'Buy' && wallet.usdc == null) action = { label: <><LoaderCircle size={16} className="animate-spin" /> Loading balance…</>, disabled: true }
  else if (amount <= 0) action = { label: 'Enter an amount', disabled: true }
  else if (mode === 'Buy' && amount > (wallet.usdc ?? 0)) action = { label: 'Not enough USDC', disabled: true }
  else if (mode === 'Sell' && amount > held) action = { label: `You hold ${held} ${outcome}`, disabled: true }
  else if (step === 'approving')
    action = { label: <><LoaderCircle size={16} className="animate-spin" /> Approving {mode === 'Buy' ? 'USDC' : 'shares'}…</>, disabled: true }
  else if (step === 'confirming') action = { label: <><LoaderCircle size={16} className="animate-spin" /> Confirm in wallet…</>, disabled: true }
  else if (needsApproval) action = { label: mode === 'Buy' ? 'Approve USDC, then buy' : 'Approve shares, then sell', onClick: run }
  else action = { label: `${mode} ${outcome === 'YES' ? 'Yes' : 'No'}`, onClick: run }

  const row = (label: string, value: ReactNode, strong = false) => (
    <div className="flex justify-between text-sm">
      <span className="text-muted">{label}</span>
      <span className={strong ? 'font-semibold' : ''}>{value}</span>
    </div>
  )
  const quick = mode === 'Buy' ? [25, 50, 100] : [10, 50, 100]

  return (
    <div className="flex flex-col gap-4 rounded-3xl bg-surface p-5">
      <h2 className="font-semibold">Trade</h2>

      <div className="grid grid-cols-2 rounded-xl bg-raised p-1 text-sm">
        {(['Buy', 'Sell'] as const).map((m) => (
          <button
            key={m}
            aria-pressed={mode === m}
            onClick={() => { setMode(m); setInput(''); setStep('idle') }}
            className={`rounded-lg py-1.5 ${focus} ${mode === m ? 'bg-[#636366] font-semibold' : 'text-muted'}`}
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
        <div className="flex justify-between text-xs text-muted">
          <label htmlFor="amount">{mode === 'Buy' ? 'Amount' : 'Shares to sell'}</label>
          {wallet && <span>{mode === 'Buy' ? `Balance ${wallet.usdc == null ? '—' : usdc(wallet.usdc)} USDC` : `You hold ${held} ${outcome}`}</span>}
        </div>
        <div className={`flex items-center rounded-xl bg-raised px-3 ring-white/30 focus-within:ring-1`}>
          <input
            id="amount"
            inputMode="decimal"
            placeholder="0.00"
            value={input}
            onChange={(e) => { if (/^\d*\.?\d{0,6}$/.test(e.target.value)) { setInput(e.target.value); setStep('idle') } }}
            className="w-full bg-transparent py-3 text-2xl font-semibold outline-none"
          />
          <span className="text-sm text-muted">{mode === 'Buy' ? 'USDC' : outcome}</span>
        </div>
        <div className="grid grid-cols-4 gap-2">
          {quick.map((q) => (
            <button key={q} onClick={() => setInput(String(q))} className={`rounded-lg bg-raised py-1.5 text-xs font-medium hover:bg-white/15 ${press} ${focus}`}>
              {mode === 'Buy' ? `$${q}` : q}
            </button>
          ))}
          <button
            onClick={() => setInput(String(mode === 'Buy' ? (wallet?.usdc ?? 0) : held))}
            className={`rounded-lg bg-raised py-1.5 text-xs font-medium hover:bg-white/15 ${press} ${focus}`}
          >
            Max
          </button>
        </div>
      </div>

      {amount > 0 && (
        <div className="flex flex-col gap-2 border-t border-line pt-4">
          {row('Avg price', cents((buy ?? sell)!.avgPrice, 1))}
          {row(
            'Price impact',
            <span className={impact > 0.05 ? 'font-medium text-amber-400' : ''}>{(impact * 100).toFixed(1)}%</span>,
          )}
          {buy && row('Est. shares', buy.shares.toFixed(1))}
          {buy && row(`Min received (${slippage * 100}% slippage)`, (buy.shares * (1 - slippage)).toFixed(1))}
          {sell && row('You receive', `${usdc(sell.received)} USDC`)}
          {sell && row(`Min received (${slippage * 100}% slippage)`, `${usdc(sell.received * (1 - slippage))} USDC`)}
          {row(`Fee (${FEE * 100}%, included)`, `${usdc((buy ?? sell)!.fee)} USDC`)}
          {buy && row(`Payout if ${outcome} wins`, <span className="text-yes">{usdc(buy.shares)} USDC</span>, true)}
          <div className="flex items-center justify-between text-xs text-muted">
            <span>Slippage tolerance</span>
            <div className="flex gap-1">
              {[0.005, 0.01, 0.02].map((s) => (
                <button
                  key={s}
                  aria-pressed={slippage === s}
                  onClick={() => setSlippage(s)}
                  className={`rounded px-1.5 py-0.5 ${focus} ${slippage === s ? 'bg-white text-black' : 'bg-raised'}`}
                >
                  {s * 100}%
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      {wallet && needsApproval && amount > 0 && !busy && (
        <p className="text-xs text-muted">
          {mode === 'Buy'
            ? 'Needs two wallet confirmations: approve this USDC amount, then buy.'
            : 'First sell in this market needs two confirmations: let the market move your shares, then sell.'}
        </p>
      )}

      <button
        onClick={action.onClick}
        disabled={action.disabled}
        className={`flex items-center justify-center gap-2 rounded-xl bg-white py-3 text-sm font-semibold text-black hover:bg-zinc-200 disabled:cursor-not-allowed disabled:bg-raised disabled:text-muted ${press} ${focus}`}
      >
        {action.label}
      </button>

      {step === 'done' && (
        <p className="flex items-center justify-between rounded-lg bg-yes-soft px-3 py-2 text-sm text-yes">
          <span className="flex items-center gap-1.5"><Check size={15} /> {result.text}</span>
          <a href={basescanTx(result.tx!)} target="_blank" rel="noreferrer" className="flex items-center gap-0.5 underline-offset-2 hover:underline">
            Basescan <ArrowUpRight size={13} />
          </a>
        </p>
      )}
      {step === 'failed' && (
        <p role="alert" className="flex items-center gap-1.5 rounded-lg bg-no-soft px-3 py-2 text-sm text-no">
          <TriangleAlert size={15} className="shrink-0" /> {result.text}
        </p>
      )}

      <p className="text-xs text-muted">
        Winning shares redeem for 1 USDC each, losing shares for 0. Estimates can change before your wallet confirms.
      </p>
    </div>
  )
}

