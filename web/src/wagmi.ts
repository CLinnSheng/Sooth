import { getDefaultConfig, type WalletList } from '@rainbow-me/rainbowkit'
import {
  injectedWallet,
  metaMaskWallet,
  phantomWallet,
  rabbyWallet,
  trustWallet,
  walletConnectWallet,
} from '@rainbow-me/rainbowkit/wallets'
import { fallback, http } from 'viem'
import { baseSepolia } from 'wagmi/chains'

const projectId = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID?.trim()

if (!projectId) {
  console.warn(
    'VITE_WALLETCONNECT_PROJECT_ID is missing; WalletConnect is disabled. Browser extension wallets remain available.',
  )
}

const wallets: WalletList = projectId
  ? [
      {
        groupName: 'Browser and mobile wallets',
        wallets: [metaMaskWallet, trustWallet, rabbyWallet, phantomWallet, walletConnectWallet],
      },
    ]
  : [{ groupName: 'Browser extensions', wallets: [injectedWallet] }]

export const config = getDefaultConfig({
  appName: 'Sooth',
  projectId: projectId ?? '',
  chains: [baseSepolia],
  multiInjectedProviderDiscovery: true,
  transports: {
    // sepolia.base.org caps eth_getLogs at 200 blocks; Tenderly's public gateway takes 1M+ and needs
    // no key. batch packs the per-market reads into one HTTP request. Falls back to the default RPC for plain reads.
    [baseSepolia.id]: fallback([http('https://base-sepolia.gateway.tenderly.co', { batch: true }), http()]),
  },
  wallets,
})
