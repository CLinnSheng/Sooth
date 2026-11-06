import { LoaderCircle } from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { BaseError, ContractFunctionRevertedError, erc20Abi, formatUnits, parseUnits, zeroAddress, type Address } from 'viem'
import { useAccount, useReadContract, useReadContracts, useSwitchChain } from 'wagmi'
import { baseSepolia } from 'wagmi/chains'
import { ORDER_BOOK, OUTCOME_TOKEN, USDC, marketAbi, orderBookAbi, outcomeTokenAbi } from './contracts'
import { cents, shortAddr, usdc, type Market, type Outcome } from './mock'
import { useTransaction } from './tx'
import { useWallet } from './wallet'

const DECIMALS = 6 // shares and mUSDC both use 6 decimals
const PRICE_SCALE = 1_000_000n // OutcomeOrderBook.PRICE_SCALE: 1 mUSDC per whole share
const MAX_LISTINGS = 20n // gas bound for buy: listings touched in one transaction
const SHOWN = 20 // listings shown in the book, cheapest first
// Deeper than the shown book, so a seller still finds a listing that sits behind the cheapest 20.
const DEPTH = 100n
const REFETCH_MS = 30_000

const outcomeIndex = (o: Outcome) => (o === 'YES' ? 0 : 1) // IMarket.Outcome
const toUnits = (input: string) => (Number(input) > 0 ? parseUnits(input, DECIMALS) : 0n)
const amountText = (raw: bigint) => usdc(Number(formatUnits(raw, DECIMALS)))
const priceText = (raw: bigint) => cents(Number(formatUnits(raw, DECIMALS)), 1)
const validPrice = (raw: bigint) => raw > 0n && raw < PRICE_SCALE

// Plain words for the order book's custom errors and the transfer errors it bubbles up.
const ERROR_TEXT: Record<string, string> = {
  MarketNotOpen: 'Order-book trading is closed for this market.',
  NotFactoryMarket: 'This market was not created by the Sooth factory.',
  ZeroAmount: 'Enter an amount above zero.',
  InvalidPrice: 'Price must be above 0 and below 1 USDC.',
  NotSeller: 'Only the seller can cancel this listing.',
  ListingNotFound: 'That listing was already filled or cancelled.',
  NothingFilled: 'Nothing is listed at or below your max price any more.',
  ERC1155InsufficientBalance: 'You do not hold that many shares.',
  ERC1155MissingApprovalForAll: 'The order book is not approved to move your shares.',
  ERC20InsufficientBalance: 'Not enough mUSDC.',
  ERC20InsufficientAllowance: 'Listings changed after your approval and the cost went up. Try again.',
}

// Rethrows a known revert as its plain message; anything else (a wallet rejection too) passes through for useTransaction.
async function explained(steps: () => Promise<unknown>) {
  try {
    await steps()
  } catch (e) {
    const revert = e instanceof BaseError ? e.walk((x) => x instanceof ContractFunctionRevertedError) : null
    const name = revert instanceof ContractFunctionRevertedError ? revert.data?.errorName : undefined
    throw name && ERROR_TEXT[name] ? new Error(ERROR_TEXT[name]) : e
  }
}

type Props = { market: Market; outcome: Outcome; setOutcome: (o: Outcome) => void }

// Hidden until the order book is deployed and its address is set in contracts.ts.
export function OrderBookPanel(props: Props) {
  if (ORDER_BOOK === zeroAddress) return null
  return <OrderBook {...props} />
}

function OrderBook({ market, outcome, setOutcome }: Props) {
  const { wallet, connect } = useWallet()
  const { address, chain } = useAccount()
  const { switchChain, isPending: isSwitchingChain } = useSwitchChain()
  const buyTx = useTransaction()
  const listTx = useTransaction()
  const cancelTx = useTransaction()
  const [shares, setShares] = useState('')
  const [maxPrice, setMaxPrice] = useState('')
  const [listAmount, setListAmount] = useState('')
  const [listPrice, setListPrice] = useState('')

  const book = { address: ORDER_BOOK, abi: orderBookAbi } as const
  const marketAddress = market.address as Address
  const side = outcomeIndex(outcome)
  const owner = address ?? zeroAddress
  // Only list and buy need Open; cancel works in every state, so shares are never stuck here.
  const isOpen = market.status === 'open'

  const { data: tokenId } = useReadContract({
    address: marketAddress,
    abi: marketAbi,
    functionName: outcome === 'YES' ? 'yesTokenId' : 'noTokenId',
  })
  const { data: head } = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...book, functionName: 'bestPrice', args: [marketAddress, side] },
      { ...book, functionName: 'listingsOf', args: [marketAddress, side, 0n, DEPTH] },
    ],
    query: { refetchInterval: REFETCH_MS },
  })
  const [best, ids] = head ?? [0n, []]
  const { data: listings } = useReadContracts({
    allowFailure: false,
    contracts: ids.map((id) => ({ ...book, functionName: 'getListing', args: [id] }) as const),
    query: { enabled: ids.length > 0, refetchInterval: REFETCH_MS },
  })
  const { data: reads } = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: [owner] },
      { address: USDC, abi: erc20Abi, functionName: 'allowance', args: [owner, ORDER_BOOK] },
      { address: OUTCOME_TOKEN, abi: outcomeTokenAbi, functionName: 'isApprovedForAll', args: [owner, ORDER_BOOK] },
      { address: OUTCOME_TOKEN, abi: outcomeTokenAbi, functionName: 'balanceOf', args: [owner, tokenId ?? 0n] },
    ],
    query: { enabled: Boolean(address && tokenId !== undefined) },
  })
  const [usdcRaw, allowance, isListApproved, heldRaw] = reads ?? [0n, 0n, false, 0n]
  // Until the wallet reads arrive, the zeros above are placeholders, not real balances.
  const balancesLoaded = reads !== undefined

  const sharesRaw = toUnits(shares)
  const maxPriceRaw = toUnits(maxPrice)
  const { data: quote } = useReadContract({
    ...book,
    functionName: 'quoteBuy',
    args: [marketAddress, side, sharesRaw, maxPriceRaw, MAX_LISTINGS],
    query: { enabled: isOpen && sharesRaw > 0n && validPrice(maxPriceRaw) },
  })
  const [quotedShares, quotedCost] = quote ?? [0n, 0n]

  const rows = (listings ?? []).map((l, i) => ({ id: ids[i], ...l })).filter((l) => l.remaining > 0n)
  const isMine = (seller: string) => seller.toLowerCase() === address?.toLowerCase()
  const mine = rows.filter((l) => isMine(l.seller))
  const shown = isOpen ? rows.slice(0, SHOWN) : mine
  const deeperMine = isOpen ? mine.filter((l) => !shown.includes(l)) : []

  // Approves exactly the quoted cost when short; if listings change first, buy reverts instead of overpaying.
  const buy = () =>
    buyTx.run(() =>
      explained(async () => {
        if (allowance < quotedCost)
          await buyTx.confirm('Approving mUSDC…', buyTx.write({ address: USDC, abi: erc20Abi, functionName: 'approve', args: [ORDER_BOOK, quotedCost] }))
        await buyTx.confirm('Buying…', buyTx.write({ ...book, functionName: 'buy', args: [marketAddress, side, sharesRaw, maxPriceRaw, MAX_LISTINGS] }))
        setShares('')
      }),
    )

  const listAmountRaw = toUnits(listAmount)
  const listPriceRaw = toUnits(listPrice)
  const list = () =>
    listTx.run(() =>
      explained(async () => {
        if (!isListApproved)
          await listTx.confirm(
            'Approving shares…',
            listTx.write({ address: OUTCOME_TOKEN, abi: outcomeTokenAbi, functionName: 'setApprovalForAll', args: [ORDER_BOOK, true] }),
          )
        await listTx.confirm('Listing…', listTx.write({ ...book, functionName: 'list', args: [marketAddress, side, listAmountRaw, listPriceRaw] }))
        setListAmount('')
        setListPrice('')
      }),
    )

  const cancel = (id: bigint) =>
    cancelTx.run(() => explained(() => cancelTx.confirm('Cancelling…', cancelTx.write({ ...book, functionName: 'cancel', args: [id] }))))

  // The first blocker wins, the same order as the trade panel: wallet, chain, input, balance.
  const gate = (): Action | null => {
    if (!wallet) return { label: 'Connect wallet', onClick: connect }
    if (!chain)
      return {
        label: isSwitchingChain ? 'Switching…' : 'Switch to Base Sepolia',
        onClick: () => switchChain({ chainId: baseSepolia.id }),
        disabled: isSwitchingChain,
      }
    return null
  }

  let buyAction: Action
  if (gate()) buyAction = gate()!
  else if (buyTx.pending) buyAction = { label: busy(buyTx.pending), disabled: true }
  else if (sharesRaw <= 0n) buyAction = { label: 'Enter shares', disabled: true }
  else if (!validPrice(maxPriceRaw)) buyAction = { label: 'Max price must be between 0 and 1', disabled: true }
  else if (!quote) buyAction = { label: 'Quoting…', disabled: true }
  else if (quotedShares === 0n) buyAction = { label: 'Nothing listed at or below that price', disabled: true }
  else if (!balancesLoaded) buyAction = { label: 'Loading balances…', disabled: true }
  else if (quotedCost > usdcRaw) buyAction = { label: 'Not enough mUSDC', disabled: true }
  else if (allowance < quotedCost) buyAction = { label: 'Approve mUSDC, then buy', onClick: buy }
  else buyAction = { label: `Buy ${amountText(quotedShares)} ${outcome}`, onClick: buy }

  let listAction: Action
  if (gate()) listAction = gate()!
  else if (listTx.pending) listAction = { label: busy(listTx.pending), disabled: true }
  else if (listAmountRaw <= 0n) listAction = { label: 'Enter an amount', disabled: true }
  else if (!balancesLoaded) listAction = { label: 'Loading balances…', disabled: true }
  else if (listAmountRaw > heldRaw) listAction = { label: `You hold ${amountText(heldRaw)} ${outcome}`, disabled: true }
  else if (!validPrice(listPriceRaw)) listAction = { label: 'Price must be between 0 and 1', disabled: true }
  else if (!isListApproved) listAction = { label: 'Approve shares, then list', onClick: list }
  else listAction = { label: `List ${amountText(listAmountRaw)} ${outcome} at ${priceText(listPriceRaw)}`, onClick: list }

  return (
    <div className="flex flex-col gap-4 rounded-3xl bg-surface p-5">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="font-semibold">Trade with others</h2>
        <span className="text-sm text-muted">Best {outcome} price: {best > 0n ? priceText(best) : '—'}</span>
      </div>
      <p className="text-sm text-muted">
        Buy shares other holders listed, or list yours at your own price. Listed shares wait here until bought or cancelled. No fee.
      </p>

      <div className="grid grid-cols-2 rounded-xl bg-raised p-1 text-sm">
        {(['YES', 'NO'] as const).map((o) => (
          <button
            key={o}
            aria-pressed={outcome === o}
            onClick={() => setOutcome(o)}
            className={`rounded-lg py-1.5 ${outcome === o ? `bg-[#636366] font-semibold ${o === 'YES' ? 'text-yes' : 'text-no'}` : 'text-muted'}`}
          >
            {o === 'YES' ? 'Yes' : 'No'}
          </button>
        ))}
      </div>

      {!isOpen && (
        <p className="text-sm text-muted">Order-book trading is closed for this market. You can still cancel your listings to get your shares back.</p>
      )}

      <div className="flex flex-col gap-2">
        <h3 className="text-sm font-semibold">{isOpen ? `${outcome} listings, cheapest first` : `Your ${outcome} listings`}</h3>
        <ListingRows rows={shown} isMine={isMine} onCancel={cancel} pending={cancelTx.pending} empty={isOpen ? 'No listings yet.' : 'You have no listings.'} />
        {deeperMine.length > 0 && (
          <>
            <h3 className="text-sm font-semibold">Your other {outcome} listings</h3>
            <ListingRows rows={deeperMine} isMine={isMine} onCancel={cancel} pending={cancelTx.pending} empty="" />
          </>
        )}
        <TxError error={cancelTx.error} />
      </div>

      {isOpen && (
        <div className="grid gap-4 border-t border-line pt-4 sm:grid-cols-2">
          <div className="flex flex-col gap-2">
            <h3 className="text-sm font-semibold">Buy {outcome}</h3>
            <Field id="ob-shares" label="Shares" unit={outcome} value={shares} onChange={setShares} />
            <Field id="ob-max-price" label="Max price per share" unit="USDC" placeholder="0.50" value={maxPrice} onChange={setMaxPrice} />
            {quote && quotedShares > 0n && (
              <div className="flex flex-col gap-1 text-sm">
                <Row label="Fills" value={`${amountText(quotedShares)}${quotedShares < sharesRaw ? ` of ${amountText(sharesRaw)}` : ''} ${outcome}`} />
                <Row label="Total cost" value={`${amountText(quotedCost)} USDC`} />
                <Row label="Avg price" value={cents(Number(quotedCost) / Number(quotedShares), 1)} />
              </div>
            )}
            <ActionButton action={buyAction} />
            <TxError error={buyTx.error} />
          </div>
          <div className="flex flex-col gap-2">
            <h3 className="text-sm font-semibold">List {outcome}</h3>
            <Field id="ob-list-amount" label="Shares" unit={outcome} hint={wallet ? `You hold ${amountText(heldRaw)}` : undefined} value={listAmount} onChange={setListAmount} />
            <Field id="ob-list-price" label="Price per share" unit="USDC" placeholder="0.50" value={listPrice} onChange={setListPrice} />
            {listAmountRaw > 0n && validPrice(listPriceRaw) && (
              // The seller gets at least amount x price: each fill rounds up in the seller's favour.
              <Row label="You receive if all sell (at least)" value={`${amountText((listAmountRaw * listPriceRaw) / PRICE_SCALE)} USDC`} />
            )}
            <ActionButton action={listAction} />
            <TxError error={listTx.error} />
          </div>
        </div>
      )}
    </div>
  )
}

type Action = { label: ReactNode; onClick?: () => void; disabled?: boolean }
type ListingRow = { id: bigint; seller: Address; price: bigint; remaining: bigint }

const busy = (label: string) => <><LoaderCircle size={14} className="animate-spin" /> {label}</>

function ListingRows({ rows, isMine, onCancel, pending, empty }: {
  rows: ListingRow[]
  isMine: (seller: string) => boolean
  onCancel: (id: bigint) => void
  pending: string | null
  empty: string
}) {
  if (!rows.length) return empty ? <p className="text-sm text-muted">{empty}</p> : null
  return (
    <ul className="divide-y divide-line text-sm">
      {rows.map((l) => (
        <li key={l.id.toString()} className="grid grid-cols-[4rem_1fr_auto] items-center gap-3 py-2 tabular-nums">
          <span className="font-medium">{priceText(l.price)}</span>
          <span className="text-muted">
            {amountText(l.remaining)} shares · {shortAddr(l.seller)}
            {isMine(l.seller) && <span className="ml-1.5 rounded bg-raised px-1.5 py-0.5 text-xs text-white">yours</span>}
          </span>
          {isMine(l.seller) ? (
            <button
              onClick={() => onCancel(l.id)}
              disabled={pending !== null}
              className="rounded-lg bg-raised px-2.5 py-1 text-xs font-medium hover:bg-white/15 disabled:cursor-not-allowed disabled:text-muted"
            >
              {pending ? busy(pending) : 'Cancel'}
            </button>
          ) : (
            <span />
          )}
        </li>
      ))}
    </ul>
  )
}

function Field({ id, label, unit, hint, placeholder = '0.00', value, onChange }: {
  id: string
  label: string
  unit: string
  hint?: string
  placeholder?: string
  value: string
  onChange: (v: string) => void
}) {
  return (
    <div className="flex flex-col gap-1">
      <div className="flex justify-between text-xs text-muted">
        <label htmlFor={id}>{label}</label>
        {hint && <span>{hint}</span>}
      </div>
      <div className="flex items-center rounded-xl bg-raised px-3 ring-white/30 focus-within:ring-1">
        <input
          id={id}
          inputMode="decimal"
          placeholder={placeholder}
          value={value}
          // Six decimals at most: both shares and mUSDC prices are 6-decimal units.
          onChange={(e) => { if (/^\d*\.?\d{0,6}$/.test(e.target.value)) onChange(e.target.value) }}
          className="w-full bg-transparent py-2.5 font-semibold outline-none"
        />
        <span className="text-sm text-muted">{unit}</span>
      </div>
    </div>
  )
}

function Row({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex justify-between">
      <span className="text-muted">{label}</span>
      <span>{value}</span>
    </div>
  )
}

function ActionButton({ action }: { action: Action }) {
  return (
    <button
      onClick={action.onClick}
      disabled={action.disabled}
      className="flex items-center justify-center gap-1.5 rounded-xl bg-white py-2.5 text-sm font-semibold text-black hover:bg-zinc-200 active:scale-[0.98] disabled:cursor-not-allowed disabled:bg-raised disabled:text-muted"
    >
      {action.label}
    </button>
  )
}

function TxError({ error }: { error: string }) {
  return error ? <p role="alert" className="text-sm text-no">{error}</p> : null
}
