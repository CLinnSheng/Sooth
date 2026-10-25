import { useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { BaseError, UserRejectedRequestError, type Hex } from 'viem'
import { useWriteContract } from 'wagmi'
import { waitForTransactionReceipt } from 'wagmi/actions'
import { config } from './wagmi'

// One button's transactions: a run is one or more confirms in order (e.g. approve, then dispute),
// stopping at the first rejection, failure or revert.
export function useTransaction() {
  const queryClient = useQueryClient()
  const { writeContractAsync: write } = useWriteContract()
  const [pending, setPending] = useState<string | null>(null)
  const [error, setError] = useState('')

  // Waits until mined, so the next transaction in the run sees this one's effects.
  const confirm = async (label: string, hash: Promise<Hex>) => {
    setPending(label)
    const receipt = await waitForTransactionReceipt(config, { hash: await hash })
    if (receipt.status === 'reverted') throw new Error(`Transaction reverted: ${receipt.transactionHash}`)
    return receipt
  }

  const run = async (steps: () => Promise<unknown>) => {
    setError('')
    try {
      await steps()
    } catch (e) {
      // A wallet rejection is the user's choice, not an error worth showing.
      if (!(e instanceof BaseError && e.walk((x) => x instanceof UserRejectedRequestError)))
        setError(e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : 'Transaction failed')
    } finally {
      setPending(null)
      // Settling moves market state, pools, balances and allowances, so every read refetches.
      await queryClient.invalidateQueries()
    }
  }

  return { write, confirm, run, pending, error }
}
