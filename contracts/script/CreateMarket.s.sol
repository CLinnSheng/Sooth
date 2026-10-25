// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IChainlinkResolver} from "../src/interfaces/IChainlinkResolver.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Approves the seed liquidity and creates one market in a single broadcast.
/// @dev cast send can't pass this struct: its tuple parser splits on the commas inside the JSON spec.
///      Env vars: FACTORY, SPEC (spec JSON), CLOSE_TIME (unix seconds),
///      LIQUIDITY (raw collateral units, default 100e6), ARBITRATOR (default: broadcasting wallet).
///      Chainlink price market: set FEED, RESOLVER, THRESHOLD (in feed decimals), COMPARISON (below|above)
///      and optionally MAX_STALENESS (seconds, default 3600). The resolver replaces ARBITRATOR and is
///      configured in the same broadcast, so the wallet must be both factory admin and resolver owner.
///
///        SPEC="$(cat spec.json)" CLOSE_TIME=$(date -d '2026-11-30 UTC' +%s) \
///          forge script script/CreateMarket.s.sol --rpc-url $RPC --account deployer --sender $ME --broadcast
contract CreateMarket is Script {
    uint64 internal constant DEFAULT_MAX_STALENESS = 1 hours;

    function run() external returns (uint256 marketId, address market) {
        IMarketFactory factory = IMarketFactory(vm.envAddress("FACTORY"));
        uint256 liquidity = vm.envOr("LIQUIDITY", uint256(100e6));
        address feed = vm.envOr("FEED", address(0));
        bool isChainlinkMarket = feed != address(0);
        // Read and check the config before broadcasting, so bad input can't leave an unconfigured market.
        IChainlinkResolver.Config memory config;
        if (isChainlinkMarket) config = _chainlinkConfig(feed);

        vm.startBroadcast();
        address arbitrator = isChainlinkMarket ? vm.envAddress("RESOLVER") : vm.envOr("ARBITRATOR", msg.sender);
        factory.collateral().approve(address(factory), liquidity);
        (marketId, market) = factory.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: arbitrator,
                closeTime: uint64(vm.envUint("CLOSE_TIME")),
                initialYesProbabilityBps: 5_000,
                spec: vm.envString("SPEC"),
                initialLiquidity: liquidity
            })
        );
        if (isChainlinkMarket) IChainlinkResolver(arbitrator).configure(IMarket(market), config);
        vm.stopBroadcast();

        console.log("Market id:", marketId);
        console.log("Market:   ", market);
        if (isChainlinkMarket) console.log("Resolver: ", arbitrator);
    }

    function _chainlinkConfig(address feed) internal view returns (IChainlinkResolver.Config memory) {
        return IChainlinkResolver.Config({
            feed: AggregatorV3Interface(feed),
            threshold: vm.envInt("THRESHOLD"),
            comparison: _comparison(vm.envString("COMPARISON")),
            maxStaleness: uint64(vm.envOr("MAX_STALENESS", uint256(DEFAULT_MAX_STALENESS)))
        });
    }

    function _comparison(string memory name) internal pure returns (IChainlinkResolver.Comparison) {
        bytes32 nameHash = keccak256(bytes(name));
        if (nameHash == keccak256("below")) return IChainlinkResolver.Comparison.Below;
        if (nameHash == keccak256("above")) return IChainlinkResolver.Comparison.Above;
        revert("COMPARISON must be below or above");
    }
}
