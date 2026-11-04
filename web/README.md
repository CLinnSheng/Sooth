# Sooth frontend

The Sooth frontend is a React and TypeScript application built with Vite. It reads market and resolver contracts on Base Sepolia and submits transactions through connected wallets.

## Setup and commands

Use a Node.js version supported by the installed Vite release: Node.js `^20.19.0` or `>=22.12.0`. The project specifies npm `12.2.1` in `package.json`. From `web/`, install the locked dependencies and start the development server:

```sh
npm ci
npm run dev
```

Other commands from `web/`:

| Command | Purpose |
|---|---|
| `npm run build` | Type-check and build the production bundle in `dist/`. |
| `npm run lint` | Run Oxlint. |
| `npm run preview` | Serve an existing production build locally. |

The package has no frontend test script. Contract tests are documented in the relevant guides linked below.

## Network and wallet configuration

The frontend targets Base Sepolia. `src/contracts.ts` contains the factory, collateral, outcome-token, and resolver addresses and the factory deployment block used for event scans. The configured collateral is the deployment's six-decimal MockUSDC. Running Vite locally still connects to these configured contracts; it does not automatically use a local chain or deployment. A different deployment requires updating the relevant network and contract configuration.

`src/wagmi.ts` configures the Base Sepolia RPC transport and wallet connectors. To enable WalletConnect, add a valid `VITE_WALLETCONNECT_PROJECT_ID` to `web/.env.local`; `web/.env.example` shows the variable name. If the variable is absent or empty, WalletConnect is disabled and injected browser-extension wallets remain available. The example value is a placeholder, not a project ID.

## Application and data flow

| Route | Purpose |
|---|---|
| `/` | Browse markets. |
| `/market/:id` | View a market, trade, inspect resolution, and claim eligible payouts. |
| `/portfolio` and `/portfolio/:address` | View positions and activity for the connected or specified address. |
| `/admin/create` | Create markets with a factory admin wallet. |
| `/admin/collect` | View and trigger eligible creator fee and liquidity withdrawals. |

The browser reads current market state from contracts and scans factory, market, and resolver events from the configured deployment block. It reconstructs trade history, price history, resolution requests, and payouts from those events. Market data refreshes every 30 seconds.

The event scan uses ranges of up to 10 million blocks and caches results in memory. RPC provider limits can affect the scan, and events from a chain reorganization remain cached until the page reloads. Portfolio average cost is calculated from recorded buys; sells do not adjust that average.

## Transaction workflows

- **Create:** The connected wallet must have the factory's `DEFAULT_ADMIN_ROLE` and approve seed collateral. For a Chainlink market, creation and feed configuration are separate transactions; the configuring wallet must also own the resolver. If configuration fails, the form offers a retry while its state is available, before the market closes.
- **Trade:** The buy flow approves collateral when needed; the sell flow approves the outcome-token operator when needed. The frontend calculates floating-point estimates and submits a minimum output and deadline. See the [trading engine](../docs/trading-engine.md) for contract calculations and execution conditions.
- **Resolve and collect:** The market page exposes actions appropriate to the selected resolver and wallet. The admin collection page can trigger eligible withdrawals, which the contracts pay to each market's creator. See [market settlement and payouts](../docs/market-settlement.md), the [Chainlink resolver](../docs/chainlink-resolver.md), and the [optimistic resolver](../docs/optimistic-resolver.md) for contract behavior and limitations.
