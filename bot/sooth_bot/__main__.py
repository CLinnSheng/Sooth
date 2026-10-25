"""Entry point. From bot/: `uv run --env-file .env python -m sooth_bot`."""

import logging
import time

import httpx
from web3.exceptions import Web3Exception

from sooth_bot.agent import USER_AGENT, HttpPageFetcher, OpenAICompatibleClient, ResolverAgent
from sooth_bot.chain import Chain
from sooth_bot.chainlink import resolve_closed_markets
from sooth_bot.config import Config
from sooth_bot.optimistic import OptimisticSettler

logger = logging.getLogger("sooth_bot")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    config = Config.from_env()
    chain = Chain(config)
    # One HTTP client for LLM calls and page fetches; Go asks callers to identify with their own user agent.
    with httpx.Client(headers={"User-Agent": USER_AGENT}) as http:
        agent = ResolverAgent(
            OpenAICompatibleClient(http, config.llm_base_url, config.llm_api_key, config.llm_model),
            HttpPageFetcher(http),
            config.agent_runs,
        )
        settler = OptimisticSettler(chain, config.alert_webhook, agent, config.llm_model, config.agent_retry_seconds)
        logger.info("bot %s watching factory %s with model %s", chain.account.address, config.factory, config.llm_model)
        _poll_forever(chain, settler, config.poll_seconds)


def _poll_forever(chain: Chain, settler: OptimisticSettler, poll_seconds: int) -> None:
    while True:
        try:
            markets = chain.markets()
            now = chain.w3.eth.get_block("latest")["timestamp"]
            resolve_closed_markets(chain, markets)
            settler.settle(markets, now)
        # A flaky RPC must not kill the bot; the next poll starts again from chain state.
        # OSError covers connection errors from the HTTP client underneath web3.
        except (OSError, Web3Exception) as err:
            logger.warning("poll failed: %s", err)
        time.sleep(poll_seconds)


if __name__ == "__main__":
    main()
