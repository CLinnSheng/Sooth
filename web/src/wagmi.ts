import { getDefaultConfig, type WalletList } from '@rainbow-me/rainbowkit'
import {
  injectedWallet,
  metaMaskWallet,
  phantomWallet,
  rabbyWallet,
  trustWallet,
  walletConnectWallet,
} from '@rainbow-me/rainbowkit/wallets'
import { http } from 'viem'
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
    [baseSepolia.id]: http(),
  },
  wallets,
})
