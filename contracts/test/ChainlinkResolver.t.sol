// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IChainlinkResolver} from "../src/interfaces/IChainlinkResolver.sol";

contract ChainlinkResolverTest is Test {
    uint256 private constant LIQUIDITY = 100e6;
    uint256 private constant TRADE = 10e6;
    string private constant SPEC = "ETH/USD below 2000 at close";
    int256 private constant THRESHOLD = 2000e8;
    uint64 private constant MAX_STALENESS = 1 hours;
    /// @dev Real proxy round ids start at phase 1: (phase << 64) | aggregatorRound.
    uint80 private constant ROUND_1 = uint80(1 << 64 | 1);
    uint80 private constant ROUND_2 = uint80(1 << 64 | 2);
    uint80 private constant ROUND_3 = uint80(1 << 64 | 3);
    uint80 private constant NEXT_PHASE_ROUND_1 = uint80(2 << 64 | 1);

    MockUSDC private usdc;
    MarketFactory private factory;
    ChainlinkResolver private resolver;
    MockAggregator private feed;
    IMarket private market;
    uint64 private closeTime;
    address private admin = makeAddr("admin");
    address private alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        factory = new MarketFactory(admin, address(usdc));
        resolver = new ChainlinkResolver(admin);
        feed = new MockAggregator();
        market = _createMarket(address(resolver));
        closeTime = market.closeTime();
    }

    function _createMarket(address arbitrator) private returns (IMarket) {
        vm.startPrank(admin);
        usdc.mint(admin, LIQUIDITY);
        usdc.approve(address(factory), LIQUIDITY);
        (, address created) = factory.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: arbitrator,
                closeTime: uint64(block.timestamp + 7 days),
                initialYesProbabilityBps: 5_000,
                spec: SPEC,
                initialLiquidity: LIQUIDITY
            })
        );
        vm.stopPrank();
        return IMarket(created);
    }

    function _config(IChainlinkResolver.Comparison comparison) private view returns (IChainlinkResolver.Config memory) {
        return IChainlinkResolver.Config({
            feed: feed, threshold: THRESHOLD, comparison: comparison, maxStaleness: MAX_STALENESS
        });
    }

    function _configure(IChainlinkResolver.Comparison comparison) private {
        vm.prank(admin);
        resolver.configure(market, _config(comparison));
    }

    function _resolveAfterClose(uint80 roundId) private {
        vm.warp(closeTime + 15 minutes);
        resolver.resolve(market, roundId);
    }

    /// @dev Price set 10 minutes before close, next round 5 minutes after, so ROUND_1 is live at close.
    function _resolveWithPrice(IChainlinkResolver.Comparison comparison, int256 price)
        private
        returns (IMarket.Outcome)
    {
        _configure(comparison);
        feed.setRound(ROUND_1, price, closeTime - 10 minutes);
        feed.setRound(ROUND_2, THRESHOLD, closeTime + 5 minutes);
        _resolveAfterClose(ROUND_1);
        return market.winningOutcome();
    }

    // configure

    function test_OwnerConfiguresMarket() public {
        vm.expectEmit(true, true, false, true, address(resolver));
        emit IChainlinkResolver.MarketConfigured(
            market, feed, THRESHOLD, IChainlinkResolver.Comparison.Below, MAX_STALENESS
        );
        _configure(IChainlinkResolver.Comparison.Below);

        IChainlinkResolver.Config memory stored = resolver.configOf(market);
        assertEq(address(stored.feed), address(feed));
        assertEq(stored.threshold, THRESHOLD);
        assertEq(uint8(stored.comparison), uint8(IChainlinkResolver.Comparison.Below));
        assertEq(stored.maxStaleness, MAX_STALENESS);
    }

    function test_RevertWhen_NonOwnerConfigures() public {
        IChainlinkResolver.Config memory config = _config(IChainlinkResolver.Comparison.Below);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolver.configure(market, config);
    }

    function test_RevertWhen_MarketArbitratorIsNotResolver() public {
        IMarket other = _createMarket(admin);
        IChainlinkResolver.Config memory config = _config(IChainlinkResolver.Comparison.Below);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkResolver.MarketNotUsingResolver.selector, other));
        resolver.configure(other, config);
    }

    function test_RevertWhen_ConfiguringTwice() public {
        _configure(IChainlinkResolver.Comparison.Below);
        IChainlinkResolver.Config memory config = _config(IChainlinkResolver.Comparison.Above);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkResolver.AlreadyConfigured.selector, market));
        resolver.configure(market, config);
    }

    function test_RevertWhen_ConfiguringAfterClose() public {
        vm.warp(closeTime);
        IChainlinkResolver.Config memory config = _config(IChainlinkResolver.Comparison.Below);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkResolver.ConfigureAfterClose.selector, market));
        resolver.configure(market, config);
    }

    function test_RevertWhen_ConfigHasZeroFeed() public {
        IChainlinkResolver.Config memory config = _config(IChainlinkResolver.Comparison.Below);
        config.feed = MockAggregator(address(0));
        vm.prank(admin);
        vm.expectRevert(IChainlinkResolver.InvalidConfig.selector);
        resolver.configure(market, config);
    }

    function test_RevertWhen_ConfigHasZeroStaleness() public {
        IChainlinkResolver.Config memory config = _config(IChainlinkResolver.Comparison.Below);
        config.maxStaleness = 0;
        vm.prank(admin);
        vm.expectRevert(IChainlinkResolver.InvalidConfig.selector);
        resolver.configure(market, config);
    }

    // outcome

    function test_BelowResolvesYesWhenPriceUnderThreshold() public {
        assertEq(
            uint8(_resolveWithPrice(IChainlinkResolver.Comparison.Below, THRESHOLD - 1)), uint8(IMarket.Outcome.Yes)
        );
        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
    }

    function test_BelowResolvesNoOnTie() public {
        assertEq(uint8(_resolveWithPrice(IChainlinkResolver.Comparison.Below, THRESHOLD)), uint8(IMarket.Outcome.No));
    }

    function test_BelowResolvesNoWhenPriceOverThreshold() public {
        assertEq(
            uint8(_resolveWithPrice(IChainlinkResolver.Comparison.Below, THRESHOLD + 1)), uint8(IMarket.Outcome.No)
        );
    }

    function test_AboveResolvesYesWhenPriceOverThreshold() public {
        assertEq(
            uint8(_resolveWithPrice(IChainlinkResolver.Comparison.Above, THRESHOLD + 1)), uint8(IMarket.Outcome.Yes)
        );
    }

    function test_AboveResolvesNoOnTie() public {
        assertEq(uint8(_resolveWithPrice(IChainlinkResolver.Comparison.Above, THRESHOLD)), uint8(IMarket.Outcome.No));
    }

    function test_ResolveEmitsPriceResolved() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD - 1, closeTime - 10 minutes);
        vm.warp(closeTime + 15 minutes);

        vm.expectEmit(true, false, false, true, address(resolver));
        emit IChainlinkResolver.PriceResolved(market, ROUND_1, THRESHOLD - 1, IMarket.Outcome.Yes);
        resolver.resolve(market, ROUND_1);
    }

    // round proof

    function test_AcceptsRoundUpdatedExactlyAtClose() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD - 1, closeTime);
        feed.setRound(ROUND_2, THRESHOLD + 1, closeTime + 1);
        _resolveAfterClose(ROUND_1);
        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.Yes));
    }

    function test_AcceptsLatestRoundWhenNoLaterRoundExists() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD - 1, closeTime - 10 minutes);
        _resolveAfterClose(ROUND_1);
        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
    }

    function test_AcceptsLastRoundOfPhaseBeforeUpgrade() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD - 1, closeTime - 10 minutes);
        feed.setRound(NEXT_PHASE_ROUND_1, THRESHOLD + 1, closeTime + 5 minutes);
        _resolveAfterClose(ROUND_1);
        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.Yes));
    }

    function test_RevertWhen_RoundUpdatedAfterClose() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD, closeTime - 10 minutes);
        feed.setRound(ROUND_2, THRESHOLD, closeTime + 5 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(IChainlinkResolver.RoundAfterClose.selector, ROUND_2, closeTime + 5 minutes)
        );
        _resolveAfterClose(ROUND_2);
    }

    function test_RevertWhen_RoundSupersededBeforeClose() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD - 1, closeTime - 20 minutes);
        feed.setRound(ROUND_2, THRESHOLD + 1, closeTime - 10 minutes);
        feed.setRound(ROUND_3, THRESHOLD + 1, closeTime + 5 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(IChainlinkResolver.RoundSuperseded.selector, ROUND_1, closeTime - 10 minutes)
        );
        _resolveAfterClose(ROUND_1);
    }

    function test_RevertWhen_RoundSupersededByNextPhaseBeforeClose() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD - 1, closeTime - 20 minutes);
        feed.setRound(NEXT_PHASE_ROUND_1, THRESHOLD + 1, closeTime - 10 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(IChainlinkResolver.RoundSuperseded.selector, ROUND_1, closeTime - 10 minutes)
        );
        _resolveAfterClose(ROUND_1);
    }

    function test_RevertWhen_RoundDoesNotExist() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD, closeTime - 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkResolver.RoundNotFound.selector, ROUND_2));
        _resolveAfterClose(ROUND_2);
    }

    function test_AcceptsPriceExactlyAtMaxStaleness() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD - 1, closeTime - MAX_STALENESS);
        _resolveAfterClose(ROUND_1);
        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
    }

    function test_RevertWhen_PriceIsStale() public {
        _configure(IChainlinkResolver.Comparison.Below);
        uint256 updatedAt = closeTime - MAX_STALENESS - 1;
        feed.setRound(ROUND_1, THRESHOLD - 1, updatedAt);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkResolver.StalePrice.selector, updatedAt, closeTime));
        _resolveAfterClose(ROUND_1);
    }

    function test_RevertWhen_PriceIsNotPositive() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, 0, closeTime - 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkResolver.InvalidPrice.selector, int256(0)));
        _resolveAfterClose(ROUND_1);
    }

    function test_RevertWhen_MarketNotConfigured() public {
        feed.setRound(ROUND_1, THRESHOLD, closeTime - 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkResolver.NotConfigured.selector, market));
        _resolveAfterClose(ROUND_1);
    }

    // market-side guards

    function test_RevertWhen_ResolvingBeforeClose() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD, closeTime - 10 minutes);
        vm.warp(closeTime - 5 minutes);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Open));
        resolver.resolve(market, ROUND_1);
    }

    function test_RevertWhen_ResolvingAfterDeadline() public {
        _configure(IChainlinkResolver.Comparison.Below);
        feed.setRound(ROUND_1, THRESHOLD, closeTime - 10 minutes);
        vm.warp(market.resolutionDeadline());
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Cancelled));
        resolver.resolve(market, ROUND_1);
    }

    function test_RevertWhen_ResolvingTwice() public {
        _resolveWithPrice(IChainlinkResolver.Comparison.Below, THRESHOLD - 1);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Resolved));
        resolver.resolve(market, ROUND_1);
    }

    // end to end

    function test_WinnerRedeemsAfterChainlinkResolution() public {
        usdc.mint(alice, TRADE);
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE);
        uint256 shares = market.buy(IMarket.Outcome.Yes, TRADE, 1, block.timestamp);
        vm.stopPrank();

        _resolveWithPrice(IChainlinkResolver.Comparison.Below, 1990e8);

        vm.prank(alice);
        assertEq(market.redeem(), shares);
        assertEq(usdc.balanceOf(alice), shares);
    }
}
