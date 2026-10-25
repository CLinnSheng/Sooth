// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OptimisticResolver} from "../src/OptimisticResolver.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

/// @notice Deploys OptimisticResolver. Markets created with ARBITRATOR set to it need no further setup.
/// @dev Env vars: FACTORY, ADMIN (judge, default: broadcasting wallet), BOND (raw collateral units,
///      default 10e6), CHALLENGE_WINDOW (seconds, default 7200).
///
///        FACTORY=0x... \
///          forge script script/DeployOptimisticResolver.s.sol --rpc-url $RPC --account deployer --sender $ME --broadcast
contract DeployOptimisticResolver is Script {
    uint256 internal constant DEFAULT_BOND = 10e6;
    uint64 internal constant DEFAULT_CHALLENGE_WINDOW = 2 hours;

    function run() external returns (OptimisticResolver resolver) {
        IMarketFactory factory = IMarketFactory(vm.envAddress("FACTORY"));
        uint256 bond = vm.envOr("BOND", DEFAULT_BOND);
        uint64 challengeWindow = uint64(vm.envOr("CHALLENGE_WINDOW", uint256(DEFAULT_CHALLENGE_WINDOW)));

        vm.startBroadcast();
        address judge = vm.envOr("ADMIN", msg.sender);
        // Without a wallet, forge falls back to a default sender nobody controls.
        require(judge != DEFAULT_SENDER, "No deployer wallet: pass --private-key / --account, or set ADMIN");

        resolver = new OptimisticResolver(judge, factory, bond, challengeWindow);
        vm.stopBroadcast();

        console.log("Judge:             ", judge);
        console.log("Bond:              ", bond);
        console.log("Challenge window:  ", challengeWindow);
        console.log("OptimisticResolver:", address(resolver));
    }
}
