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
    // sepolia.base.org caps eth_getLogs at 200 blocks; publicnode allows 50k. batch packs the
    // per-market reads into one HTTP request. Falls back to the default RPC for plain reads.
    // Fail fast, don't retry for minutes: with the defaults, a hanging
    // publicnode request could be retried across both transports and then
    // again by React Query, turning one hiccup into minutes of
    // "Loading markets…". A 10s timeout with no per-transport retry means
    // the fallback is tried once, quickly, and a genuinely dead RPC shows
    // an error (and a 30s refetch retries it) instead of hanging.
    [baseSepolia.id]: fallback(
      [
        http('https://base-sepolia-rpc.publicnode.com', { batch: true, timeout: 10_000, retryCount: 0 }),
        http('https://sepolia.base.org', { timeout: 10_000, retryCount: 0 }),
      ],
      { retryCount: 0, retryDelay: 500 },
    ),
  },
  wallets,
})
