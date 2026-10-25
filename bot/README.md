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

The bot renders the spec's source URL in headless Chromium (so JavaScript-built pages work), then asks
the model once per run with that page's text. It only proposes when:
- the page loaded and stayed on the source's site (redirects included),
- each cited quote appears verbatim on the page,
- all `AGENT_RUNS` runs agree.

Otherwise it skips and retries after `AGENT_RETRY_HOURS`. Expect ~15k tokens per market; unclear markets
stop after one run and a dead source costs none. Pick sources whose answer is visible as text on the page:
paywalls, logins, bot walls and images can't be read.

## Run

```bash
cd contracts && forge build          # the bot loads ABIs from contracts/out
cd ../bot && cp .env.example .env    # fill in addresses and the bot key
uv sync
uv run playwright install chromium   # once, ~150MB
uv run --env-file .env python -m sooth_bot
```

Use a **dedicated wallet** with only gas (and later bond money). Never the admin or judge key: the judge must
not rule on the bot's own proposals.

## Test

```bash
uv run pytest
```

Unit tests cover the round search, the agent's checks against a scripted model, and the browser fetcher
against a local server (skipped without Chromium). Chain interactions are thin web3 wrappers; check them
with a run on Base Sepolia.
