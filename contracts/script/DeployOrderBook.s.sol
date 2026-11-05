// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OutcomeOrderBook} from "../src/OutcomeOrderBook.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

/// @notice Deploys OutcomeOrderBook. It serves every market of FACTORY; no per-market setup and no owner.
/// @dev Env vars: FACTORY.
///
///        FACTORY=0x... \
///          forge script script/DeployOrderBook.s.sol --rpc-url $RPC --account deployer --sender $ME --broadcast
contract DeployOrderBook is Script {
    function run() external returns (OutcomeOrderBook orderBook) {
        IMarketFactory factory = IMarketFactory(vm.envAddress("FACTORY"));

        vm.startBroadcast();
        orderBook = new OutcomeOrderBook(factory);
        vm.stopBroadcast();

        console.log("Factory:         ", address(factory));
        console.log("Outcome token:   ", address(orderBook.outcomeToken()));
        console.log("OutcomeOrderBook:", address(orderBook));
    }
}
