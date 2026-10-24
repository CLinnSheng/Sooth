// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

/// @notice Approves the seed liquidity and creates one market in a single broadcast.
/// @dev cast send can't pass this struct: its tuple parser splits on the commas inside the JSON spec.
///      Env vars: FACTORY, SPEC (spec JSON), CLOSE_TIME (unix seconds),
///      LIQUIDITY (raw collateral units, default 100e6), ARBITRATOR (default: broadcasting wallet).
///
///        SPEC="$(cat spec.json)" CLOSE_TIME=$(date -d '2026-11-30 UTC' +%s) \
///          forge script script/CreateMarket.s.sol --rpc-url $RPC --account deployer --sender $ME --broadcast
contract CreateMarket is Script {
    function run() external returns (uint256 marketId, address market) {
        IMarketFactory factory = IMarketFactory(vm.envAddress("FACTORY"));
        uint256 liquidity = vm.envOr("LIQUIDITY", uint256(100e6));

        vm.startBroadcast();
        address arbitrator = vm.envOr("ARBITRATOR", msg.sender);
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
        vm.stopBroadcast();

        console.log("Market id:", marketId);
        console.log("Market:   ", market);
    }
}
