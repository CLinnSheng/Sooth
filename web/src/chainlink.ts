import { readContract } from 'wagmi/actions'
import type { Address } from 'viem'
import { aggregatorAbi } from './contracts'
import { config } from './wagmi'

// Proxy round ids are (phaseId << 64 | aggregatorRoundId).
const PHASE_OFFSET = 64n

// Last round updated at or before close, by binary search over the feed's current phase: the same
// algorithm as bot/sooth_bot/chainlink.py. The resolver re-checks the round, so a wrong answer only reverts.
export async function roundAtClose(feed: Address, closeTime: bigint): Promise<bigint> {
  const updatedAt = async (roundId: bigint) =>
    (await readContract(config, { address: feed, abi: aggregatorAbi, functionName: 'getRoundData', args: [roundId] }))[3]

  const [latest, , , latestUpdatedAt] = await readContract(config, { address: feed, abi: aggregatorAbi, functionName: 'latestRoundData' })
  if (latestUpdatedAt <= closeTime) return latest

  let low = ((latest >> PHASE_OFFSET) << PHASE_OFFSET) | 1n
  if ((await updatedAt(low)) > closeTime)
    throw new Error("The market closed before the feed's current phase: resolve it with ResolveChainlinkMarket.s.sol and ROUND_ID.")
  let high = latest
  // Invariant: low is at or before close, high is after it.
  while (high - low > 1n) {
    const mid = low + (high - low) / 2n
    if ((await updatedAt(mid)) <= closeTime) low = mid
    else high = mid
  }
  return low
}
