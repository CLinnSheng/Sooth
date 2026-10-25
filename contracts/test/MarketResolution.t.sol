// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IOutcomeToken} from "../src/interfaces/IOutcomeToken.sol";

/// @dev Collateral that tries to reenter the market whenever it pays someone.
contract ReentrantPayoutToken is MockUSDC {
    Market public target;
    bytes4 public redeemError;
    bytes4 public claimError;

    function setTarget(Market target_) external {
        target = target_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (address(target) != address(0)) {
            try target.redeem(1, 0) returns (uint256) {
                revert("Reentry succeeded");
            } catch (bytes memory reason) {
                // forge-lint: disable-next-line(unsafe-typecast)
                redeemError = bytes4(reason);
            }
            try target.claimLiquidity() returns (uint256) {
                revert("Reentry succeeded");
            } catch (bytes memory reason) {
                // forge-lint: disable-next-line(unsafe-typecast)
                claimError = bytes4(reason);
            }
        }
        return success;
    }
}

contract MarketResolutionTest is Test {
    uint256 private constant LIQUIDITY = 100e6;
    string private constant SPEC = "market rules";

    MockUSDC private usdc;
    IOutcomeToken private token;
    Market private market;
    MarketFactory private factory;
    address private admin = makeAddr("admin");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private arbitrator = makeAddr("arbitrator");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        (factory, market) = _deploy(usdc);
        token = factory.outcomeToken();
        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
    }

    // ---------------------------------------------------------------- helpers

    function _deploy(MockUSDC collateral) private returns (MarketFactory factory_, Market market_) {
        factory_ = new MarketFactory(admin, address(collateral));
        collateral.mint(admin, 1_000e6);
        vm.startPrank(admin);
        collateral.approve(address(factory_), type(uint256).max);
        (, address marketAddress) = factory_.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: arbitrator,
                closeTime: uint64(block.timestamp + 7 days),
                initialYesProbabilityBps: 5_000,
                spec: SPEC,
                initialLiquidity: LIQUIDITY
            })
        );
        vm.stopPrank();
        market_ = Market(marketAddress);
    }

    function _buy(address trader, IMarket.Outcome outcome, uint256 amount) private returns (uint256 shares) {
        vm.startPrank(trader);
        usdc.approve(address(market), type(uint256).max);
        shares = market.buy(outcome, amount, 1, block.timestamp);
        vm.stopPrank();
    }

    function _close() private {
        vm.warp(market.closeTime());
    }

    function _resolve(IMarket.Resolution resolution) private {
        _close();
        vm.prank(arbitrator);
        market.resolve(resolution);
    }

    function _yes(address account) private view returns (uint256) {
        return token.balanceOf(account, market.yesTokenId());
    }

    function _no(address account) private view returns (uint256) {
        return token.balanceOf(account, market.noTokenId());
    }

    /// @dev Redeems everything `account` holds; returns the payout (0 if it held nothing).
    function _redeemAll(address account) private returns (uint256) {
        uint256 yesAmount = _yes(account);
        uint256 noAmount = _no(account);
        if (yesAmount == 0 && noAmount == 0) return 0;
        vm.prank(account);
        return market.redeem(yesAmount, noAmount);
    }

    // ------------------------------------------------------------- resolve (E3-1)

    function test_ArbitratorResolvesYesAfterClose() public {
        _close();
        vm.expectEmit(address(market));
        emit IMarket.MarketResolved(IMarket.Resolution.Yes, arbitrator);
        vm.prank(arbitrator);
        market.resolve(IMarket.Resolution.Yes);

        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
        assertEq(uint8(market.finalResolution()), uint8(IMarket.Resolution.Yes));
    }

    function test_ArbitratorCanResolveUntilJustBeforeDeadline() public {
        vm.warp(market.resolutionDeadline() - 1);
        vm.prank(arbitrator);
        market.resolve(IMarket.Resolution.No);
        assertEq(uint8(market.finalResolution()), uint8(IMarket.Resolution.No));
    }

    function test_RevertWhen_NonArbitratorResolves() public {
        _close();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotArbitrator.selector, admin));
        market.resolve(IMarket.Resolution.Yes);
    }

    function test_RevertWhen_ResolvingBeforeClose() public {
        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotClosed.selector, IMarket.State.Open));
        market.resolve(IMarket.Resolution.Yes);
    }

    function test_RevertWhen_ResolvingAtOrAfterDeadline() public {
        vm.warp(market.resolutionDeadline());
        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotClosed.selector, IMarket.State.Cancelled));
        market.resolve(IMarket.Resolution.Yes);
    }

    function test_RevertWhen_ResolvingTwice() public {
        _resolve(IMarket.Resolution.Yes);
        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotClosed.selector, IMarket.State.Resolved));
        market.resolve(IMarket.Resolution.No);
    }

    function test_RevertWhen_ResolvingAfterInvalid() public {
        _resolve(IMarket.Resolution.Invalid);
        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotClosed.selector, IMarket.State.Cancelled));
        market.resolve(IMarket.Resolution.Yes);
    }

    function test_RevertWhen_TradingAfterResolution() public {
        _resolve(IMarket.Resolution.Yes);
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IMarket.TradingClosed.selector, IMarket.State.Resolved));
        market.buy(IMarket.Outcome.Yes, 10e6, 0, block.timestamp);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- redeem (E3-2)

    function test_RedeemPaysWinnersOneToOneAndLosersZero() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        uint256 bobNo = _buy(bob, IMarket.Outcome.No, 10e6);
        _resolve(IMarket.Resolution.Yes);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.expectEmit(address(market));
        emit IMarket.Redeemed(alice, aliceYes, 0, aliceYes);
        vm.prank(alice);
        assertEq(market.redeem(aliceYes, 0), aliceYes);
        assertEq(usdc.balanceOf(alice) - aliceBefore, aliceYes);
        assertEq(_yes(alice), 0);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        assertEq(market.redeem(0, bobNo), 0);
        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(_no(bob), 0, "losing tokens are burned too");
    }

    function test_RedeemNoWinner() public {
        uint256 bobNo = _buy(bob, IMarket.Outcome.No, 10e6);
        _resolve(IMarket.Resolution.No);
        vm.prank(bob);
        assertEq(market.redeem(0, bobNo), bobNo);
    }

    function test_RedeemNeedsNoApproval() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        _resolve(IMarket.Resolution.Yes);
        assertFalse(token.isApprovedForAll(alice, address(market)));
        vm.prank(alice);
        market.redeem(aliceYes, 0);
    }

    function test_PreviewRedeemMatchesRedeem() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        _resolve(IMarket.Resolution.Yes);
        uint256 preview = market.previewRedeem(aliceYes, 0);
        vm.prank(alice);
        assertEq(market.redeem(aliceYes, 0), preview);
    }

    function test_RevertWhen_RedeemingTwice() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        _resolve(IMarket.Resolution.Yes);
        vm.startPrank(alice);
        market.redeem(aliceYes, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 0, aliceYes, market.yesTokenId()
            )
        );
        market.redeem(aliceYes, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemingMoreThanBalance() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        _resolve(IMarket.Resolution.Yes);
        uint256 yesId = market.yesTokenId(); // read before vm.prank, which applies to the next call
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, alice, aliceYes, aliceYes + 1, yesId
            )
        );
        market.redeem(aliceYes + 1, 0);
    }

    function test_RevertWhen_RedeemingZero() public {
        _resolve(IMarket.Resolution.Yes);
        vm.prank(alice);
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.redeem(0, 0);
    }

    function test_RevertWhen_RedeemingBeforeFinal() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotFinal.selector, IMarket.State.Open));
        market.redeem(aliceYes, 0);

        vm.warp(market.closeTime());
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotFinal.selector, IMarket.State.Closed));
        market.redeem(aliceYes, 0);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IMarket.NotFinal.selector, IMarket.State.Closed));
        market.finalResolution();
    }

    // ------------------------------------------------------ cancel / refund (E3-3)

    function test_InvalidResolutionCancelsAndRefundsHalf() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        _close();
        vm.expectEmit(address(market));
        emit IMarket.MarketResolved(IMarket.Resolution.Invalid, arbitrator);
        vm.expectEmit(address(market));
        emit IMarket.MarketCancelled();
        vm.prank(arbitrator);
        market.resolve(IMarket.Resolution.Invalid);

        assertEq(uint8(market.state()), uint8(IMarket.State.Cancelled));
        assertEq(uint8(market.finalResolution()), uint8(IMarket.Resolution.Invalid));
        vm.prank(alice);
        assertEq(market.redeem(aliceYes, 0), aliceYes / 2);
    }

    function test_CancelledAutomaticallyAtDeadlineWithoutAnyTransaction() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        vm.warp(market.resolutionDeadline() - 1);
        assertEq(uint8(market.state()), uint8(IMarket.State.Closed));

        vm.warp(market.resolutionDeadline());
        assertEq(uint8(market.state()), uint8(IMarket.State.Cancelled));
        assertEq(uint8(market.finalResolution()), uint8(IMarket.Resolution.Invalid));

        vm.prank(alice);
        assertEq(market.redeem(aliceYes, 0), aliceYes / 2, "redeem works without finalize");
    }

    function test_CancelledRedeemOfAPairReturnsOneEach() public {
        _buy(alice, IMarket.Outcome.Yes, 11e6);
        _buy(alice, IMarket.Outcome.No, 7e6);
        uint256 yesAmount = _yes(alice);
        uint256 noAmount = _no(alice);
        vm.warp(market.resolutionDeadline());
        vm.prank(alice);
        assertEq(market.redeem(yesAmount, noAmount), (yesAmount + noAmount) / 2);
    }

    function test_FinalizeStoresTimeoutCancellation() public {
        vm.warp(market.resolutionDeadline());
        vm.expectEmit(address(market));
        emit IMarket.MarketCancelled();
        market.finalize();
        assertEq(uint8(market.state()), uint8(IMarket.State.Cancelled));

        vm.expectRevert(abi.encodeWithSelector(IMarket.NothingToFinalize.selector, IMarket.State.Cancelled));
        market.finalize();
    }

    function test_RevertWhen_FinalizingBeforeDeadlineOrAfterResolve() public {
        vm.expectRevert(abi.encodeWithSelector(IMarket.NothingToFinalize.selector, IMarket.State.Open));
        market.finalize();

        _close();
        vm.expectRevert(abi.encodeWithSelector(IMarket.NothingToFinalize.selector, IMarket.State.Closed));
        market.finalize();

        vm.prank(arbitrator);
        market.resolve(IMarket.Resolution.Yes);
        vm.warp(market.resolutionDeadline() + 1);
        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved), "a resolved market never times out");
        vm.expectRevert(abi.encodeWithSelector(IMarket.NothingToFinalize.selector, IMarket.State.Resolved));
        market.finalize();
    }

    // ------------------------------------------------------- creator's liquidity

    function test_ClaimLiquidityPaysCreatorThePoolsWinningSide() public {
        _buy(alice, IMarket.Outcome.Yes, 10e6);
        uint256 poolYes = _yes(address(market));
        uint256 poolNo = _no(address(market));
        _resolve(IMarket.Resolution.No);

        uint256 before = usdc.balanceOf(admin);
        vm.expectEmit(address(market));
        emit IMarket.LiquidityClaimed(admin, poolYes, poolNo, poolNo);
        vm.prank(bob); // anyone may trigger it; the creator is always paid
        assertEq(market.claimLiquidity(), poolNo);
        assertEq(usdc.balanceOf(admin) - before, poolNo);
        assertEq(_yes(address(market)) + _no(address(market)), 0);

        vm.expectRevert(IMarket.NothingToClaim.selector);
        market.claimLiquidity();
    }

    function test_ClaimLiquidityIncludesDonatedTokens() public {
        uint256 aliceYes = _buy(alice, IMarket.Outcome.Yes, 10e6);
        uint256 poolYes = _yes(address(market));
        uint256 yesId = market.yesTokenId();
        vm.prank(alice);
        token.safeTransferFrom(alice, address(market), yesId, aliceYes, "");
        _resolve(IMarket.Resolution.Yes);

        assertEq(market.claimLiquidity(), poolYes + aliceYes);
    }

    function test_RevertWhen_ClaimingLiquidityBeforeFinal() public {
        _close();
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotFinal.selector, IMarket.State.Closed));
        market.claimLiquidity();
    }

    function test_WithdrawFeesStillWorksAfterResolution() public {
        _buy(alice, IMarket.Outcome.Yes, 10e6);
        uint256 fees = market.accruedFees();
        _resolve(IMarket.Resolution.Yes);
        market.claimLiquidity();
        assertEq(market.withdrawFees(), fees);
    }

    // ---------------------------------------------------------- full settlement

    /// @dev Worked example from resolution_plan.md §5, then everyone is paid out.
    function test_FullSettlementLeavesNothingBehind() public {
        _buy(alice, IMarket.Outcome.Yes, 10.1e6);
        _resolve(IMarket.Resolution.Yes);

        _redeemAll(alice);
        market.claimLiquidity();
        market.withdrawFees();
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(token.totalSupply(market.yesTokenId()), 0);
        assertEq(token.totalSupply(market.noTokenId()), 0);
    }

    function testFuzz_SettlementNeverPaysMoreThanBacking(uint256 yesBuy, uint256 noBuy, uint8 rawResolution) public {
        yesBuy = bound(yesBuy, 1e6, 500e6);
        noBuy = bound(noBuy, 1e6, 500e6);
        IMarket.Resolution resolution = IMarket.Resolution(bound(rawResolution, 0, 2));

        _buy(alice, IMarket.Outcome.Yes, yesBuy);
        _buy(bob, IMarket.Outcome.No, noBuy);

        // Backing rule: every YES+NO pair is backed by exactly one unit of collateral.
        uint256 yesId = market.yesTokenId();
        assertEq(token.totalSupply(yesId), token.totalSupply(market.noTokenId()));
        assertEq(usdc.balanceOf(address(market)), token.totalSupply(yesId) + market.accruedFees());

        _resolve(resolution);
        _redeemAll(alice);
        _redeemAll(bob);
        market.claimLiquidity();
        market.withdrawFees();

        // Rounding is always in the market's favour: at most a few raw units of dust remain.
        uint256 dust = usdc.balanceOf(address(market));
        if (resolution == IMarket.Resolution.Invalid) assertLe(dust, 2);
        else assertEq(dust, 0);
    }

    // ------------------------------------------------------------- reentrancy

    function test_PayoutTransferCannotReenter() public {
        ReentrantPayoutToken evil = new ReentrantPayoutToken();
        (, Market evilMarket) = _deploy(evil);
        vm.warp(evilMarket.closeTime());
        vm.prank(arbitrator);
        evilMarket.resolve(IMarket.Resolution.Yes);

        evil.setTarget(evilMarket);
        evilMarket.claimLiquidity();

        assertEq(evil.redeemError(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(evil.claimError(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }
}
