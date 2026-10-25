# Sooth bot

Off-chain worker that keeps markets moving so humans only judge disputes. Each poll it reads chain
state and:

- **Chainlink markets, closed:** finds the round live at close and calls `ChainlinkResolver.resolve`.
- **Optimistic markets, closed, no request:** asks an LLM agent to resolve from the spec's source and, if
  every run agrees, approves one bond and calls `propose` with the evidence as a `data:` URI.
- **Optimistic requests:** `finalize` after an undisputed window, `refund` if the market cancelled with a
  request open, and alerts (log, optional webhook) once per dispute.

Stateless: everything is re-derived from the chain, so restarts and duplicate attempts are safe.

## Agent

Any OpenAI-compatible chat API with tool calling; defaults to OpenCode Go with `deepseek-v4.1-flash`
(enable the Global region in OpenCode privacy settings for DeepSeek models). Switch with `LLM_BASE_URL`,
`LLM_MODEL`, `LLM_API_KEY`.

It only proposes when:
- every fetched page is on the spec's source site (redirects included),
- each cited quote appears verbatim on a page it fetched,
- all `AGENT_RUNS` runs agree.

Otherwise it skips and retries after `AGENT_RETRY_HOURS`. Expect ~10-25k tokens per market; unclear markets
stop after one run.

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
