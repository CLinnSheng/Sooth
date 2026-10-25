# Sooth bot

Off-chain worker that keeps markets moving so humans only judge disputes. Each poll it reads chain
state and:

- **Chainlink markets, closed:** finds the round live at close and calls `ChainlinkResolver.resolve`.
- **Optimistic requests:** `finalize` after an undisputed window, `refund` if the market cancelled with a
  request open, and alerts (log, optional webhook) once per dispute.

Stateless: everything is re-derived from the chain, so restarts and duplicate attempts are safe.

## Run

```bash
cd contracts && forge build          # the bot loads ABIs from contracts/out
cd ../bot && cp .env.example .env    # fill in addresses and the bot key
uv sync
uv run --env-file .env python -m sooth_bot
```

Use a **dedicated wallet** with only gas (and later bond money). Never the admin or judge key: the judge must
not rule on the bot's own proposals.

## Test

```bash
uv run pytest
```

Unit tests cover the round search. Chain interactions are thin web3 wrappers; check them with a run on Base
Sepolia.
