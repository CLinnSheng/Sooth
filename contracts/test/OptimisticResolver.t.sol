// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {OptimisticResolver} from "../src/OptimisticResolver.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IOptimisticResolver} from "../src/interfaces/IOptimisticResolver.sol";

contract OptimisticResolverTest is Test {
    uint256 private constant LIQUIDITY = 100e6;
    uint256 private constant TRADE = 10e6;
    uint256 private constant BOND = 10e6;
    uint64 private constant WINDOW = 2 hours;
    string private constant SPEC = "Will Apple announce a foldable iPhone by close?";
    string private constant EVIDENCE = "ipfs://evidence";

    MockUSDC private usdc;
    MarketFactory private factory;
    OptimisticResolver private resolver;
    IMarket private market;
    uint64 private closeTime;
    address private admin = makeAddr("admin");
    address private judge = makeAddr("judge");
    address private proposer = makeAddr("proposer");
    address private disputer = makeAddr("disputer");
    address private alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        factory = new MarketFactory(admin, address(usdc));
        resolver = new OptimisticResolver(judge, factory, BOND, WINDOW);
        market = _createMarket(factory, address(resolver));
        closeTime = market.closeTime();
    }

    function _createMarket(MarketFactory factory_, address arbitrator) private returns (IMarket) {
        vm.startPrank(admin);
        usdc.mint(admin, LIQUIDITY);
        usdc.approve(address(factory_), LIQUIDITY);
        (, address created) = factory_.createMarket(
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

    function _fundBond(address account) private {
        usdc.mint(account, BOND);
        vm.prank(account);
        usdc.approve(address(resolver), BOND);
    }

    function _propose(IMarket.Outcome outcome) private {
        _fundBond(proposer);
        vm.prank(proposer);
        resolver.propose(market, outcome, EVIDENCE);
    }

    function _dispute() private {
        _fundBond(disputer);
        vm.prank(disputer);
        resolver.dispute(market, EVIDENCE);
    }

    function _proposeAndDispute(IMarket.Outcome outcome) private {
        vm.warp(closeTime);
        _propose(outcome);
        _dispute();
    }

    function _assertStatus(IOptimisticResolver.Status expected) private view {
        assertEq(uint8(resolver.requestOf(market).status), uint8(expected));
    }

    function _assertHeldBonds(uint256 count) private view {
        assertEq(usdc.balanceOf(address(resolver)), count * BOND);
    }

    // constructor

    function test_RevertWhen_BondIsZero() public {
        vm.expectRevert(IOptimisticResolver.InvalidConfig.selector);
        new OptimisticResolver(judge, factory, 0, WINDOW);
    }

    function test_RevertWhen_WindowNotShorterThanResolutionWindow() public {
        vm.expectRevert(IOptimisticResolver.InvalidConfig.selector);
        new OptimisticResolver(judge, factory, BOND, 7 days);
    }

    // propose

    function test_ProposePullsBondAndRecordsRequest() public {
        vm.warp(closeTime);
        _fundBond(proposer);
        vm.expectEmit(true, true, false, true, address(resolver));
        emit IOptimisticResolver.Proposed(market, proposer, IMarket.Outcome.No, EVIDENCE);
        vm.prank(proposer);
        resolver.propose(market, IMarket.Outcome.No, EVIDENCE);

        IOptimisticResolver.Request memory request = resolver.requestOf(market);
        assertEq(request.proposer, proposer);
        assertEq(uint8(request.outcome), uint8(IMarket.Outcome.No));
        assertEq(uint8(request.status), uint8(IOptimisticResolver.Status.Proposed));
        assertEq(request.proposedAt, closeTime);
        _assertHeldBonds(1);
    }

    function test_RevertWhen_MarketNotFromFactory() public {
        MarketFactory otherFactory = new MarketFactory(admin, address(usdc));
        IMarket foreign = _createMarket(otherFactory, address(resolver));
        vm.warp(closeTime);
        _fundBond(proposer);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.NotFactoryMarket.selector, foreign));
        resolver.propose(foreign, IMarket.Outcome.Yes, EVIDENCE);
    }

    function test_RevertWhen_MarketUsesOtherArbitrator() public {
        IMarket other = _createMarket(factory, judge);
        vm.warp(closeTime);
        _fundBond(proposer);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.MarketNotUsingResolver.selector, other));
        resolver.propose(other, IMarket.Outcome.Yes, EVIDENCE);
    }

    function test_RevertWhen_ProposingOpenMarket() public {
        _fundBond(proposer);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.MarketNotClosed.selector, IMarket.State.Open));
        resolver.propose(market, IMarket.Outcome.Yes, EVIDENCE);
    }

    function test_RevertWhen_ProposingTwice() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        _fundBond(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.Proposed)
        );
        resolver.propose(market, IMarket.Outcome.No, EVIDENCE);
    }

    function test_RevertWhen_ProposingTooLate() public {
        uint64 deadline = market.resolutionDeadline();
        vm.warp(deadline - WINDOW);
        _fundBond(proposer);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.ProposalTooLate.selector, deadline, deadline));
        resolver.propose(market, IMarket.Outcome.Yes, EVIDENCE);
    }

    function test_RevertWhen_ProposerHasNotApproved() public {
        vm.warp(closeTime);
        usdc.mint(proposer, BOND);
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(resolver), 0, BOND)
        );
        resolver.propose(market, IMarket.Outcome.Yes, EVIDENCE);
    }

    // dispute

    function test_DisputePullsBondAndRecordsDisputer() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        _fundBond(disputer);
        vm.expectEmit(true, true, false, true, address(resolver));
        emit IOptimisticResolver.Disputed(market, disputer, EVIDENCE);
        vm.prank(disputer);
        resolver.dispute(market, EVIDENCE);

        assertEq(resolver.requestOf(market).disputer, disputer);
        _assertStatus(IOptimisticResolver.Status.Disputed);
        _assertHeldBonds(2);
    }

    function test_RevertWhen_DisputingAfterWindow() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        vm.warp(closeTime + WINDOW);
        _fundBond(disputer);
        vm.prank(disputer);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.ChallengeWindowClosed.selector, uint256(closeTime + WINDOW))
        );
        resolver.dispute(market, EVIDENCE);
    }

    function test_RevertWhen_DisputingWithoutProposal() public {
        vm.warp(closeTime);
        _fundBond(disputer);
        vm.prank(disputer);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.None)
        );
        resolver.dispute(market, EVIDENCE);
    }

    function test_RevertWhen_DisputingTwice() public {
        _proposeAndDispute(IMarket.Outcome.Yes);
        _fundBond(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.Disputed)
        );
        resolver.dispute(market, EVIDENCE);
    }

    // finalize

    function test_FinalizeResolvesMarketAndReturnsBond() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.No);
        vm.warp(closeTime + WINDOW);

        vm.expectEmit(true, false, false, true, address(resolver));
        emit IOptimisticResolver.Finalized(market, IMarket.Outcome.No);
        resolver.finalize(market);

        assertEq(uint8(market.state()), uint8(IMarket.State.Resolved));
        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.No));
        assertEq(usdc.balanceOf(proposer), BOND);
        _assertStatus(IOptimisticResolver.Status.Settled);
        _assertHeldBonds(0);
    }

    function test_RevertWhen_FinalizingDuringWindow() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        vm.warp(closeTime + WINDOW - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.ChallengeWindowOpen.selector, uint256(closeTime + WINDOW))
        );
        resolver.finalize(market);
    }

    function test_RevertWhen_FinalizingDisputed() public {
        _proposeAndDispute(IMarket.Outcome.Yes);
        vm.warp(closeTime + WINDOW);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.Disputed)
        );
        resolver.finalize(market);
    }

    function test_RevertWhen_ProposingAfterFinalize() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        vm.warp(closeTime + WINDOW);
        resolver.finalize(market);

        _fundBond(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.MarketNotClosed.selector, IMarket.State.Resolved));
        resolver.propose(market, IMarket.Outcome.No, EVIDENCE);
    }

    // rule

    function test_RuleForProposerPaysProposerBothBonds() public {
        _proposeAndDispute(IMarket.Outcome.Yes);
        vm.expectEmit(true, true, false, true, address(resolver));
        emit IOptimisticResolver.Ruled(market, IMarket.Outcome.Yes, proposer);
        vm.prank(judge);
        resolver.rule(market, IMarket.Outcome.Yes);

        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.Yes));
        assertEq(usdc.balanceOf(proposer), 2 * BOND);
        assertEq(usdc.balanceOf(disputer), 0);
        _assertHeldBonds(0);
    }

    function test_RuleForDisputerPaysDisputerBothBonds() public {
        _proposeAndDispute(IMarket.Outcome.Yes);
        vm.prank(judge);
        resolver.rule(market, IMarket.Outcome.No);

        assertEq(uint8(market.winningOutcome()), uint8(IMarket.Outcome.No));
        assertEq(usdc.balanceOf(disputer), 2 * BOND);
        assertEq(usdc.balanceOf(proposer), 0);
        _assertHeldBonds(0);
    }

    function test_RevertWhen_NonJudgeRules() public {
        _proposeAndDispute(IMarket.Outcome.Yes);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolver.rule(market, IMarket.Outcome.No);
    }

    function test_RevertWhen_RulingUndisputed() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        vm.prank(judge);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.Proposed)
        );
        resolver.rule(market, IMarket.Outcome.No);
    }

    // refund

    function test_RefundAfterCancelReturnsProposerBond() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        vm.warp(market.resolutionDeadline());

        vm.expectEmit(true, false, false, false, address(resolver));
        emit IOptimisticResolver.Refunded(market);
        resolver.refund(market);

        assertEq(usdc.balanceOf(proposer), BOND);
        _assertStatus(IOptimisticResolver.Status.Settled);
        _assertHeldBonds(0);
    }

    function test_RefundAfterCancelReturnsBothBondsWhenDisputed() public {
        _proposeAndDispute(IMarket.Outcome.Yes);
        vm.warp(market.resolutionDeadline());
        resolver.refund(market);

        assertEq(usdc.balanceOf(proposer), BOND);
        assertEq(usdc.balanceOf(disputer), BOND);
        _assertHeldBonds(0);
    }

    function test_RevertWhen_RefundingBeforeCancel() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticResolver.MarketNotCancelled.selector, IMarket.State.Closed));
        resolver.refund(market);
    }

    function test_RevertWhen_RefundingTwice() public {
        vm.warp(closeTime);
        _propose(IMarket.Outcome.Yes);
        vm.warp(market.resolutionDeadline());
        resolver.refund(market);
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.Settled)
        );
        resolver.refund(market);
    }

    function test_RevertWhen_RefundingWithoutRequest() public {
        vm.warp(market.resolutionDeadline());
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticResolver.WrongStatus.selector, IOptimisticResolver.Status.None)
        );
        resolver.refund(market);
    }

    // judge handover

    function test_JudgeHandoverNeedsAcceptance() public {
        address multisig = makeAddr("multisig");
        vm.prank(judge);
        resolver.transferOwnership(multisig);
        assertEq(resolver.owner(), judge);

        vm.prank(multisig);
        resolver.acceptOwnership();
        assertEq(resolver.owner(), multisig);
    }

    // end to end

    function test_WinnerRedeemsAfterUndisputedProposal() public {
        usdc.mint(alice, TRADE);
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE);
        uint256 shares = market.buy(IMarket.Outcome.No, TRADE, 1, block.timestamp);
        vm.stopPrank();

        vm.warp(closeTime);
        _propose(IMarket.Outcome.No);
        vm.warp(closeTime + WINDOW);
        resolver.finalize(market);

        vm.prank(alice);
        assertEq(market.redeem(), shares);
    }
}
