# Sooth

Sooth is a binary prediction-market application. Admins create markets with YES and NO outcome shares, traders buy and sell shares through a constant-product AMM, and holders redeem eligible shares after resolution or cancellation. Each market has its own contract and collateral balance.

Markets can use a Chainlink price feed, an optimistic proposal and dispute process, or a custom wallet or contract address as arbitrator. The frontend connects to Base Sepolia; an off-chain bot can attempt Chainlink resolution and optimistic proposals and settlement.

Try it live at [sooth.deva16z.workers.dev](https://sooth.deva16z.workers.dev/).

## Features

- Admin-created binary markets with shared ERC-1155 outcome tokens and collateral-backed liquidity.
- YES/NO trading with reserve-based prices, quotes, slippage limits, and a 1% fee.
- Chainlink price-feed resolution, bonded optimistic proposals and disputes, or a custom arbitrator address.
- Share redemption after resolution or cancellation, and creator liquidity and fee withdrawals.
- A web interface for markets and portfolios, plus an optional bot for resolution attempts and dispute alerts.

## Components

| Directory | Purpose |
|---|---|
| [`contracts/`](contracts/) | Solidity market, outcome-token, factory, and resolver contracts; Foundry scripts and tests. |
| [`web/`](web/) | React and TypeScript frontend for browsing, trading, administration, and payouts. |
| [`bot/`](bot/) | Python worker for resolution attempts, proposals, settlement, and dispute alerts. |
| [`docs/`](docs/) | Contract behavior, resolver operation, and design details. |

## Prerequisites

- Foundry for contract builds and tests; the project configures Solidity `0.8.28`.
- Node.js and npm for the frontend. See the [frontend guide](web/README.md) for supported versions.
- Python 3.12 or later, `uv`, and Chromium for the optional bot. See the [bot guide](bot/README.md) for installation and configuration.

## Try it locally

To run Sooth yourself, clone the repository with its Foundry dependencies. The SSH URL requires access to GitHub over SSH:

```sh
git clone --recursive git@github.com:CLinnSheng/Sooth.git
cd Sooth
```

The recursive clone includes the Forge Standard Library and OpenZeppelin contract dependencies. For an existing checkout, fetch them with `git submodule update --init --recursive`.
Run each component's commands below from the repository root.

### Contracts

Install Foundry, then build and test the contracts from `contracts/`:

```sh
cd contracts
forge build
forge test
```

See [market creation](docs/market-creation-explained.md) for factory deployment and the resolver guides below for resolver deployment and operation.

### Frontend

From `web/`, install dependencies and start Vite:

```sh
cd web
npm ci
npm run dev
```

The frontend uses the Base Sepolia contract addresses configured in `web/src/contracts.ts`, including a MockUSDC collateral token. Starting it locally does not connect it to a local chain. WalletConnect is optional; see the [frontend guide](web/README.md) for Node.js requirements, configuration, build commands, and data-flow limitations.

### Bot

The bot requires contract build artifacts and deployment-specific configuration. Follow the [bot guide](bot/README.md) to configure and run it. The frontend and contracts can be used without running the bot, but automated resolution attempts depend on the bot being available.

## Usage

Connect a wallet on Base Sepolia to buy or sell shares and redeem eligible payouts on a market page. An admin wallet can create markets and trigger creator withdrawals. Chainlink markets require feed configuration; optimistic markets use bonded proposals and may be disputed. A custom arbitrator must call the market's `resolve` function directly or through its own contract logic.

See the [frontend guide](web/README.md) for wallet configuration and workflows, and the resolver guides below for resolution procedures and limitations.

## Testing

Run these commands from the repository root:

```sh
(cd contracts && forge test)
(cd web && npm run lint)
(cd bot && uv run pytest)
```

The frontend also provides `npm run build` for type-checking and a production build. The bot's browser tests can be skipped if Chromium is not installed. See the [frontend](web/README.md) and [bot](bot/README.md) guides for their prerequisites and commands.

## Documentation

- [Market creation and outcome tokens](docs/market-creation-explained.md) — contract architecture, creation constraints, and collateral assumptions.
- [Trading engine](docs/trading-engine.md) — AMM pricing, trade accounting, quotes, and fees.
- [Market settlement and payouts](docs/market-settlement.md) — lifecycle, resolution, cancellation, redemption, and withdrawals.
- [Chainlink resolver](docs/chainlink-resolver.md) — price-feed settlement and operation.
- [Optimistic resolver](docs/optimistic-resolver.md) — bonded proposals, disputes, judging, and operation.

The resolver guides describe their respective feed, sequencer, bond-transfer, and operational limitations. Choose an arbitrator and collateral token whose assumptions match the market and deployment environment.
