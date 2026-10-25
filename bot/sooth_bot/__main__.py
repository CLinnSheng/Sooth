"""Entry point. From bot/: `uv run --env-file .env python -m sooth_bot`."""

import logging
import time

from web3.exceptions import Web3Exception

from sooth_bot.chain import Chain
from sooth_bot.chainlink import resolve_closed_markets
from sooth_bot.config import Config
from sooth_bot.optimistic import OptimisticSettler

logger = logging.getLogger("sooth_bot")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    config = Config.from_env()
    chain = Chain(config)
    settler = OptimisticSettler(chain, config.alert_webhook)
    logger.info("bot %s watching factory %s", chain.account.address, config.factory)

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
        time.sleep(config.poll_seconds)


if __name__ == "__main__":
    main()
