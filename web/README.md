# Sooth frontend

The Sooth frontend is a React and TypeScript application built with Vite. It reads market and resolver contracts on Base Sepolia and submits transactions through connected wallets.

## Setup and commands

Use Node.js `22.22.0` or later for the current lockfile. The project specifies npm `12.2.1` in `package.json`. From `web/`, install the locked dependencies and start the development server:

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

## Fund a test wallet

To buy shares, seed a market, or post an optimistic bond, the relevant wallet needs the configured MockUSDC collateral. The wallet sending each transaction also needs Base Sepolia ETH for gas. Ordinary USDC is a different token.

The configured test token provides a permissionless `mint(address,uint256)` function. With Foundry installed, set `RPC_URL` to a Base Sepolia RPC endpoint, `WALLET` to the recipient address, and `ACCOUNT` to a funded Foundry keystore name. This example sends a transaction that mints 100 MockUSDC to `WALLET`:

```sh
cast send 0x5f29331BBBA6f605942f5de0B217359F3C7B7c51 \
  'mint(address,uint256)' "$WALLET" 100000000 \
  --rpc-url "$RPC_URL" --account "$ACCOUNT"
```

MockUSDC uses six decimals, so `100000000` raw units represent 100 tokens. The address is the frontend's configured `USDC` in `src/contracts.ts`; check that configuration if the deployment changes. This mint function is specific to the test token and does not apply to arbitrary collateral.

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
