# Sooth

Sooth is a binary prediction-market application where people trade YES and NO shares on the outcome of a question.

Try it live at [sooth.deva16z.workers.dev](https://sooth.deva16z.workers.dev/).

## How Sooth works

Sooth runs on **Base Sepolia**. Its markets use test MockUSDC as collateral; users also need Base Sepolia ETH to pay transaction fees. See the [frontend guide](web/README.md#fund-a-test-wallet) for wallet funding.

1. **Create a market.** An admin sets a question, closing time, and resolution method, and supplies the initial collateral that backs the market.
2. **Trade shares.** Traders buy and sell YES or NO shares against a constant-product automated market maker (AMM). The pool's reserves determine prices, and each trade incurs a 1% fee. See the [trading engine](docs/trading-engine.md).
3. **Resolve the outcome.** Trading stops at the closing time. The market is resolved using a [Chainlink price feed](docs/chainlink-resolver.md), an [optimistic proposal and dispute process](docs/optimistic-resolver.md), or a designated wallet or contract. An optional bot can attempt resolution and assist with optimistic settlement.
4. **Redeem shares.** After resolution, winning shares can be redeemed for one unit of collateral each. If the market remains unresolved for seven days after close, it is cancelled and each YES or NO share pays half a collateral unit, subject to rounding. See [market settlement and payouts](docs/market-settlement.md).

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

Connect a wallet on Base Sepolia to buy or sell shares and redeem eligible payouts on a market page. To buy shares, seed a market, or post a bond, first [fund the relevant wallet with test collateral](web/README.md#fund-a-test-wallet). An admin wallet can create markets and trigger creator withdrawals. Chainlink markets require feed configuration; optimistic markets use bonded proposals and may be disputed. A custom arbitrator must call the market's `resolve` function directly or through its own contract logic.

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
- [Order book](docs/order-book.md) — secondary trading of outcome shares between users (Bonus 1).
- [Architecture](docs/architecture.md) — system overview, contract interactions, and sequence diagrams.
- [Contract spec](docs/contract-spec.md) — every contract's functions, events, errors, and access rules.
- [Invariants](docs/invariants.md) — the rules the contracts must keep, and the tests that check them.
- [Threat model](docs/threat-model.md) — trust assumptions, threats, mitigations, and known limitations.
- [Testing](docs/testing.md) — how to run every test suite, what each covers, and the [Slither and coverage results](docs/testing.md#security-analysis).
- [Live demo checklist](docs/demo-checklist.md) — step-by-step Base Sepolia demo.
- [Final report](docs/final-report.md) — problem, design justifications, requirement-to-code map, and limitations.
- [AI Audit Report](docs/ai-audit-report.md) and the [AI audit log](docs/ai/README.md).

The resolver guides describe their respective feed, sequencer, bond-transfer, and operational limitations. Choose an arbitrator and collateral token whose assumptions match the market and deployment environment.
