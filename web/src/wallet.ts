import { createContext, createElement, useContext, type ReactNode } from 'react'
import { useConnectModal } from '@rainbow-me/rainbowkit'
import { erc20Abi, formatUnits, zeroAddress, type Address } from 'viem'
import { useAccount, useDisconnect, useReadContract } from 'wagmi'
import { baseSepolia } from 'wagmi/chains'

// Sooth's MockUSDC (mUSDC, 6 decimals), the collateral for every market.
const BASE_SEPOLIA_USDC: Address = '0x5f29331BBBA6f605942f5de0B217359F3C7B7c51'

export type WalletState = {
  // usdc is the wallet's mUSDC balance on Base Sepolia; null while loading,
  // on a read error, or when the wallet is on another network.
  wallet: { address: string; usdc: number | null } | null
  connect: () => void
  disconnect: () => void
}

const WalletContext = createContext<WalletState | null>(null)

export function WalletProvider({ children }: { children: ReactNode }) {
  const { address, chainId, isConnected } = useAccount()
  const { openConnectModal } = useConnectModal()
  const { disconnect } = useDisconnect()
  const { data: balance } = useReadContract({
    address: BASE_SEPOLIA_USDC,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [address ?? zeroAddress],
    chainId: baseSepolia.id,
    query: { enabled: Boolean(isConnected && address && chainId === baseSepolia.id) },
  })

  const value: WalletState = {
    wallet:
      isConnected && address
        ? { address, usdc: balance === undefined || chainId !== baseSepolia.id ? null : Number(formatUnits(balance, 6)) }
        : null,
    connect: () => openConnectModal?.(),
    disconnect: () => disconnect(),
  }

  return createElement(WalletContext.Provider, { value }, children)
}

export function useWallet() {
  const wallet = useContext(WalletContext)
  if (!wallet) throw new Error('useWallet must be used within WalletProvider')
  return wallet
}
