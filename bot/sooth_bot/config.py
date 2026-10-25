"""Bot settings, read once from the environment at startup."""

import os
from dataclasses import dataclass, field

from eth_typing import ChecksumAddress
from web3 import Web3

DEFAULT_POLL_SECONDS = 300
DEFAULT_LLM_BASE_URL = "https://opencode.ai/inference/go/openai/v1"
DEFAULT_LLM_MODEL = "deepseek-v4.1-flash"
DEFAULT_AGENT_RUNS = 2
DEFAULT_AGENT_RETRY_HOURS = 6
SECONDS_PER_HOUR = 3600


@dataclass(frozen=True)
class Config:
    rpc_url: str
    factory: ChecksumAddress
    deploy_block: int
    chainlink_resolver: ChecksumAddress
    optimistic_resolver: ChecksumAddress
    # Kept out of repr so logging the config can never print the key.
    bot_private_key: str = field(repr=False)
    llm_api_key: str = field(repr=False)
    poll_seconds: int = DEFAULT_POLL_SECONDS
    alert_webhook: str | None = None
    llm_base_url: str = DEFAULT_LLM_BASE_URL
    llm_model: str = DEFAULT_LLM_MODEL
    agent_runs: int = DEFAULT_AGENT_RUNS
    agent_retry_seconds: int = DEFAULT_AGENT_RETRY_HOURS * SECONDS_PER_HOUR

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            rpc_url=_required("RPC_URL"),
            factory=_address("FACTORY"),
            deploy_block=int(_required("DEPLOY_BLOCK")),
            chainlink_resolver=_address("CHAINLINK_RESOLVER"),
            optimistic_resolver=_address("OPTIMISTIC_RESOLVER"),
            bot_private_key=_required("BOT_PRIVATE_KEY"),
            llm_api_key=_required("LLM_API_KEY"),
            poll_seconds=int(os.environ.get("POLL_SECONDS", DEFAULT_POLL_SECONDS)),
            alert_webhook=os.environ.get("ALERT_WEBHOOK") or None,
            llm_base_url=os.environ.get("LLM_BASE_URL") or DEFAULT_LLM_BASE_URL,
            llm_model=os.environ.get("LLM_MODEL") or DEFAULT_LLM_MODEL,
            agent_runs=_positive_int("AGENT_RUNS", DEFAULT_AGENT_RUNS),
            agent_retry_seconds=_positive_int("AGENT_RETRY_HOURS", DEFAULT_AGENT_RETRY_HOURS) * SECONDS_PER_HOUR,
        )


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Missing env var {name}; see .env.example")
    return value


def _positive_int(name: str, default: int) -> int:
    value = int(os.environ.get(name) or default)
    if value < 1:
        raise SystemExit(f"{name} must be at least 1, got {value}")
    return value


def _address(name: str) -> ChecksumAddress:
    value = _required(name)
    # The .env.example placeholders are zero addresses; refuse to run against them.
    if not Web3.is_address(value) or int(value, 16) == 0:
        raise SystemExit(f"{name} must be a non-zero address, got {value!r}")
    return Web3.to_checksum_address(value)
