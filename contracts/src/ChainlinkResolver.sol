// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IChainlinkResolver} from "./interfaces/IChainlinkResolver.sol";
import {IMarket} from "./interfaces/IMarket.sol";

/// @title ChainlinkResolver
/// @notice Arbitrator for price markets. Settles each market on the Chainlink round that was live at
///         its closeTime, so the outcome doesn't depend on who calls resolve or when.
/// @dev shortcut: no L2 sequencer uptime check because Base Sepolia has no uptime feed; add one before mainnet.
contract ChainlinkResolver is Ownable, IChainlinkResolver {
    /// @dev Proxy round ids are (phaseId << 64 | aggregatorRoundId).
    uint256 internal constant PHASE_OFFSET = 64;

    mapping(IMarket market => Config) internal _configs;

    constructor(address owner_) Ownable(owner_) {}

    function configure(IMarket market, Config calldata config) external onlyOwner {
        if (address(config.feed) == address(0) || config.maxStaleness == 0) revert InvalidConfig();
        if (market.arbitrator() != address(this)) revert MarketNotUsingResolver(market);
        if (address(_configs[market].feed) != address(0)) revert AlreadyConfigured(market);
        if (block.timestamp >= market.closeTime()) revert ConfigureAfterClose(market);

        _configs[market] = config;
        emit MarketConfigured(market, config.feed, config.threshold, config.comparison, config.maxStaleness);
    }

    function resolve(IMarket market, uint80 roundId) external {
        Config memory config = _configs[market];
        if (address(config.feed) == address(0)) revert NotConfigured(market);

        int256 price = _priceAtClose(config, roundId, market.closeTime());
        IMarket.Outcome outcome = _isYes(config, price) ? IMarket.Outcome.Yes : IMarket.Outcome.No;
        emit PriceResolved(market, roundId, price, outcome);
        market.resolve(outcome);
    }

    function configOf(IMarket market) external view returns (Config memory) {
        return _configs[market];
    }

    function _priceAtClose(Config memory config, uint80 roundId, uint64 closeTime) internal view returns (int256) {
        (, int256 answer,, uint256 updatedAt,) = config.feed.getRoundData(roundId);
        if (updatedAt == 0) revert RoundNotFound(roundId);
        if (updatedAt > closeTime) revert RoundAfterClose(roundId, updatedAt);
        if (closeTime - updatedAt > config.maxStaleness) revert StalePrice(updatedAt, closeTime);
        if (answer <= 0) revert InvalidPrice(answer);

        (uint80 latestRoundId,,,,) = config.feed.latestRoundData();
        if (roundId != latestRoundId) {
            uint256 nextUpdatedAt = _nextRoundUpdatedAt(config.feed, roundId);
            if (nextUpdatedAt <= closeTime) revert RoundSuperseded(roundId, nextUpdatedAt);
        }
        return answer;
    }

    /// @dev Only called when a later round exists. Within a phase the next round is roundId + 1; after an
    ///      aggregator upgrade it is round 1 of the next phase, and OCR aggregators return zeros for the
    ///      round past their last one. No try/catch: a caught out-of-gas would read as "no next round".
    function _nextRoundUpdatedAt(AggregatorV3Interface feed, uint80 roundId) internal view returns (uint256 updatedAt) {
        (,,, updatedAt,) = feed.getRoundData(roundId + 1);
        if (updatedAt != 0) return updatedAt;

        uint80 nextPhaseFirstRound = ((roundId >> PHASE_OFFSET) + 1) << PHASE_OFFSET | 1;
        (,,, updatedAt,) = feed.getRoundData(nextPhaseFirstRound);
    }

    function _isYes(Config memory config, int256 price) internal pure returns (bool) {
        if (config.comparison == Comparison.Below) return price < config.threshold;
        return price > config.threshold;
    }
}
