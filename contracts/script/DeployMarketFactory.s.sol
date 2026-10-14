// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Deploys MarketFactory, plus MockUSDC when COLLATERAL is not set (test chains only).
/// @dev Limits come from env vars so local, demo and testnet deploys can differ (Q7):
///      MIN_DURATION (seconds, default 600), MIN_LIQUIDITY (default 10e6 = 10 USDC),
///      MAX_FEE_BPS (default 500 = 5%), COLLATERAL (default: deploy MockUSDC),
///      ADMIN (default: the broadcasting wallet).
///
///      Local: anvil, then
///        forge script script/DeployMarketFactory.s.sol --rpc-url http://127.0.0.1:8545 \
///          --broadcast --private-key <anvil key>
contract DeployMarketFactory is Script {
    function run() external returns (MarketFactory factory, address collateral) {
        // SafeCast reverts on out-of-range values instead of silently wrapping
        // (e.g. MAX_FEE_BPS=70000 would otherwise become 4464).
        uint64 minDuration = SafeCast.toUint64(vm.envOr("MIN_DURATION", uint256(10 minutes)));
        uint256 minLiquidity = vm.envOr("MIN_LIQUIDITY", uint256(10e6));
        uint16 maxFeeBps = SafeCast.toUint16(vm.envOr("MAX_FEE_BPS", uint256(500)));
        collateral = vm.envOr("COLLATERAL", address(0));

        // MockUSDC can be minted by anyone, so never make it the collateral on a real network.
        require(collateral != address(0) || _isTestChain(), "Set COLLATERAL: MockUSDC is test-chain only");

        vm.startBroadcast();
        address admin = vm.envOr("ADMIN", msg.sender);
        // Without a wallet, forge falls back to a default sender nobody controls.
        require(admin != DEFAULT_SENDER, "No deployer wallet: pass --private-key / --account, or set ADMIN");

        if (collateral == address(0)) collateral = address(new MockUSDC());
        factory = new MarketFactory(admin, minDuration, minLiquidity, maxFeeBps, collateral);
        vm.stopBroadcast();

        console.log("Admin:        ", admin);
        console.log("Collateral:   ", collateral);
        console.log("MarketFactory:", address(factory));
        console.log("OutcomeToken: ", address(factory.outcomeToken()));
        console.log("Market impl:  ", factory.implementation());
    }

    /// @dev Anvil, Base Sepolia, Ethereum Sepolia, Arbitrum Sepolia.
    function _isTestChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 84532 || block.chainid == 11155111 || block.chainid == 421614;
    }
}
