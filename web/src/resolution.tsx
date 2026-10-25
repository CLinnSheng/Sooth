import { ArrowUpRight, LoaderCircle } from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { erc20Abi, formatUnits, zeroAddress, type Address, type Hex } from 'viem'
import { useAccount, useReadContracts } from 'wagmi'
import { OPTIMISTIC_RESOLVER, USDC, marketAbi, optimisticResolverAbi } from './contracts'
import { basescanAddr, shortAddr, usdc, type Market, type Outcome, type ResolutionRequest } from './mock'
import { useTransaction } from './tx'

// Evidence is whatever the proposer or disputer attached. Anyone can write it, so it is decoded
// defensively and only ever rendered as text.
const EVIDENCE_PREFIX = 'data:application/json;base64,'
// The bot's bundles are a few KB; anything far larger is not worth decoding in the page.
const MAX_EVIDENCE_CHARS = 16_000
const MAX_RAW_CHARS = 500
export const MAX_NOTE_CHARS = 1_000

type Evidence = { reasoning?: string; model?: string; quotes: { url?: string; quote: string }[] }

const isHttpUrl = (url: string) => /^https?:\/\//.test(url)
const asString = (value: unknown) => (typeof value === 'string' ? value : undefined)

function decodeEvidence(uri: string): Evidence | null {
  if (!uri.startsWith(EVIDENCE_PREFIX) || uri.length > MAX_EVIDENCE_CHARS) return null
  try {
    // atob yields bytes; TextDecoder turns them back into UTF-8, so "4–2" survives.
    const bytes = Uint8Array.from(atob(uri.slice(EVIDENCE_PREFIX.length)), (c) => c.charCodeAt(0))
    const raw: unknown = JSON.parse(new TextDecoder().decode(bytes))
    if (typeof raw !== 'object' || raw === null) return null
    const { reasoning, model, evidence } = raw as Record<string, unknown>
    const quotes = (Array.isArray(evidence) ? evidence : []).flatMap((item) => {
      const { url, quote } = (item ?? {}) as Record<string, unknown>
      return typeof quote === 'string' ? [{ url: asString(url), quote }] : []
    })
    return { reasoning: asString(reasoning), model: asString(model), quotes }
  } catch {
    return null // malformed base64 or JSON: shown raw instead
  }
}

// A person's propose or dispute note, in the bot's bundle shape so one viewer reads both.
export function encodeNote(note: string): string {
  const bytes = new TextEncoder().encode(JSON.stringify({ reasoning: note.trim() }))
  return EVIDENCE_PREFIX + btoa(String.fromCharCode(...bytes))
}

export function EvidenceView({ uri }: { uri: string }) {
  if (!uri) return <p className="text-sm text-muted">No evidence attached.</p>
  const evidence = decodeEvidence(uri)
  if (!evidence) return <p className="break-all text-sm text-zinc-300">{uri.slice(0, MAX_RAW_CHARS)}</p>
  return (
    <div className="flex flex-col gap-2 text-sm">
      {evidence.reasoning && <p className="whitespace-pre-line text-zinc-300">{evidence.reasoning}</p>}
      {evidence.quotes.map((q, i) => (
        <blockquote key={i} className="border-l-2 border-line pl-3 text-zinc-300">
          “{q.quote}”
          {q.url && isHttpUrl(q.url) && (
            <a href={q.url} target="_blank" rel="noreferrer noopener" className="ml-1 inline-flex items-center gap-0.5 text-muted hover:underline">
              source <ArrowUpRight size={12} />
            </a>
          )}
        </blockquote>
      ))}
      {evidence.model && <p className="text-xs text-muted">Written by an AI agent ({evidence.model})</p>}
    </div>
  )
}

const OUTCOMES: Outcome[] = ['YES', 'NO']
const outcomeIndex = (o: Outcome) => (o === 'YES' ? 0 : 1) // IMarket.Outcome
// Browser time and block time can differ, so disputes stop a minute early rather than land late and revert.
const DISPUTE_MARGIN_SECS = 60
const SETTLED_TEXT = { finalized: 'Finalized: nobody disputed in time.', ruled: 'Ruled by the judge.', refunded: 'Bonds refunded: the market cancelled first.' }

// `now` is the page's load-time clock (unix seconds), so every check here uses one moment.
export function ResolutionPanel({ market, now }: { market: Market; now: number }) {
  const isOptimistic = market.arbitrator.toLowerCase() === OPTIMISTIC_RESOLVER.toLowerCase()
  return (
    <div className="flex flex-col gap-3 rounded-3xl bg-surface p-5">
      <h2 className="font-semibold">Resolution</h2>
      {isOptimistic ? <OptimisticResolution market={market} now={now} /> : <ArbitratorResolution market={market} />}
    </div>
  )
}

// A plain address as arbitrator (Admin's default): only that wallet can resolve, directly on the market.
function ArbitratorResolution({ market }: { market: Market }) {
  const { address } = useAccount()
  const tx = useTransaction()
  const isArbitrator = address?.toLowerCase() === market.arbitrator.toLowerCase()
  const resolve = (o: Outcome) =>
    tx.run(() =>
      tx.confirm(`Resolving ${o}…`, tx.write({ address: market.address as Address, abi: marketAbi, functionName: 'resolve', args: [outcomeIndex(o)] })),
    )
  return (
    <>
      <p className="text-sm text-muted">
        Resolved by <AddressLink address={market.arbitrator} />
        {isArbitrator && ' (you)'}.
      </p>
      {isArbitrator && market.status === 'closed' && (
        <div className="flex gap-2">
          {OUTCOMES.map((o) => <ActionButton key={o} label={`Resolve ${o}`} onClick={() => resolve(o)} pending={tx.pending} />)}
        </div>
      )}
      <TxError error={tx.error} />
    </>
  )
}

function OptimisticResolution({ market, now }: { market: Market; now: number }) {
  const { address } = useAccount()
  const tx = useTransaction()
  const [note, setNote] = useState('')
  const resolver = { address: OPTIMISTIC_RESOLVER, abi: optimisticResolverAbi } as const
  const { data } = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...resolver, functionName: 'bond' },
      { ...resolver, functionName: 'challengeWindow' },
      { ...resolver, functionName: 'owner' },
      { address: USDC, abi: erc20Abi, functionName: 'allowance', args: [address ?? zeroAddress, OPTIMISTIC_RESOLVER] },
    ],
  })
  if (!data) return <p className="text-sm text-muted">Loading resolver…</p>

  const [bondRaw, windowRaw, judge, allowance] = data
  const bond = usdc(Number(formatUnits(bondRaw, 6)))
  const windowSecs = Number(windowRaw)
  const request = market.request
  const isJudge = address?.toLowerCase() === judge.toLowerCase()
  const marketAddress = market.address as Address
  const evidence = note.trim() ? encodeNote(note) : ''

  // Proposing and disputing each lock one bond; approve exactly that much first if needed.
  const bonded = (label: string, send: () => Promise<Hex>) =>
    tx.run(async () => {
      if (allowance < bondRaw)
        await tx.confirm('Approving bond…', tx.write({ address: USDC, abi: erc20Abi, functionName: 'approve', args: [OPTIMISTIC_RESOLVER, bondRaw] }))
      await tx.confirm(label, send())
      setNote('')
    })
  const plain = (label: string, send: () => Promise<Hex>) => tx.run(() => tx.confirm(label, send()))

  const propose = (o: Outcome) =>
    bonded(`Proposing ${o}…`, () => tx.write({ ...resolver, functionName: 'propose', args: [marketAddress, outcomeIndex(o), evidence] }))
  const dispute = () => bonded('Disputing…', () => tx.write({ ...resolver, functionName: 'dispute', args: [marketAddress, evidence] }))
  const finalize = () => plain('Finalizing…', () => tx.write({ ...resolver, functionName: 'finalize', args: [marketAddress] }))
  const refund = () => plain('Refunding…', () => tx.write({ ...resolver, functionName: 'refund', args: [marketAddress] }))
  const rule = (o: Outcome) => plain(`Ruling ${o}…`, () => tx.write({ ...resolver, functionName: 'rule', args: [marketAddress, outcomeIndex(o)] }))

  const noteField = (placeholder: string) => (
    <textarea
      rows={2}
      maxLength={MAX_NOTE_CHARS}
      value={note}
      onChange={(e) => setNote(e.target.value)}
      placeholder={placeholder}
      className="w-full rounded-xl bg-raised px-3 py-2 text-sm outline-none ring-white/30 focus:ring-1"
    />
  )

  let action: ReactNode = null
  if (market.status === 'open')
    action = (
      <p className="text-sm text-muted">
        After close, anyone can propose the outcome with a {bond} USDC bond. Undisputed for {duration(windowSecs)}, it stands;
        a dispute goes to the judge, and the side proven wrong loses its bond.
      </p>
    )
  else if (!request && market.status === 'cancelled') action = <p className="text-sm text-muted">Nobody proposed before the deadline.</p>
  else if (!request && now + windowSecs >= market.resolutionDeadline)
    action = <p className="text-sm text-muted">Too late to propose: the market cancels at its deadline.</p>
  else if (!request)
    action = (
      <>
        <p className="text-sm text-muted">Waiting for a proposal. Propose with a {bond} USDC bond, returned if nobody proves you wrong.</p>
        {noteField('Evidence: link or explanation (optional)')}
        <div className="flex gap-2">
          {OUTCOMES.map((o) => <ActionButton key={o} label={`Propose ${o}`} onClick={() => propose(o)} pending={tx.pending} />)}
        </div>
      </>
    )
  else if (request.status !== 'settled' && market.status === 'cancelled')
    action = <ActionButton label="Refund bonds" onClick={refund} pending={tx.pending} />
  else if (request.status === 'proposed' && now < request.proposedAt + windowSecs - DISPUTE_MARGIN_SECS)
    action = (
      <>
        <p className="text-sm text-muted">
          Challenge ends in {duration(request.proposedAt + windowSecs - now)}. Think it's wrong? Dispute with a {bond} USDC bond.
        </p>
        {noteField('Why the proposal is wrong (optional)')}
        <ActionButton label="Dispute" onClick={dispute} pending={tx.pending} />
      </>
    )
  else if (request.status === 'proposed' && now >= request.proposedAt + windowSecs)
    action = <ActionButton label="Finalize" onClick={finalize} pending={tx.pending} />
  else if (request.status === 'proposed') action = <p className="text-sm text-muted">Challenge window closing.</p>
  else if (request.status === 'disputed' && isJudge)
    action = (
      <div className="flex gap-2">
        {OUTCOMES.map((o) => <ActionButton key={o} label={`Rule ${o}`} onClick={() => rule(o)} pending={tx.pending} />)}
      </div>
    )
  else if (request.status === 'disputed') action = <p className="text-sm text-muted">Disputed: awaiting the judge's ruling.</p>
  else action = <p className="text-sm text-muted">{SETTLED_TEXT[request.settledBy!]}</p>

  return (
    <>
      {request && <RequestView request={request} />}
      {action}
      <TxError error={tx.error} />
    </>
  )
}

function RequestView({ request }: { request: ResolutionRequest }) {
  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-1.5">
        <p className="text-sm">
          Proposed <span className={request.outcome === 'YES' ? 'text-yes' : 'text-no'}>{request.outcome}</span> by{' '}
          <AddressLink address={request.proposer} />
        </p>
        <EvidenceView uri={request.proposalEvidence} />
      </div>
      {request.disputer && (
        <div className="flex flex-col gap-1.5 border-t border-line pt-3">
          <p className="text-sm">Disputed by <AddressLink address={request.disputer} /></p>
          <EvidenceView uri={request.disputeEvidence ?? ''} />
        </div>
      )}
    </div>
  )
}

function ActionButton({ label, onClick, pending }: { label: string; onClick: () => void; pending: string | null }) {
  return (
    <button
      onClick={onClick}
      disabled={pending !== null}
      className="flex flex-1 items-center justify-center gap-1.5 rounded-xl bg-white py-2.5 text-sm font-semibold text-black hover:bg-zinc-200 active:scale-[0.98] disabled:cursor-not-allowed disabled:bg-raised disabled:text-muted"
    >
      {pending ? <><LoaderCircle size={14} className="animate-spin" /> {pending}</> : label}
    </button>
  )
}

function AddressLink({ address }: { address: string }) {
  return (
    <a href={basescanAddr(address)} target="_blank" rel="noreferrer" className="font-medium hover:underline">
      {shortAddr(address)}
    </a>
  )
}

function TxError({ error }: { error: string }) {
  return error ? <p role="alert" className="text-sm text-no">{error}</p> : null
}

function duration(secs: number): string {
  const hours = Math.floor(secs / 3600)
  const minutes = Math.ceil((secs % 3600) / 60)
  return hours ? `${hours}h ${minutes}m` : `${minutes}m`
}
