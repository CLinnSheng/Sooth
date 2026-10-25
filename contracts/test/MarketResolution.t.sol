// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IOutcomeToken} from "../src/interfaces/IOutcomeToken.sol";

contract MarketResolutionTest is Test {
    uint256 private constant LIQUIDITY = 100e6;
    uint256 private constant TRADE = 10e6;
    string private constant SPEC = "market rules";
    /// @dev Cancelled payouts round down at most half a raw unit for each of the 3 traders and the pool.
    uint256 private constant MAX_CANCEL_DUST = 2;
    /// @dev Keeps part of the position so the seller still has a payout to redeem.
    uint256 private constant MAX_SELL_BPS = 9_000;
    /// @dev Smaller sells can round to zero output and revert.
    uint256 private constant MIN_SELL = 0.01e6;

    MockUSDC private usdc;
    IOutcomeToken private token;
    Market private market;
    address private admin = makeAddr("admin");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private arbitrator = makeAddr("arbitrator");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        MarketFactory factory = new MarketFactory(admin, address(usdc));
        token = factory.outcomeToken();

        usdc.mint(admin, LIQUIDITY);
        vm.startPrank(admin);
        usdc.approve(address(factory), LIQUIDITY);
        (, address marketAddress) = factory.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: arbitrator,
                closeTime: uint64(block.timestamp + 7 days),
                initialYesProbabilityBps: 5_000,
                spec: SPEC,
                initialLiquidity: LIQUIDITY
            })
        );
        vm.stopPrank();
        market = Market(marketAddress);
    }

    function _buy(address trader, IMarket.Outcome outcome, uint256 amount) private returns (uint256 shares) {
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(market), amount);
        shares = market.buy(outcome, amount, 1, block.timestamp);
        vm.stopPrank();
    }

    function _sell(address trader, IMarket.Outcome outcome, uint256 shares) private {
        vm.startPrank(trader);
        token.setApprovalForAll(address(market), true);
        market.sell(outcome, shares, 1, block.timestamp);
        vm.stopPrank();
    }

    function _resolve(IMarket.Outcome outcome) private {
        vm.warp(market.closeTime());
        vm.prank(arbitrator);
        market.resolve(outcome);
    }

    function _cancel() private {
        vm.warp(market.resolutionDeadline());
    }

    function _redeem(address holder) private returns (uint256) {
        vm.prank(holder);
        return market.redeem();
    }

    function test_StateMovesFromOpenToClosedToCancelledWithoutTransactions() public {
        assertEq(uint8(market.state()), uint8(IMarket.State.Open));
        vm.warp(market.closeTime());
        assertEq(uint8(market.state()), uint8(IMarket.State.Closed));
        vm.warp(market.resolutionDeadline() - 1);
        assertEq(uint8(market.state()), uint8(IMarket.State.Closed));
        _cancel();
        assertEq(uint8(market.state()), uint8(IMarket.State.Cancelled));
    }

    function test_ArbitratorResolvesClosedMarket() public {
        vm.warp(market.closeTime());
        vm.expectEmit(true, false, false, true, address(market));
        emit IMarket.MarketResolved(IMarket.Outcome.No);
        vm.prank(arbitrator);
        market.resolve(IMarket.Outcome.No);

        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.No));
    }

    function test_ResolvedMarketStaysResolvedPastDeadline() public {
        _resolve(IMarket.Outcome.Yes);
        _cancel();
        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
    }

    function test_RevertWhen_ResolverIsNotArbitrator() public {
        vm.warp(market.closeTime());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotArbitrator.selector, alice));
        market.resolve(IMarket.Outcome.Yes);
    }

    function test_RevertWhen_ResolvingOpenMarket() public {
        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Open));
        market.resolve(IMarket.Outcome.Yes);
    }

    function test_RevertWhen_ResolvingAtDeadline() public {
        _cancel();
        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Cancelled));
        market.resolve(IMarket.Outcome.Yes);
    }

    function test_RevertWhen_ResolvingTwice() public {
        _resolve(IMarket.Outcome.Yes);
        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Resolved));
        market.resolve(IMarket.Outcome.No);
    }

    function test_WinnerRedeemsOneCollateralPerShare() public {
        uint256 shares = _buy(alice, IMarket.Outcome.Yes, TRADE);
        _resolve(IMarket.Outcome.Yes);

        vm.expectEmit(true, false, false, true, address(market));
        emit IMarket.Redeemed(alice, shares);
        assertEq(_redeem(alice), shares);

        assertEq(usdc.balanceOf(alice), shares);
        assertEq(token.balanceOf(alice, market.yesTokenId()), 0);
    }

    function test_RedeemBurnsLosingSharesAlongsideWinners() public {
        uint256 yesShares = _buy(alice, IMarket.Outcome.Yes, TRADE);
        _buy(alice, IMarket.Outcome.No, TRADE);
        _resolve(IMarket.Outcome.Yes);

        assertEq(_redeem(alice), yesShares);
        assertEq(token.balanceOf(alice, market.noTokenId()), 0);
    }

    function test_RevertWhen_LoserRedeems() public {
        _buy(alice, IMarket.Outcome.No, TRADE);
        _resolve(IMarket.Outcome.Yes);
        vm.prank(alice);
        vm.expectRevert(IMarket.NothingToRedeem.selector);
        market.redeem();
    }

    function test_RevertWhen_RedeemingTwice() public {
        _buy(alice, IMarket.Outcome.Yes, TRADE);
        _resolve(IMarket.Outcome.Yes);
        _redeem(alice);
        vm.prank(alice);
        vm.expectRevert(IMarket.NothingToRedeem.selector);
        market.redeem();
    }

    function test_RevertWhen_RedeemingBeforeSettlement() public {
        _buy(alice, IMarket.Outcome.Yes, TRADE);
        vm.warp(market.closeTime());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotSettled.selector, IMarket.State.Closed));
        market.redeem();
    }

    function test_CancelledRedeemPaysHalfPerShare() public {
        uint256 yesShares = _buy(alice, IMarket.Outcome.Yes, TRADE);
        uint256 noShares = _buy(alice, IMarket.Outcome.No, TRADE);
        _cancel();

        assertEq(_redeem(alice), (yesShares + noShares) / 2);
        assertEq(token.balanceOf(alice, market.yesTokenId()), 0);
        assertEq(token.balanceOf(alice, market.noTokenId()), 0);
    }

    function test_CancelledRedeemRoundsDown() public {
        uint256 shares = _buy(alice, IMarket.Outcome.Yes, TRADE);
        uint256 yesId = market.yesTokenId();
        vm.prank(alice);
        token.safeTransferFrom(alice, bob, yesId, shares - 3, "");
        _cancel();

        assertEq(_redeem(alice), 1);
    }

    function test_WithdrawLiquidityPaysWinningPoolToCreator() public {
        _buy(alice, IMarket.Outcome.Yes, TRADE);
        _resolve(IMarket.Outcome.No);
        uint256 noPool = market.noPool();

        vm.expectEmit(true, false, false, true, address(market));
        emit IMarket.LiquidityWithdrawn(admin, noPool);
        assertEq(market.withdrawLiquidity(), noPool);

        assertEq(usdc.balanceOf(admin), noPool);
        assertEq(token.balanceOf(address(market), market.yesTokenId()), 0);
        assertEq(token.balanceOf(address(market), market.noTokenId()), 0);
        assertTrue(market.liquidityWithdrawn());
    }

    function test_WithdrawLiquidityAfterCancelPaysHalfThePool() public {
        _buy(alice, IMarket.Outcome.Yes, TRADE);
        _cancel();
        uint256 expected = (market.yesPool() + market.noPool()) / 2;

        assertEq(market.withdrawLiquidity(), expected);
    }

    function test_PriceStillReadableAfterLiquidityWithdrawn() public {
        _buy(alice, IMarket.Outcome.Yes, TRADE);
        uint256 priceBefore = market.priceYes();
        _resolve(IMarket.Outcome.Yes);
        market.withdrawLiquidity();

        assertEq(market.priceYes(), priceBefore);
    }

    function test_RevertWhen_WithdrawingLiquidityTwice() public {
        _resolve(IMarket.Outcome.Yes);
        market.withdrawLiquidity();
        vm.expectRevert(IMarket.LiquidityAlreadyWithdrawn.selector);
        market.withdrawLiquidity();
    }

    function test_RevertWhen_WithdrawingLiquidityBeforeSettlement() public {
        vm.warp(market.closeTime());
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotSettled.selector, IMarket.State.Closed));
        market.withdrawLiquidity();
    }

    /// @param ending 0 = YES wins, 1 = NO wins, 2 = cancelled.
    function testFuzz_EveryoneExitsAndOnlyDustRemains(
        uint256 aliceIn,
        uint256 bobIn,
        uint256 carolIn,
        uint256 sellBps,
        uint256 ending
    ) public {
        aliceIn = bound(aliceIn, 1e6, 1_000_000e6);
        bobIn = bound(bobIn, 1e6, 1_000_000e6);
        carolIn = bound(carolIn, 1e6, 1_000_000e6);
        ending = bound(ending, 0, 2);

        uint256 aliceShares = _buy(alice, IMarket.Outcome.Yes, aliceIn);
        // Sell before the others trade: a huge opposite buy could make Alice's shares worth zero.
        uint256 aliceSold = aliceShares * bound(sellBps, 0, MAX_SELL_BPS) / 10_000;
        if (aliceSold >= MIN_SELL) _sell(alice, IMarket.Outcome.Yes, aliceSold);
        _buy(bob, IMarket.Outcome.No, bobIn);
        _buy(carol, IMarket.Outcome.Yes, carolIn);

        bool isCancelled = ending == 2;
        if (isCancelled) _cancel();
        else _resolve(IMarket.Outcome(ending));

        if (ending != uint256(IMarket.Outcome.No)) {
            _redeem(alice);
            _redeem(carol);
        }
        if (ending != uint256(IMarket.Outcome.Yes)) _redeem(bob);
        market.withdrawLiquidity();
        market.withdrawFees();

        uint256 dust = usdc.balanceOf(address(market));
        if (isCancelled) assertLe(dust, MAX_CANCEL_DUST);
        else assertEq(dust, 0);
    }
}
