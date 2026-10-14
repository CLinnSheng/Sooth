import { createContext, useContext } from 'react'

// Fake wallet. Replaced by wagmi's useAccount / useConnect later.
export type WalletState = {
  wallet: { address: string; usdc: number } | null
  connect: () => void
  disconnect: () => void
  mint: () => void
}
export const WalletContext = createContext<WalletState | null>(null)
export const useWallet = () => useContext(WalletContext)!
