// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {IOutcomeToken} from "../../src/interfaces/IOutcomeToken.sol";

/// @notice Shared clock for both handlers and the invariant contract. Every handler call and every
///         invariant check warps to `time` first, so the fuzzed sequence sees one monotonic clock
///         whether or not the runner keeps `vm.warp` between calls.
contract Clock {
    uint256 public time;

    constructor(uint256 start) {
        time = start;
    }

    function set(uint256 t) external {
        time = t;
    }
}

/// @notice Wiring shared by the market and resolver handlers.
/// @dev Handler-side checks never use `assert*`: with `fail_on_revert = false` a failing assert in a
///      handler is just a reverted call and would be ignored. They bump a ghost counter instead, and an
///      `invariant_*` function requires the counter to be 0. Arithmetic in checks is written so it
///      cannot underflow, so a bad state is counted rather than reverted away.
abstract contract HandlerBase is CommonBase, StdCheats, StdUtils {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE_BPS = 100;

    MockUSDC public immutable usdc;
    IOutcomeToken public immutable token;
    Clock public immutable clock;

    IMarket[] internal _markets;
    address[] internal _actors;

    constructor(
        MockUSDC usdc_,
        IOutcomeToken token_,
        Clock clock_,
        IMarket[] memory markets_,
        address[] memory actors_
    ) {
        usdc = usdc_;
        token = token_;
        clock = clock_;
        for (uint256 i; i < markets_.length; ++i) {
            _markets.push(markets_[i]);
        }
        for (uint256 i; i < actors_.length; ++i) {
            _actors.push(actors_[i]);
        }
    }

    modifier synced() {
        vm.warp(clock.time());
        _;
    }

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    /// @dev Time only moves forward.
    function _advanceTo(uint256 t) internal {
        if (t <= vm.getBlockTimestamp()) return;
        vm.warp(t);
        clock.set(t);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _outcome(uint256 seed) internal pure returns (IMarket.Outcome) {
        return IMarket.Outcome(seed % 2);
    }

    function _id(IMarket market, IMarket.Outcome outcome) internal view returns (uint256) {
        return outcome == IMarket.Outcome.Yes ? market.yesTokenId() : market.noTokenId();
    }

    function _ceilFee(uint256 amount) internal pure returns (uint256) {
        return (amount * FEE_BPS + BPS - 1) / BPS;
    }
}
