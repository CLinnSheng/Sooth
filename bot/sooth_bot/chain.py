"""Web3 connection, contract bindings, market discovery and transaction sending."""

import json
import logging
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path
from typing import Any

from eth_account import Account
from eth_typing import ChecksumAddress
from web3 import Web3
from web3.contract import Contract
from web3.contract.contract import ContractFunction

from sooth_bot.config import Config

logger = logging.getLogger(__name__)

# Forge build output; run `forge build` in contracts/ first.
FORGE_OUT = Path(__file__).resolve().parents[2] / "contracts" / "out"
# publicnode caps eth_getLogs at 50k blocks (same limit as web/src/chain.ts).
LOG_CHUNK_BLOCKS = 50_000


class MarketState(IntEnum):
    """Mirrors IMarket.State; the order must match the Solidity enum."""

    OPEN = 0
    CLOSED = 1
    PROPOSED = 2
    RESOLVED = 3
    CANCELLED = 4


@dataclass(frozen=True)
class MarketInfo:
    """What MarketCreated tells us about a market; live state is read from the market itself."""

    address: ChecksumAddress
    arbitrator: ChecksumAddress
    close_time: int
    spec: str


class TransactionReverted(Exception):
    pass


def load_abi(contract_name: str) -> list[dict[str, Any]]:
    artifact = FORGE_OUT / f"{contract_name}.sol" / f"{contract_name}.json"
    if not artifact.exists():
        raise SystemExit(f"Missing {artifact}; run `forge build` in contracts/")
    return json.loads(artifact.read_text())["abi"]


class Chain:
    def __init__(self, config: Config) -> None:
        self.w3 = Web3(Web3.HTTPProvider(config.rpc_url))
        self.account = Account.from_key(config.bot_private_key)
        self.factory = self._contract(config.factory, "MarketFactory")
        self.chainlink_resolver = self._contract(config.chainlink_resolver, "ChainlinkResolver")
        self.optimistic_resolver = self._contract(config.optimistic_resolver, "OptimisticResolver")
        self._markets: list[MarketInfo] = []
        self._scanned_to = config.deploy_block - 1

    def market(self, address: ChecksumAddress) -> Contract:
        return self._contract(address, "Market")

    def feed(self, address: ChecksumAddress) -> Contract:
        return self._contract(address, "AggregatorV3Interface")

    def markets(self) -> list[MarketInfo]:
        """Every market created so far. Each call scans only blocks it hasn't seen."""
        head = self.w3.eth.block_number
        while self._scanned_to < head:
            from_block = self._scanned_to + 1
            to_block = min(from_block + LOG_CHUNK_BLOCKS - 1, head)
            logs = self.factory.events.MarketCreated.get_logs(from_block=from_block, to_block=to_block)
            self._markets.extend(
                MarketInfo(
                    address=log["args"]["market"],
                    arbitrator=log["args"]["arbitrator"],
                    close_time=log["args"]["closeTime"],
                    spec=log["args"]["spec"],
                )
                for log in logs
            )
            self._scanned_to = to_block
        return self._markets

    def send(self, call: ContractFunction) -> str:
        """Sends `call` from the bot wallet and waits for it. Gas estimation runs the call first, so a
        call that would revert raises here without spending gas."""
        tx = call.build_transaction(
            {
                "from": self.account.address,
                "nonce": self.w3.eth.get_transaction_count(self.account.address, "pending"),
            }
        )
        tx_hash = self.w3.eth.send_raw_transaction(self.account.sign_transaction(tx).raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        if receipt["status"] != 1:
            raise TransactionReverted(f"{tx_hash.hex()} reverted")
        logger.info("sent %s", tx_hash.hex())
        return tx_hash.hex()

    def _contract(self, address: ChecksumAddress, contract_name: str) -> Contract:
        return self.w3.eth.contract(address=address, abi=load_abi(contract_name))
