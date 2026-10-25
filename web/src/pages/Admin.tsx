import { useQueryClient } from '@tanstack/react-query'
import { LoaderCircle, TriangleAlert } from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { useNavigate } from 'react-router'
import { BaseError, UserRejectedRequestError, erc20Abi, isAddress, parseEventLogs, parseUnits, zeroAddress, type Address, type Hex } from 'viem'
import { useAccount, useReadContract, useSwitchChain, useWriteContract } from 'wagmi'
import { waitForTransactionReceipt } from 'wagmi/actions'
import { baseSepolia } from 'wagmi/chains'
import { parseSpec, useIsAdmin } from '../chain'
import { CHAINLINK_RESOLVER, FACTORY, OPTIMISTIC_RESOLVER, USDC, factoryAbi } from '../contracts'
import { categories, type Category } from '../mock'
import { useWallet } from '../wallet'
import { config } from '../wagmi'

// The factory only accepts a 50/50 opening price for now.
const FIFTY_FIFTY_BPS = 5_000
// Mirrors MarketFactory.MIN_LIQUIDITY.
const MIN_LIQUIDITY = 10
const USDC_DECIMALS = 6

// How the market settles: a resolver contract, or a wallet that resolves by hand.
const RESOLUTIONS = {
  optimistic: { label: 'AI bot + disputes (Optimistic)', hint: 'The bot proposes from the source URL after close; anyone can dispute; the judge rules.' },
  chainlink: { label: 'Chainlink price feed', hint: 'Configure the feed before close or the market cancels. CreateMarket.s.sol does both in one go.' },
  custom: { label: 'Custom address', hint: 'That wallet resolves YES or NO itself. Defaults to yours.' },
} as const
type Resolution = keyof typeof RESOLUTIONS

type Step = 'idle' | 'approving' | 'creating' | 'failed'

const field = 'w-full rounded-xl bg-raised px-3 py-2.5 text-sm outline-none ring-white/30 focus:ring-1'

export default function Admin() {
  const { wallet, connect } = useWallet()
  const { address, chain } = useAccount()
  const { switchChain, isPending: isSwitchingChain } = useSwitchChain()
  const { writeContractAsync } = useWriteContract()
  const queryClient = useQueryClient()
  const navigate = useNavigate()

  const [question, setQuestion] = useState('')
  const [category, setCategory] = useState<Category>(categories[0])
  const [rules, setRules] = useState('')
  const [sourceLabel, setSourceLabel] = useState('')
  const [sourceUrl, setSourceUrl] = useState('')
  const [closesAt, setClosesAt] = useState('')
  const [liquidity, setLiquidity] = useState('100')
  const [resolution, setResolution] = useState<Resolution>('optimistic')
  const [customArbitrator, setCustomArbitrator] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState('')

  const owner = address ?? zeroAddress
  const { data: isAdmin, isPending: isCheckingRole } = useIsAdmin(address)
  const { data: allowance = 0n } = useReadContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [owner, FACTORY],
    chainId: baseSepolia.id,
    query: { enabled: Boolean(address) },
  })

  if (!wallet)
    return (
      <p className="text-muted">
        Connect the admin wallet to create markets. <button onClick={connect} className="text-white underline">Connect</button>
      </p>
    )
  if (isCheckingRole) return <p className="text-muted">Checking admin role…</p>
  if (!isAdmin) return <p className="text-muted">Admin only. {wallet.address} cannot create markets.</p>

  // JSON.stringify keeps key order, and the round trip through parseSpec guarantees the market page can render it.
  const spec = JSON.stringify({ question: question.trim(), category, rules: rules.trim(), source: { label: sourceLabel.trim(), url: sourceUrl.trim() } })
  const isSpecValid = Boolean(question.trim() && rules.trim() && sourceLabel.trim() && parseSpec(spec))
  // datetime-local has no timezone, so the browser reads it as local time.
  const closeTime = closesAt ? Math.floor(new Date(closesAt).getTime() / 1000) : 0
  const liquidityAmount = Number(liquidity) || 0
  const liquidityRaw = liquidityAmount > 0 ? parseUnits(liquidity, USDC_DECIMALS) : 0n
  const arbitratorAddress = {
    optimistic: OPTIMISTIC_RESOLVER,
    chainlink: CHAINLINK_RESOLVER,
    custom: (customArbitrator.trim() || wallet.address) as Address,
  }[resolution]
  const needsApproval = allowance < liquidityRaw
  const busy = step === 'approving' || step === 'creating'

  const create = async () => {
    const confirm = (hash: Hex) => waitForTransactionReceipt(config, { hash })
    try {
      if (needsApproval) {
        setStep('approving')
        await confirm(await writeContractAsync({ address: USDC, abi: erc20Abi, functionName: 'approve', args: [FACTORY, liquidityRaw] }))
      }
      setStep('creating')
      const receipt = await confirm(
        await writeContractAsync({
          address: FACTORY,
          abi: factoryAbi,
          functionName: 'createMarket',
          args: [
            {
              arbitrator: arbitratorAddress,
              closeTime: BigInt(closeTime),
              initialYesProbabilityBps: FIFTY_FIFTY_BPS,
              spec,
              initialLiquidity: liquidityRaw,
            },
          ],
        }),
      )
      const [created] = parseEventLogs({ abi: factoryAbi, eventName: 'MarketCreated', logs: receipt.logs })
      // refetchQueries also runs inactive queries, so the market page opens with the new market loaded.
      await queryClient.refetchQueries({ queryKey: ['markets'] })
      navigate(`/market/${created.args.marketId}`)
    } catch (e) {
      // A wallet rejection is the user's choice, not an error worth showing.
      if (e instanceof BaseError && e.walk((x) => x instanceof UserRejectedRequestError)) return setStep('idle')
      setError(e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : 'Transaction failed')
      setStep('failed')
    } finally {
      queryClient.invalidateQueries({ queryKey: ['readContract'] })
    }
  }

  const isFormValid =
    isSpecValid &&
    closeTime > Date.now() / 1000 &&
    liquidityAmount >= MIN_LIQUIDITY &&
    liquidityAmount <= (wallet.usdc ?? 0) &&
    isAddress(arbitratorAddress)

  let action: { label: ReactNode; onClick?: () => void; disabled?: boolean }
  if (!chain)
    action = {
      label: isSwitchingChain ? <><LoaderCircle size={16} className="animate-spin" /> Switching…</> : 'Switch to Base Sepolia',
      onClick: () => switchChain({ chainId: baseSepolia.id }),
      disabled: isSwitchingChain,
    }
  else if (step === 'approving') action = { label: <><LoaderCircle size={16} className="animate-spin" /> Approving USDC…</>, disabled: true }
  else if (step === 'creating') action = { label: <><LoaderCircle size={16} className="animate-spin" /> Creating market…</>, disabled: true }
  else action = { label: 'Approve', onClick: create, disabled: !isFormValid }

  const label = (text: string, input: ReactNode, hint?: string) => (
    <label className="flex flex-col gap-1.5 text-sm">
      <span className="text-xs text-muted">{text}</span>
      {input}
      {hint && <span className="text-xs text-muted">{hint}</span>}
    </label>
  )

  return (
    <div className="mx-auto flex max-w-xl flex-col gap-4 rounded-3xl bg-surface p-6">
      <h1 className="text-2xl font-bold tracking-tight">Create market</h1>
      <fieldset disabled={busy} className="flex flex-col gap-4">
        {label('Question', <input value={question} onChange={(e) => setQuestion(e.target.value)} className={field} />)}
        {label(
          'Category',
          <select value={category} onChange={(e) => setCategory(e.target.value as Category)} className={field}>
            {categories.map((c) => <option key={c}>{c}</option>)}
          </select>,
        )}
        {label('Resolution rules', <textarea rows={4} value={rules} onChange={(e) => setRules(e.target.value)} className={field} />)}
        <div className="grid gap-4 sm:grid-cols-2">
          {label('Source label', <input value={sourceLabel} onChange={(e) => setSourceLabel(e.target.value)} className={field} />)}
          {label('Source URL', <input type="url" placeholder="https://" value={sourceUrl} onChange={(e) => setSourceUrl(e.target.value)} className={field} />)}
        </div>
        {label(
          'Closes at (your local time)',
          <input type="datetime-local" value={closesAt} onChange={(e) => setClosesAt(e.target.value)} className={field} />,
          closeTime ? new Date(closeTime * 1000).toUTCString() : undefined,
        )}
        <div className="grid gap-4 sm:grid-cols-2">
          {label(
            'Seed liquidity (USDC)',
            <input
              inputMode="decimal"
              value={liquidity}
              onChange={(e) => { if (/^\d*\.?\d{0,6}$/.test(e.target.value)) setLiquidity(e.target.value) }}
              className={field}
            />,
            `Balance ${wallet.usdc == null ? '—' : wallet.usdc} USDC`,
          )}
          {label(
            'Resolution',
            <select value={resolution} onChange={(e) => setResolution(e.target.value as Resolution)} className={field}>
              {Object.entries(RESOLUTIONS).map(([value, { label }]) => <option key={value} value={value}>{label}</option>)}
            </select>,
            RESOLUTIONS[resolution].hint,
          )}
        </div>
        {resolution === 'custom' &&
          label('Arbitrator address', <input placeholder={wallet.address} value={customArbitrator} onChange={(e) => setCustomArbitrator(e.target.value)} className={field} />)}
      </fieldset>

      <button
        onClick={action.onClick}
        disabled={action.disabled}
        className="flex items-center justify-center gap-2 rounded-xl bg-white py-3 text-sm font-semibold text-black hover:bg-zinc-200 disabled:cursor-not-allowed disabled:bg-raised disabled:text-muted"
      >
        {action.label}
      </button>
      {step === 'failed' && (
        <p role="alert" className="flex items-center gap-1.5 rounded-lg bg-no-soft px-3 py-2 text-sm text-no">
          <TriangleAlert size={15} className="shrink-0" /> {error}
        </p>
      )}
    </div>
  )
}
