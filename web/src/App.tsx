import { useState } from 'react'
import { Route, Routes } from 'react-router'
import { Nav } from './components'
import { WalletContext } from './wallet'
import { WALLET } from './mock'
import Home from './pages/Home'
import Market from './pages/Market'
import Portfolio from './pages/Portfolio'

export default function App() {
  const [wallet, setWallet] = useState<{ address: string; usdc: number } | null>(null)
  const ctx = {
    wallet,
    connect: () => setWallet(WALLET),
    disconnect: () => setWallet(null),
    mint: () => setWallet((w) => w && { ...w, usdc: w.usdc + 100 }),
  }

  return (
    <WalletContext.Provider value={ctx}>
      <Nav />
      <main className="mx-auto max-w-6xl px-4 py-8">
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/market/:id" element={<Market />} />
          <Route path="/portfolio" element={<Portfolio />} />
          <Route path="*" element={<p className="text-zinc-500">Page not found.</p>} />
        </Routes>
      </main>
      <footer className="mx-auto flex max-w-6xl justify-between px-4 pb-8 text-xs text-zinc-400">
        <span>Illustrative markets · Testnet USDC · Not investment advice</span>
        <span>Base Sepolia</span>
      </footer>
    </WalletContext.Provider>
  )
}
