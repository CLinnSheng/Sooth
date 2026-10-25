// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IChainlinkResolver} from "../src/interfaces/IChainlinkResolver.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Finds the Chainlink round live at a market's closeTime and resolves the market with it.
///         Anyone can run it once the market has closed.
/// @dev Env vars: RESOLVER, MARKET, ROUND_ID (optional, skips the search).
///      shortcut: searches the feed's current phase only; if the market closed before an aggregator
///      upgrade, find the round by hand and pass ROUND_ID.
///
///        RESOLVER=0x... MARKET=0x... \
///          forge script script/ResolveChainlinkMarket.s.sol --rpc-url $RPC --account deployer --sender $ME --broadcast
contract ResolveChainlinkMarket is Script {
    /// @dev Proxy round ids are (phaseId << 64 | aggregatorRoundId).
    uint256 internal constant PHASE_OFFSET = 64;

    function run() external returns (uint80 roundId) {
        IChainlinkResolver resolver = IChainlinkResolver(vm.envAddress("RESOLVER"));
        IMarket market = IMarket(vm.envAddress("MARKET"));
        roundId = uint80(vm.envOr("ROUND_ID", uint256(0)));
        if (roundId == 0) {
            AggregatorV3Interface feed = resolver.configOf(market).feed;
            require(address(feed) != address(0), "Market is not configured on this resolver");
            roundId = _roundAtClose(feed, market.closeTime());
        }

        vm.startBroadcast();
        resolver.resolve(market, roundId);
        vm.stopBroadcast();

        console.log("Round id:", roundId);
        console.log("Outcome: ", market.winningOutcome() == IMarket.Outcome.Yes ? "YES" : "NO");
    }

    /// @dev Binary search for the last round updated at or before close. Rounds within a phase have
    ///      consecutive ids and rising timestamps. Invariant: low is at or before close, high is after it.
    function _roundAtClose(AggregatorV3Interface feed, uint64 closeTime) internal view returns (uint80) {
        (uint80 high,,, uint256 latestUpdatedAt,) = feed.latestRoundData();
        if (latestUpdatedAt <= closeTime) return high;

        uint80 low = high >> PHASE_OFFSET << PHASE_OFFSET | 1;
        (,,, uint256 firstUpdatedAt,) = feed.getRoundData(low);
        require(firstUpdatedAt <= closeTime, "Market closed before the current phase: pass ROUND_ID");

        while (high - low > 1) {
            uint80 mid = low + (high - low) / 2;
            (,,, uint256 midUpdatedAt,) = feed.getRoundData(mid);
            if (midUpdatedAt <= closeTime) low = mid;
            else high = mid;
        }
        return low;
    }
}
