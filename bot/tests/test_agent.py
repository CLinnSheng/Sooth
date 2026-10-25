"""ResolverAgent against a scripted chat model and an in-memory site: no network, no tokens."""

import base64
import json
from typing import Any

import pytest

from sooth_bot.agent import (
    FetchError,
    LLMError,
    Resolution,
    ResolverAgent,
    Verdict,
    same_site,
)
from sooth_bot.optimistic import evidence_uri

SOURCE = "https://www.apple.com/newsroom/"
SPEC = json.dumps(
    {
        "question": "Will Apple announce a foldable iPhone by close?",
        "category": "Tech",
        "rules": "YES if Apple officially announces a foldable iPhone before close.",
        "source": {"label": "Apple Newsroom", "url": SOURCE},
    }
)
CLOSE = 1_790_000_000
PAGE = "Apple today announced iPhone Fold, its first foldable iPhone, available next month."
QUOTE = "Apple today announced iPhone Fold, its first foldable iPhone"


def _call(name: str, arguments: dict[str, Any] | str) -> dict[str, Any]:
    raw = arguments if isinstance(arguments, str) else json.dumps(arguments)
    return {"id": "call_1", "type": "function", "function": {"name": name, "arguments": raw}}


def _turn(call: dict[str, Any]) -> dict[str, Any]:
    return {"role": "assistant", "content": None, "tool_calls": [call]}


def _submit(outcome: str, quote: str = QUOTE) -> dict[str, Any]:
    return _turn(_call("submit_resolution", {"outcome": outcome, "quotes": [quote], "reasoning": "per rules"}))


class FakeChat:
    def __init__(self, replies: list[dict[str, Any]]) -> None:
        self._replies = iter(replies)
        self.calls = 0
        self.sessions: set[str] = set()

    def complete(self, messages: list[dict[str, Any]], tools: list[dict[str, Any]], session_id: str) -> dict[str, Any]:
        self.calls += 1
        self.sessions.add(session_id)
        return next(self._replies)


class FailingChat:
    def complete(self, messages: list[dict[str, Any]], tools: list[dict[str, Any]], session_id: str) -> dict[str, Any]:
        raise LLMError("503 Service Unavailable")


class FakeFetcher:
    def __init__(self, pages: dict[str, str]) -> None:
        self._pages = pages
        self.fetched: list[str] = []

    def fetch(self, url: str) -> str:
        self.fetched.append(url)
        if url not in self._pages:
            raise FetchError("404 Not Found")
        return self._pages[url]


def _resolve(replies: list[dict[str, Any]], runs: int = 1) -> tuple[Resolution, FakeChat, FakeFetcher]:
    chat, fetcher = FakeChat(replies), FakeFetcher({SOURCE: PAGE})
    return ResolverAgent(chat, fetcher, runs).resolve(SPEC, CLOSE), chat, fetcher


# verdicts


def test_yes_with_verified_quote() -> None:
    resolution, _, _ = _resolve([_submit("YES")])
    assert resolution.verdict == Verdict.YES
    assert resolution.evidence[0].quote == QUOTE


def test_runs_must_agree_and_each_uses_its_own_session() -> None:
    resolution, chat, _ = _resolve([_submit("YES"), _submit("YES")], runs=2)
    assert resolution.verdict == Verdict.YES
    assert len(chat.sessions) == 2


def test_disagreement_is_unresolvable() -> None:
    resolution, _, _ = _resolve([_submit("YES"), _submit("NO")], runs=2)
    assert resolution.verdict == Verdict.UNRESOLVABLE


def test_first_unresolvable_skips_remaining_runs() -> None:
    resolution, chat, _ = _resolve([_submit("UNRESOLVABLE")], runs=2)
    assert resolution.verdict == Verdict.UNRESOLVABLE
    assert chat.calls == 1  # the second run never starts


# evidence checks


def test_invented_quote_is_rejected() -> None:
    resolution, _, _ = _resolve([_submit("YES", quote="Apple announced a foldable iPhone yesterday")])
    assert resolution.verdict == Verdict.UNRESOLVABLE


def test_too_short_quote_is_rejected() -> None:
    resolution, _, _ = _resolve([_submit("YES", quote="Apple today")])
    assert resolution.verdict == Verdict.UNRESOLVABLE


def test_quote_whitespace_is_normalized() -> None:
    resolution, _, _ = _resolve([_submit("YES", quote=QUOTE.replace(" ", "\n  ", 2))])
    assert resolution.verdict == Verdict.YES


# failures become UNRESOLVABLE


def test_invalid_tool_arguments() -> None:
    resolution, _, _ = _resolve([_turn(_call("submit_resolution", "{not json"))])
    assert resolution.verdict == Verdict.UNRESOLVABLE


def test_model_stops_without_submitting() -> None:
    resolution, _, _ = _resolve([{"role": "assistant", "content": "Probably yes.", "tool_calls": None}])
    assert resolution.verdict == Verdict.UNRESOLVABLE


def test_llm_error() -> None:
    resolution = ResolverAgent(FailingChat(), FakeFetcher({SOURCE: PAGE}), runs=2).resolve(SPEC, CLOSE)
    assert resolution.verdict == Verdict.UNRESOLVABLE


def test_spec_without_source_costs_no_tokens() -> None:
    chat = FakeChat([])
    resolution = ResolverAgent(chat, FakeFetcher({}), runs=2).resolve(json.dumps({"question": "?"}), CLOSE)
    assert resolution.verdict == Verdict.UNRESOLVABLE
    assert chat.calls == 0


def test_dead_source_costs_no_tokens() -> None:
    chat = FakeChat([])
    resolution = ResolverAgent(chat, FakeFetcher({}), runs=2).resolve(SPEC, CLOSE)
    assert resolution.verdict == Verdict.UNRESOLVABLE
    assert chat.calls == 0


def test_source_is_fetched_once_for_all_runs() -> None:
    _, _, fetcher = _resolve([_submit("YES"), _submit("YES")], runs=2)
    assert fetcher.fetched == [SOURCE]


# helpers


@pytest.mark.parametrize(
    ("url", "allowed"),
    [
        ("https://www.apple.com/newsroom/2026/", True),
        ("https://apple.com/newsroom/", True),
        ("http://www.apple.com/", True),
        ("https://support.apple.com/", False),
        ("https://apple.com.evil.example/", False),
        ("file:///etc/passwd", False),
    ],
)
def test_same_site(url: str, allowed: bool) -> None:
    assert same_site(url, SOURCE) is allowed


def test_evidence_uri_round_trips() -> None:
    resolution, _, _ = _resolve([_submit("YES")])
    prefix = "data:application/json;base64,"
    uri = evidence_uri(resolution, "deepseek-v4.1-flash")
    bundle = json.loads(base64.b64decode(uri.removeprefix(prefix)))
    assert uri.startswith(prefix)
    assert bundle["verdict"] == "YES"
    assert bundle["model"] == "deepseek-v4.1-flash"
    assert bundle["evidence"] == [{"url": SOURCE, "quote": QUOTE}]
