import { createContext, createElement, useContext, type ReactNode } from 'react'
import { useConnectModal } from '@rainbow-me/rainbowkit'
import { erc20Abi, formatUnits, zeroAddress, type Address } from 'viem'
import { useAccount, useDisconnect, useReadContract } from 'wagmi'
import { baseSepolia } from 'wagmi/chains'

const BASE_SEPOLIA_USDC: Address = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'

export type WalletState = {
  // usdc is the wallet's Circle USDC balance on Base Sepolia; null while loading,
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
