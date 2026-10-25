"""Bot settings, read once from the environment at startup."""

import os
from dataclasses import dataclass, field

from eth_typing import ChecksumAddress
from web3 import Web3

DEFAULT_POLL_SECONDS = 30


@dataclass(frozen=True)
class Config:
    rpc_url: str
    factory: ChecksumAddress
    deploy_block: int
    chainlink_resolver: ChecksumAddress
    optimistic_resolver: ChecksumAddress
    # Kept out of repr so logging the config can never print the key.
    bot_private_key: str = field(repr=False)
    poll_seconds: int = DEFAULT_POLL_SECONDS
    alert_webhook: str | None = None

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            rpc_url=_required("RPC_URL"),
            factory=_address("FACTORY"),
            deploy_block=int(_required("DEPLOY_BLOCK")),
            chainlink_resolver=_address("CHAINLINK_RESOLVER"),
            optimistic_resolver=_address("OPTIMISTIC_RESOLVER"),
            bot_private_key=_required("BOT_PRIVATE_KEY"),
            poll_seconds=int(os.environ.get("POLL_SECONDS", DEFAULT_POLL_SECONDS)),
            alert_webhook=os.environ.get("ALERT_WEBHOOK") or None,
        )


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Missing env var {name}; see .env.example")
    return value


def _address(name: str) -> ChecksumAddress:
    value = _required(name)
    # The .env.example placeholders are zero addresses; refuse to run against them.
    if not Web3.is_address(value) or int(value, 16) == 0:
        raise SystemExit(f"{name} must be a non-zero address, got {value!r}")
    return Web3.to_checksum_address(value)
