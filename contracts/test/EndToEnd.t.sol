// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {OptimisticResolver} from "../src/OptimisticResolver.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IChainlinkResolver} from "../src/interfaces/IChainlinkResolver.sol";
import {IOptimisticResolver} from "../src/interfaces/IOptimisticResolver.sol";

/// @notice Whole-lifecycle tests on the real contracts. Expected balances were worked out with an
///         independent Python model of the documented formulas (constant-product pools, 1% fee rounded
///         up, ceil on the pool update, 1 USDC per winning share, (yes + no) / 2 on cancel), not read
///         back from the contracts. Where a number is only "what the code returns" it says so.
contract EndToEndTest is Test {
    uint256 private constant LIQUIDITY = 100e6;
    uint256 private constant START = 1_000e6;
    uint256 private constant BOND = 10e6;
    uint64 private constant WINDOW = 2 hours;
    int256 private constant THRESHOLD = 2000e8;
    uint64 private constant MAX_STALENESS = 1 hours;
    uint80 private constant ROUND_1 = uint80(1 << 64 | 1);
    uint80 private constant ROUND_2 = uint80(1 << 64 | 2);
    string private constant SPEC = "Will the event happen by close?";
    string private constant EVIDENCE = "ipfs://evidence";

    // Direct route trades: alice 50 YES, bob 30 NO, carol 20 YES, alice sells 10 YES, bob sells 5 NO.
    uint256 private constant D_ALICE_YES = 72_610_367; // 82_610_367 bought - 10e6 sold
    uint256 private constant D_BOB_NO = 70_669_219; // 75_669_219 bought - 5e6 sold
    uint256 private constant D_CAROL_YES = 35_306_872;
    uint256 private constant D_ALICE_SELL_OUT = 5_856_040;
    uint256 private constant D_BOB_SELL_OUT = 2_051_371;
    uint256 private constant D_YES_POOL = 83_095_477;
    uint256 private constant D_NO_POOL = 120_343_497;
    uint256 private constant D_FEES = 1_079_873;

    // Simple trades: alice buys 20 USDC of YES, bob buys 20 USDC of NO, nothing else.
    uint256 private constant S_ALICE_YES = 36_327_545;
    uint256 private constant S_BOB_NO = 42_768_757;
    uint256 private constant S_YES_POOL = 103_272_455;
    uint256 private constant S_NO_POOL = 96_831_243;
    uint256 private constant S_FEES = 400_000; // 2 x ceil(1% of 20e6)

    MockUSDC private usdc;
    MarketFactory private factory;
    OutcomeToken private token;
    ChainlinkResolver private chainlink;
    OptimisticResolver private optimistic;
    address[] private markets;
    uint256 private minted;

    address private admin = makeAddr("admin");
    address private arbitrator = makeAddr("arbitrator");
    address private judge = makeAddr("judge");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private proposer = makeAddr("proposer");
    address private disputer = makeAddr("disputer");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        factory = new MarketFactory(admin, address(usdc));
        token = OutcomeToken(address(factory.outcomeToken()));
        chainlink = new ChainlinkResolver(admin);
        optimistic = new OptimisticResolver(judge, factory, BOND, WINDOW);
    }

    // helpers

    function _fund(address account, uint256 amount) private {
        usdc.mint(account, amount);
        minted += amount;
    }

    function _create(address resolverAddr) private returns (IMarket market) {
        _fund(admin, LIQUIDITY);
        vm.startPrank(admin);
        usdc.approve(address(factory), LIQUIDITY);
        (, address created) = factory.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: resolverAddr,
                closeTime: uint64(block.timestamp + 7 days),
                initialYesProbabilityBps: 5_000,
                spec: SPEC,
                initialLiquidity: LIQUIDITY
            })
        );
        vm.stopPrank();
        markets.push(created);
        return IMarket(created);
    }

    function _buy(IMarket market, address who, IMarket.Outcome outcome, uint256 amount) private returns (uint256) {
        vm.startPrank(who);
        usdc.approve(address(market), amount);
        uint256 shares = market.buy(outcome, amount, 0, block.timestamp);
        vm.stopPrank();
        return shares;
    }

    function _sell(IMarket market, address who, IMarket.Outcome outcome, uint256 shares) private returns (uint256) {
        vm.startPrank(who);
        token.setApprovalForAll(address(market), true);
        uint256 out = market.sell(outcome, shares, 0, block.timestamp);
        vm.stopPrank();
        return out;
    }

    /// @dev alice 20 USDC of YES, bob 20 USDC of NO. Both funded with START.
    function _simpleTrades(IMarket market) private {
        _fund(alice, START);
        _fund(bob, START);
        assertEq(_buy(market, alice, IMarket.Outcome.Yes, 20e6), S_ALICE_YES);
        assertEq(_buy(market, bob, IMarket.Outcome.No, 20e6), S_BOB_NO);
        assertEq(market.yesPool(), S_YES_POOL);
        assertEq(market.noPool(), S_NO_POOL);
        assertEq(market.accruedFees(), S_FEES);
    }

    function _redeem(IMarket market, address who) private returns (uint256) {
        vm.prank(who);
        return market.redeem();
    }

    function _settleCreator(IMarket market) private {
        vm.startPrank(admin);
        market.withdrawLiquidity();
        market.withdrawFees();
        vm.stopPrank();
    }

    /// @dev Every USDC ever minted must sit in an actor, a market, a resolver or the factory.
    function _assertConserved() private view {
        address[11] memory holders = [
            admin,
            arbitrator,
            judge,
            alice,
            bob,
            carol,
            proposer,
            disputer,
            address(factory),
            address(chainlink),
            address(optimistic)
        ];
        uint256 sum;
        for (uint256 i; i < holders.length; ++i) {
            sum += usdc.balanceOf(holders[i]);
        }
        for (uint256 i; i < markets.length; ++i) {
            sum += usdc.balanceOf(markets[i]);
        }
        assertEq(sum, minted, "USDC not conserved");
        assertEq(usdc.totalSupply(), minted);
    }

    function _proposeAndMaybeDispute(IMarket market, IMarket.Outcome outcome, bool dispute_) private {
        vm.warp(market.closeTime());
        _fund(proposer, BOND);
        vm.startPrank(proposer);
        usdc.approve(address(optimistic), BOND);
        optimistic.propose(market, outcome, EVIDENCE);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(optimistic)), BOND);
        assertEq(usdc.balanceOf(proposer), 0);
        if (dispute_) {
            _fund(disputer, BOND);
            vm.startPrank(disputer);
            usdc.approve(address(optimistic), BOND);
            optimistic.dispute(market, EVIDENCE);
            vm.stopPrank();
            assertEq(usdc.balanceOf(address(optimistic)), 2 * BOND);
            assertEq(usdc.balanceOf(disputer), 0);
        }
    }

    /// @dev After a YES resolution of the simple trades: alice redeems, bob holds only losing NO.
    function _assertSimpleYesSettlement(IMarket market) private {
        assertEq(_redeem(market, alice), S_ALICE_YES);
        vm.prank(bob);
        vm.expectRevert(IMarket.NothingToRedeem.selector);
        market.redeem();
        _settleCreator(market);

        assertEq(usdc.balanceOf(alice), START - 20e6 + S_ALICE_YES);
        assertEq(usdc.balanceOf(bob), START - 20e6);
        assertEq(usdc.balanceOf(admin), S_YES_POOL + S_FEES);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    // E2E-1 / E2E-2: direct route

    function _directTrades(IMarket market) private {
        _fund(alice, START);
        _fund(bob, START);
        _fund(carol, START);
        uint256 aliceYes = _buy(market, alice, IMarket.Outcome.Yes, 50e6);
        uint256 bobNo = _buy(market, bob, IMarket.Outcome.No, 30e6);
        uint256 carolYes = _buy(market, carol, IMarket.Outcome.Yes, 20e6);
        assertEq(aliceYes, 82_610_367);
        assertEq(bobNo, 75_669_219);
        assertEq(carolYes, D_CAROL_YES);
        assertEq(_sell(market, alice, IMarket.Outcome.Yes, 10e6), D_ALICE_SELL_OUT);
        assertEq(_sell(market, bob, IMarket.Outcome.No, 5e6), D_BOB_SELL_OUT);

        assertEq(token.balanceOf(alice, market.yesTokenId()), D_ALICE_YES);
        assertEq(token.balanceOf(bob, market.noTokenId()), D_BOB_NO);
        assertEq(token.balanceOf(carol, market.yesTokenId()), D_CAROL_YES);
        assertEq(market.yesPool(), D_YES_POOL);
        assertEq(market.noPool(), D_NO_POOL);
        assertEq(market.accruedFees(), D_FEES);
        // The market holds exactly the seed, the buys, minus the sell payouts.
        assertEq(
            usdc.balanceOf(address(market)),
            LIQUIDITY + 100e6 - D_ALICE_SELL_OUT - D_BOB_SELL_OUT,
            "market balance after trades"
        );
        // Backing: every outstanding winning-side share plus fees is covered either way.
        assertEq(usdc.balanceOf(address(market)), D_ALICE_YES + D_CAROL_YES + D_YES_POOL + D_FEES);
        assertEq(usdc.balanceOf(address(market)), D_BOB_NO + D_NO_POOL + D_FEES);
    }

    function test_E2E1_DirectYes() public {
        IMarket market = _create(arbitrator);
        _directTrades(market);

        vm.warp(market.closeTime());
        vm.prank(arbitrator);
        market.resolve(IMarket.Outcome.Yes);
        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));

        assertEq(_redeem(market, alice), D_ALICE_YES);
        assertEq(_redeem(market, carol), D_CAROL_YES);
        vm.prank(bob);
        vm.expectRevert(IMarket.NothingToRedeem.selector);
        market.redeem();
        _settleCreator(market);

        assertEq(usdc.balanceOf(alice), START - 50e6 + D_ALICE_SELL_OUT + D_ALICE_YES); // 1_028_466_407
        assertEq(usdc.balanceOf(bob), START - 30e6 + D_BOB_SELL_OUT); // 972_051_371
        assertEq(usdc.balanceOf(carol), START - 20e6 + D_CAROL_YES); // 1_015_306_872
        assertEq(usdc.balanceOf(admin), D_YES_POOL + D_FEES); // 84_175_350
        assertEq(usdc.balanceOf(alice), 1_028_466_407);
        assertEq(usdc.balanceOf(bob), 972_051_371);
        assertEq(usdc.balanceOf(carol), 1_015_306_872);
        assertEq(usdc.balanceOf(admin), 84_175_350);
        assertEq(usdc.balanceOf(address(market)), 0, "dust");
        _assertConserved();
    }

    function test_E2E2_DirectNo() public {
        IMarket market = _create(arbitrator);
        _directTrades(market);

        vm.warp(market.closeTime());
        vm.prank(arbitrator);
        market.resolve(IMarket.Outcome.No);

        assertEq(_redeem(market, bob), D_BOB_NO);
        vm.prank(alice);
        vm.expectRevert(IMarket.NothingToRedeem.selector);
        market.redeem();
        vm.prank(carol);
        vm.expectRevert(IMarket.NothingToRedeem.selector);
        market.redeem();
        _settleCreator(market);

        assertEq(usdc.balanceOf(alice), 955_856_040); // START - 50e6 + sell out
        assertEq(usdc.balanceOf(bob), 1_042_720_590); // START - 30e6 + sell out + NO redeem
        assertEq(usdc.balanceOf(carol), 980_000_000);
        assertEq(usdc.balanceOf(admin), 121_423_370); // NO pool + fees
        assertEq(usdc.balanceOf(alice), START - 50e6 + D_ALICE_SELL_OUT);
        assertEq(usdc.balanceOf(bob), START - 30e6 + D_BOB_SELL_OUT + D_BOB_NO);
        assertEq(usdc.balanceOf(admin), D_NO_POOL + D_FEES);
        assertEq(usdc.balanceOf(address(market)), 0, "dust");
        _assertConserved();
    }

    // E2E-3: Chainlink route

    /// @dev One YES buyer and one NO buyer per market, fresh feed, price live at close is `price`.
    function _runPriceMarket(IChainlinkResolver.Comparison comparison, int256 price, IMarket.Outcome expected) private {
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 adminBefore = usdc.balanceOf(admin);

        IMarket market = _create(address(chainlink));
        MockAggregator feed = new MockAggregator();
        vm.prank(admin);
        chainlink.configure(
            market,
            IChainlinkResolver.Config({
                feed: feed, threshold: THRESHOLD, comparison: comparison, maxStaleness: MAX_STALENESS
            })
        );
        _simpleTrades(market);

        // ROUND_1 is live at close, ROUND_2 lands after it.
        feed.setRound(ROUND_1, price, market.closeTime() - 10 minutes);
        feed.setRound(ROUND_2, THRESHOLD, market.closeTime() + 5 minutes);
        vm.warp(market.closeTime() + 15 minutes);
        vm.prank(makeAddr("anyone"));
        chainlink.resolve(market, ROUND_1);
        assertEq(uint8(market.winningOutcome()), uint8(expected));

        if (expected == IMarket.Outcome.Yes) {
            assertEq(_redeem(market, alice), S_ALICE_YES);
            vm.prank(bob);
            vm.expectRevert(IMarket.NothingToRedeem.selector);
            market.redeem();
            _settleCreator(market);
            assertEq(usdc.balanceOf(alice) - aliceBefore, START - 20e6 + S_ALICE_YES);
            assertEq(usdc.balanceOf(bob) - bobBefore, START - 20e6);
            assertEq(usdc.balanceOf(admin) - adminBefore, S_YES_POOL + S_FEES);
            assertEq(usdc.balanceOf(address(market)), 0, "dust");
        } else {
            assertEq(_redeem(market, bob), S_BOB_NO);
            vm.prank(alice);
            vm.expectRevert(IMarket.NothingToRedeem.selector);
            market.redeem();
            _settleCreator(market);
            assertEq(usdc.balanceOf(alice) - aliceBefore, START - 20e6);
            assertEq(usdc.balanceOf(bob) - bobBefore, START - 20e6 + S_BOB_NO);
            assertEq(usdc.balanceOf(admin) - adminBefore, S_NO_POOL + S_FEES);
            assertEq(usdc.balanceOf(address(market)), 0, "dust");
        }
        _assertConserved();
    }

    function test_E2E3_ChainlinkAboveBelowAndTie() public {
        // Above 2000: 2100 -> YES.
        _runPriceMarket(IChainlinkResolver.Comparison.Above, 2100e8, IMarket.Outcome.Yes);
        // Above 2000: 1900 -> NO.
        _runPriceMarket(IChainlinkResolver.Comparison.Above, 1900e8, IMarket.Outcome.No);
        // Exact tie -> NO, documented in IChainlinkResolver ("A tie is NO"), for both comparisons.
        _runPriceMarket(IChainlinkResolver.Comparison.Above, THRESHOLD, IMarket.Outcome.No);
        _runPriceMarket(IChainlinkResolver.Comparison.Below, THRESHOLD, IMarket.Outcome.No);
        // Below 2000: 1900 -> YES.
        _runPriceMarket(IChainlinkResolver.Comparison.Below, 1900e8, IMarket.Outcome.Yes);

        assertEq(usdc.balanceOf(address(chainlink)), 0);
        assertEq(markets.length, 5);
    }

    // E2E-4 .. E2E-6: optimistic route

    function test_E2E4_OptimisticUndisputed() public {
        IMarket market = _create(address(optimistic));
        _simpleTrades(market);
        _proposeAndMaybeDispute(market, IMarket.Outcome.Yes, false);

        // One second before the window ends: cannot finalize.
        vm.warp(block.timestamp + WINDOW - 1);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.ChallengeWindowOpen.selector, block.timestamp + 1));
        optimistic.finalize(market);

        vm.warp(block.timestamp + 1);
        vm.prank(makeAddr("anyone"));
        optimistic.finalize(market);

        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.Yes));
        assertEq(usdc.balanceOf(proposer), BOND, "bond returned");
        assertEq(usdc.balanceOf(address(optimistic)), 0);

        _assertSimpleYesSettlement(market);
        assertEq(usdc.balanceOf(disputer), 0);
        _assertConserved();
    }

    function test_E2E5_OptimisticDisputedJudgeUpholds() public {
        IMarket market = _create(address(optimistic));
        _simpleTrades(market);
        _proposeAndMaybeDispute(market, IMarket.Outcome.Yes, true);

        vm.prank(judge);
        optimistic.rule(market, IMarket.Outcome.Yes);

        assertEq(usdc.balanceOf(proposer), 2 * BOND, "proposer takes both bonds");
        assertEq(usdc.balanceOf(disputer), 0);
        assertEq(usdc.balanceOf(address(optimistic)), 0);
        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.Yes));

        _assertSimpleYesSettlement(market);
        _assertConserved();
    }

    function test_E2E6_OptimisticDisputedJudgeOverturns() public {
        IMarket market = _create(address(optimistic));
        _simpleTrades(market);
        _proposeAndMaybeDispute(market, IMarket.Outcome.Yes, true);

        vm.prank(judge);
        optimistic.rule(market, IMarket.Outcome.No);

        assertEq(usdc.balanceOf(disputer), 2 * BOND, "disputer takes both bonds");
        assertEq(usdc.balanceOf(proposer), 0);
        assertEq(usdc.balanceOf(address(optimistic)), 0);
        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.No), "judge's outcome, not the proposal");

        assertEq(_redeem(market, bob), S_BOB_NO);
        vm.prank(alice);
        vm.expectRevert(IMarket.NothingToRedeem.selector);
        market.redeem();
        _settleCreator(market);

        assertEq(usdc.balanceOf(alice), START - 20e6);
        assertEq(usdc.balanceOf(bob), START - 20e6 + S_BOB_NO); // 1_022_768_757
        assertEq(usdc.balanceOf(admin), S_NO_POOL + S_FEES); // 97_231_243
        assertEq(usdc.balanceOf(address(market)), 0, "dust");
        _assertConserved();
    }

    // E2E-7 / E2E-8: cancel route

    /// @dev Cancelled payouts: floor((yes + no) / 2) per holder, so 1 unit of rounding dust stays behind.
    function _assertSimpleCancelSettlement(IMarket market) private {
        assertEq(uint8(market.state()), uint8(IMarket.State.Cancelled));
        assertEq(_redeem(market, alice), S_ALICE_YES / 2); // 18_163_772
        assertEq(_redeem(market, bob), S_BOB_NO / 2); // 21_384_378
        _settleCreator(market);

        assertEq(usdc.balanceOf(alice), 998_163_772);
        assertEq(usdc.balanceOf(bob), 1_001_384_378);
        // (103_272_455 + 96_831_243) / 2 + 400_000 fees
        assertEq(usdc.balanceOf(admin), 100_451_849);
        // 140_000_000 in, 139_999_999 out: the single unit is floor() dust from alice's odd share count.
        assertEq(usdc.balanceOf(address(market)), 1, "dust");
        _assertConserved();
    }

    function test_E2E7_TimeoutCancelsAndRefunds() public {
        IMarket market = _create(address(arbitrator));
        _simpleTrades(market);

        // Last second before the deadline: still Closed, arbitrator could resolve. Nobody does.
        vm.warp(market.resolutionDeadline() - 1);
        assertEq(uint8(market.state()), uint8(IMarket.State.Closed));
        vm.warp(market.resolutionDeadline());
        assertEq(uint8(market.state()), uint8(IMarket.State.Cancelled));

        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Cancelled));
        market.resolve(IMarket.Outcome.Yes);

        _assertSimpleCancelSettlement(market);
    }

    function test_E2E8_OptimisticDisputedLeftOpenRefundsBothBonds() public {
        IMarket market = _create(address(optimistic));
        _simpleTrades(market);
        _proposeAndMaybeDispute(market, IMarket.Outcome.Yes, true);

        // Judge never rules. Before the deadline the bonds stay locked.
        vm.warp(market.resolutionDeadline() - 1);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.MarketNotCancelled.selector, IMarket.State.Closed));
        optimistic.refund(market);

        vm.warp(market.resolutionDeadline());
        // Neither path can settle it any more.
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Cancelled));
        optimistic.rule(market, IMarket.Outcome.Yes);

        vm.prank(makeAddr("anyone"));
        optimistic.refund(market);

        assertEq(usdc.balanceOf(proposer), BOND);
        assertEq(usdc.balanceOf(disputer), BOND);
        assertEq(usdc.balanceOf(address(optimistic)), 0, "nothing stuck in the resolver");
        assertEq(uint8(optimistic.requestOf(market).status), uint8(IOptimisticResolver.Status.Settled));

        // Second refund is not possible.
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.Settled)
        );
        optimistic.refund(market);

        _assertSimpleCancelSettlement(market);
    }

    function test_E2E8b_OptimisticProposedOnlyLeftOpenRefundsProposer() public {
        IMarket market = _create(address(optimistic));
        _simpleTrades(market);
        _proposeAndMaybeDispute(market, IMarket.Outcome.No, false);

        // Window ends well before the deadline but nobody calls finalize.
        vm.warp(market.resolutionDeadline());
        vm.expectRevert(abi.encodeWithSelector(IMarket.CannotResolve.selector, IMarket.State.Cancelled));
        optimistic.finalize(market);

        optimistic.refund(market);
        assertEq(usdc.balanceOf(proposer), BOND);
        assertEq(usdc.balanceOf(disputer), 0);
        assertEq(usdc.balanceOf(address(optimistic)), 0, "nothing stuck in the resolver");

        _assertSimpleCancelSettlement(market);
    }
}
