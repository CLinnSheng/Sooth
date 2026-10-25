"""Settles optimistic requests: finalizes undisputed ones, refunds bonds on cancelled markets and
alerts the judge about disputes."""

import json
import logging
import urllib.request
from enum import IntEnum
from urllib.error import URLError

from eth_typing import ChecksumAddress
from web3.exceptions import ContractLogicError

from sooth_bot.chain import Chain, MarketInfo, MarketState, TransactionReverted

logger = logging.getLogger(__name__)

ALERT_TIMEOUT_SECONDS = 10


class RequestStatus(IntEnum):
    """Mirrors IOptimisticResolver.Status; the order must match the Solidity enum."""

    NONE = 0
    PROPOSED = 1
    DISPUTED = 2
    SETTLED = 3


class OptimisticSettler:
    def __init__(self, chain: Chain, alert_webhook: str | None) -> None:
        self._chain = chain
        self._resolver = chain.optimistic_resolver
        self._challenge_window: int = self._resolver.functions.challengeWindow().call()
        self._alert_webhook = alert_webhook
        self._alerted: set[ChecksumAddress] = set()

    def settle(self, markets: list[MarketInfo], now: int) -> None:
        """`now` is the latest block timestamp, the clock the contract checks the window against."""
        for info in markets:
            if info.arbitrator != self._resolver.address:
                continue
            try:
                self._settle(info, now)
            except (ContractLogicError, TransactionReverted) as err:
                logger.warning("optimistic: skipped %s: %s", info.address, err)

    def _settle(self, info: MarketInfo, now: int) -> None:
        _, _, status, proposed_at, disputer = self._resolver.functions.requestOf(info.address).call()
        if status in (RequestStatus.NONE, RequestStatus.SETTLED):
            return
        state = self._chain.market(info.address).functions.state().call()

        if state == MarketState.CANCELLED:
            logger.info("optimistic: refunding bonds on cancelled %s", info.address)
            self._chain.send(self._resolver.functions.refund(info.address))
        elif status == RequestStatus.PROPOSED and now >= proposed_at + self._challenge_window:
            logger.info("optimistic: finalizing %s", info.address)
            self._chain.send(self._resolver.functions.finalize(info.address))
        elif status == RequestStatus.DISPUTED and info.address not in self._alerted:
            self._alert_dispute(info, disputer)

    def _alert_dispute(self, info: MarketInfo, disputer: ChecksumAddress) -> None:
        self._alerted.add(info.address)
        message = f"Sooth market {info.address} disputed by {disputer}; rule before its resolution deadline."
        logger.warning("optimistic: %s", message)
        if self._alert_webhook is None:
            return
        # Discord reads `content`, Slack reads `text`; the rest is for anything else listening.
        body = json.dumps({"content": message, "text": message, "market": info.address, "disputer": disputer})
        request = urllib.request.Request(
            self._alert_webhook, data=body.encode(), headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(request, timeout=ALERT_TIMEOUT_SECONDS):
                pass
        except URLError as err:
            logger.warning("optimistic: dispute alert failed for %s: %s", info.address, err)
