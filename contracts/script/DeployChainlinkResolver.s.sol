// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";

/// @notice Deploys ChainlinkResolver. Markets naming it as arbitrator are configured by CreateMarket.
/// @dev Env vars: ADMIN (default: broadcasting wallet), the only account that can configure markets.
///
///        forge script script/DeployChainlinkResolver.s.sol --rpc-url $RPC --account deployer --sender $ME --broadcast
contract DeployChainlinkResolver is Script {
    function run() external returns (ChainlinkResolver resolver) {
        vm.startBroadcast();
        address admin = vm.envOr("ADMIN", msg.sender);
        // Without a wallet, forge falls back to a default sender nobody controls.
        require(admin != DEFAULT_SENDER, "No deployer wallet: pass --private-key / --account, or set ADMIN");

        resolver = new ChainlinkResolver(admin);
        vm.stopBroadcast();

        console.log("Admin:            ", admin);
        console.log("ChainlinkResolver:", address(resolver));
    }
}
