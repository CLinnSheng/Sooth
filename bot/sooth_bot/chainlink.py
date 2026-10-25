"""Resolves closed Chainlink markets on the round that was live at their close."""

import logging
from typing import Protocol

from web3.contract import Contract
from web3.exceptions import ContractLogicError

from sooth_bot.chain import Chain, MarketInfo, MarketState, TransactionReverted

logger = logging.getLogger(__name__)

# Proxy round ids are (phaseId << 64 | aggregatorRoundId).
PHASE_OFFSET = 64
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


class RoundReader(Protocol):
    def latest_round(self) -> tuple[int, int]:
        """(round_id, updated_at) of the feed's latest round."""
        ...

    def updated_at(self, round_id: int) -> int: ...


class RoundNotInPhase(Exception):
    """The market closed before the feed's current phase; pass ROUND_ID to the Forge script by hand."""


def round_at_close(feed: RoundReader, close_time: int) -> int:
    """Last round updated at or before close, by binary search over the current phase. Same algorithm as
    script/ResolveChainlinkMarket.s.sol. The contract re-checks the round, so a wrong answer only reverts."""
    high, latest_updated_at = feed.latest_round()
    if latest_updated_at <= close_time:
        return high

    low = (high >> PHASE_OFFSET) << PHASE_OFFSET | 1
    if feed.updated_at(low) > close_time:
        raise RoundNotInPhase(f"round {low} is already after close {close_time}")
    # Invariant: low is at or before close, high is after it.
    while high - low > 1:
        mid = low + (high - low) // 2
        if feed.updated_at(mid) <= close_time:
            low = mid
        else:
            high = mid
    return low


class FeedReader:
    """RoundReader over a Chainlink feed contract."""

    def __init__(self, feed: Contract) -> None:
        self._feed = feed

    def latest_round(self) -> tuple[int, int]:
        round_id, _, _, updated_at, _ = self._feed.functions.latestRoundData().call()
        return round_id, updated_at

    def updated_at(self, round_id: int) -> int:
        _, _, _, updated_at, _ = self._feed.functions.getRoundData(round_id).call()
        return updated_at


def resolve_closed_markets(chain: Chain, markets: list[MarketInfo]) -> None:
    for info in markets:
        if info.arbitrator != chain.chainlink_resolver.address:
            continue
        if chain.market(info.address).functions.state().call() != MarketState.CLOSED:
            continue
        try:
            _resolve(chain, info)
        # One market failing (stale feed, race with another resolver) must not block the rest.
        except (ContractLogicError, TransactionReverted, RoundNotInPhase) as err:
            logger.warning("chainlink: skipped %s: %s", info.address, err)


def _resolve(chain: Chain, info: MarketInfo) -> None:
    feed_address, _, _, _ = chain.chainlink_resolver.functions.configOf(info.address).call()
    if feed_address == ZERO_ADDRESS:
        logger.warning("chainlink: %s is not configured on the resolver", info.address)
        return

    round_id = round_at_close(FeedReader(chain.feed(feed_address)), info.close_time)
    logger.info("chainlink: resolving %s on round %d", info.address, round_id)
    chain.send(chain.chainlink_resolver.functions.resolve(info.address, round_id))
