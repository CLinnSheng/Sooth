"""Settles optimistic requests: finalizes undisputed ones, refunds bonds on cancelled markets and
alerts the judge about disputes. Proposes an outcome via the agent when a closed market has no request."""

import base64
import json
import logging
import urllib.request
from enum import IntEnum
from urllib.error import URLError

from eth_typing import ChecksumAddress
from web3.exceptions import ContractLogicError

from sooth_bot.agent import Resolution, ResolverAgent, Verdict
from sooth_bot.chain import Chain, MarketInfo, MarketState, TransactionReverted

logger = logging.getLogger(__name__)

ALERT_TIMEOUT_SECONDS = 10
# Mirrors IMarket.Outcome; the order must match the Solidity enum.
OUTCOME_INDEX = {Verdict.YES: 0, Verdict.NO: 1}


class RequestStatus(IntEnum):
    """Mirrors IOptimisticResolver.Status; the order must match the Solidity enum."""

    NONE = 0
    PROPOSED = 1
    DISPUTED = 2
    SETTLED = 3


class OptimisticSettler:
    def __init__(
        self, chain: Chain, alert_webhook: str | None, agent: ResolverAgent, model: str, retry_seconds: int
    ) -> None:
        self._chain = chain
        self._resolver = chain.optimistic_resolver
        self._challenge_window: int = self._resolver.functions.challengeWindow().call()
        self._bond: int = self._resolver.functions.bond().call()
        self._alert_webhook = alert_webhook
        self._alerted: set[ChecksumAddress] = set()
        self._agent = agent
        self._model = model
        self._retry_seconds = retry_seconds
        # Block time before which a market the agent couldn't resolve isn't asked again.
        self._next_attempt: dict[ChecksumAddress, int] = {}

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
        if status == RequestStatus.SETTLED:
            return
        state = self._chain.market(info.address).functions.state().call()

        if status == RequestStatus.NONE:
            if state == MarketState.CLOSED:
                self._propose(info, now)
            else:
                logger.debug("optimistic: %s not closed yet (state %s)", info.address, MarketState(state).name)
        elif state == MarketState.CANCELLED:
            logger.info("optimistic: refunding bonds on cancelled %s", info.address)
            self._chain.send(self._resolver.functions.refund(info.address))
        elif status == RequestStatus.PROPOSED and now >= proposed_at + self._challenge_window:
            logger.info("optimistic: finalizing %s", info.address)
            self._chain.send(self._resolver.functions.finalize(info.address))
        elif status == RequestStatus.PROPOSED:
            logger.debug("optimistic: %s in challenge window until %d", info.address, proposed_at + self._challenge_window)
        elif status == RequestStatus.DISPUTED and info.address not in self._alerted:
            self._alert_dispute(info, disputer)
        else:
            logger.debug("optimistic: %s disputed, awaiting the judge", info.address)

    def _propose(self, info: MarketInfo, now: int) -> None:
        next_attempt = self._next_attempt.get(info.address)
        if next_attempt is not None and now < next_attempt:
            logger.debug("optimistic: %s backing off until %d", info.address, next_attempt)
            return
        deadline = self._chain.market(info.address).functions.resolutionDeadline().call()
        if now + self._challenge_window >= deadline:
            logger.debug("optimistic: %s too close to its deadline to propose", info.address)
            return  # the resolver would reject it as too late; don't spend tokens finding out
        # Set before asking, so a crash mid-run can't cause a retry on every poll.
        self._next_attempt[info.address] = now + self._retry_seconds

        resolution = self._agent.resolve(info.spec, info.close_time)
        if resolution.verdict == Verdict.UNRESOLVABLE:
            logger.info("optimistic: no proposal for %s, retrying in %ds", info.address, self._retry_seconds)
            return
        logger.info("optimistic: proposing %s for %s", resolution.verdict, info.address)
        # Approve exactly one bond, so the resolver can never pull more than this proposal needs.
        self._chain.send(self._chain.bond_token.functions.approve(self._resolver.address, self._bond))
        self._chain.send(
            self._resolver.functions.propose(
                info.address, OUTCOME_INDEX[resolution.verdict], evidence_uri(resolution, self._model)
            )
        )

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


def evidence_uri(resolution: Resolution, model: str) -> str:
    """Evidence as a data: URI in the Proposed event, so anyone can check it on-chain with no extra hosting.
    The agent's caps on quotes and reasoning keep it to a few KB."""
    bundle = {
        "verdict": resolution.verdict,
        "model": model,
        "reasoning": resolution.reasoning,
        "evidence": [{"url": item.url, "quote": item.quote} for item in resolution.evidence],
    }
    encoded = base64.b64encode(json.dumps(bundle, separators=(",", ":")).encode()).decode()
    return f"data:application/json;base64,{encoded}"
