// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import {IMarket} from "./IMarket.sol";

/// @title IChainlinkResolver
/// @notice Resolves price markets from a Chainlink feed. A market uses it by naming this contract as
///         its arbitrator; the owner then configures it once, and anyone can resolve after close.
interface IChainlinkResolver {
    /// @dev YES when the price is strictly below (Below) or strictly above (Above) the threshold. A tie is NO.
    enum Comparison {
        Below,
        Above
    }

    struct Config {
        AggregatorV3Interface feed;
        /// @dev In the feed's decimals, e.g. 2000_00000000 for $2000 on an 8-decimal USD feed.
        int256 threshold;
        Comparison comparison;
        /// @dev Oldest the price at close may be, in seconds. Older rounds can't resolve, so the market
        ///      cancels at its deadline instead of settling on a frozen feed.
        uint64 maxStaleness;
    }

    event MarketConfigured(
        IMarket indexed market,
        AggregatorV3Interface indexed feed,
        int256 threshold,
        Comparison comparison,
        uint64 maxStaleness
    );
    event PriceResolved(IMarket indexed market, uint80 roundId, int256 price, IMarket.Outcome outcome);

    error InvalidConfig();
    error MarketNotUsingResolver(IMarket market);
    error AlreadyConfigured(IMarket market);
    error ConfigureAfterClose(IMarket market);
    error NotConfigured(IMarket market);
    error RoundNotFound(uint80 roundId);
    error RoundAfterClose(uint80 roundId, uint256 updatedAt);
    error RoundSuperseded(uint80 roundId, uint256 nextUpdatedAt);
    error StalePrice(uint256 updatedAt, uint64 closeTime);
    error InvalidPrice(int256 answer);

    /// @notice Owner only, once per market, before it closes. The market's arbitrator must be this contract.
    function configure(IMarket market, Config calldata config) external;

    /// @notice Anyone may call after close. `roundId` must be the feed round live at the market's closeTime:
    ///         updated at or before close, with no later round updated at or before close.
    ///         The market itself rejects calls before close, after its deadline, or once resolved.
    function resolve(IMarket market, uint80 roundId) external;

    /// @notice A zero `feed` means the market is not configured.
    function configOf(IMarket market) external view returns (Config memory);
}
