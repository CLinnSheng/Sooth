"""round_at_close against an in-memory feed."""

import pytest

from sooth_bot.chainlink import PHASE_OFFSET, RoundNotInPhase, round_at_close

PHASE = 3
CLOSE = 1_000_000
AGGREGATOR_ROUND_MASK = (1 << PHASE_OFFSET) - 1


def _round_id(aggregator_round: int) -> int:
    return PHASE << PHASE_OFFSET | aggregator_round


class FakeFeed:
    """Rounds 1..n of one phase; round i was updated at updated_ats[i - 1]."""

    def __init__(self, updated_ats: list[int]) -> None:
        self._updated_ats = updated_ats
        self.reads = 0

    def latest_round(self) -> tuple[int, int]:
        return _round_id(len(self._updated_ats)), self._updated_ats[-1]

    def updated_at(self, round_id: int) -> int:
        self.reads += 1
        return self._updated_ats[(round_id & AGGREGATOR_ROUND_MASK) - 1]


def test_returns_latest_round_when_no_round_after_close() -> None:
    feed = FakeFeed([CLOSE - 100, CLOSE - 10])
    assert round_at_close(feed, CLOSE) == _round_id(2)


def test_round_updated_exactly_at_close_counts() -> None:
    feed = FakeFeed([CLOSE - 60, CLOSE, CLOSE + 1])
    assert round_at_close(feed, CLOSE) == _round_id(2)


def test_first_round_of_phase_can_be_live_at_close() -> None:
    feed = FakeFeed([CLOSE - 5, CLOSE + 5, CLOSE + 10])
    assert round_at_close(feed, CLOSE) == _round_id(1)


def test_raises_when_close_is_before_current_phase() -> None:
    feed = FakeFeed([CLOSE + 1, CLOSE + 2])
    with pytest.raises(RoundNotInPhase):
        round_at_close(feed, CLOSE)


@pytest.mark.parametrize("close", range(0, 1_100, 7))
def test_matches_linear_scan_for_every_close(close: int) -> None:
    updated_ats = [100 * i for i in range(1, 11)]  # rounds at 100, 200, ..., 1000
    if close < updated_ats[0]:
        pytest.skip("close before the phase is covered by test_raises_when_close_is_before_current_phase")
    expected = max(i for i, updated_at in enumerate(updated_ats, start=1) if updated_at <= close)
    assert round_at_close(FakeFeed(updated_ats), close) == _round_id(expected)


def test_search_reads_a_logarithmic_number_of_rounds() -> None:
    rounds = 100_000
    feed = FakeFeed([CLOSE - rounds + i for i in range(rounds)])
    round_at_close(feed, CLOSE - rounds // 3)
    # One read for the phase's first round, then about log2(100_000) = 17 halvings.
    assert feed.reads <= 20
