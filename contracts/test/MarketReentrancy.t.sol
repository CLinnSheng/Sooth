// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IOutcomeToken} from "../src/interfaces/IOutcomeToken.sol";

interface ITransferHook {
    function onCollateralReceived() external;
}

/// @dev Collateral that calls the recipient after each `transfer`, like an ERC-777 receive hook.
///      Only the registered hook address is called, so ordinary accounts see a plain token.
contract HookToken is MockUSDC {
    address public hook;

    function setHook(address hook_) external {
        hook = hook_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (to == hook) ITransferHook(to).onCollateralReceived();
        return success;
    }
}

/// @dev Trades, redeems and withdraws, and on receiving collateral tries one armed re-entrant call.
contract ReentrantActor is ERC1155Holder, ITransferHook {
    enum Action {
        None,
        Sell,
        Redeem,
        WithdrawLiquidity
    }

    HookToken public immutable collateral;
    IOutcomeToken public immutable outcomeToken;
    Market public market;

    Action public armed;
    uint256 public reentrySellAmount;
    uint256 public reentryAttempts;
    bool public reentrySucceeded;
    bytes4 public reentryError;

    constructor(HookToken collateral_, IOutcomeToken outcomeToken_) {
        collateral = collateral_;
        outcomeToken = outcomeToken_;
    }

    function setMarket(Market market_) external {
        market = market_;
        collateral.approve(address(market_), type(uint256).max);
        outcomeToken.setApprovalForAll(address(market_), true);
    }

    function createMarket(MarketFactory factory, IMarketFactory.CreateParams calldata p) external returns (Market) {
        collateral.approve(address(factory), p.initialLiquidity);
        (, address created) = factory.createMarket(p);
        return Market(created);
    }

    function arm(Action action, uint256 sellAmount) external {
        armed = action;
        reentrySellAmount = sellAmount;
    }

    function buy(IMarket.Outcome outcome, uint256 amount) external returns (uint256) {
        return market.buy(outcome, amount, 1, block.timestamp);
    }

    function sell(IMarket.Outcome outcome, uint256 shares) external returns (uint256) {
        return market.sell(outcome, shares, 1, block.timestamp);
    }

    function redeem() external returns (uint256) {
        return market.redeem();
    }

    function withdrawLiquidity() external returns (uint256) {
        return market.withdrawLiquidity();
    }

    function onCollateralReceived() external {
        Action action = armed;
        if (action == Action.None) return;
        // Disarm first so a successful re-entry cannot recurse.
        armed = Action.None;
        reentryAttempts++;
        try this.reenter(action) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            // forge-lint: disable-next-line(unsafe-typecast)
            reentryError = bytes4(reason);
        }
    }

    /// @dev External so the try/catch above can catch the market's revert. The market sees this
    ///      contract as the caller, the same account as the outer call.
    function reenter(Action action) external {
        require(msg.sender == address(this), "only self");
        if (action == Action.Sell) market.sell(IMarket.Outcome.Yes, reentrySellAmount, 1, block.timestamp);
        else if (action == Action.Redeem) market.redeem();
        else market.withdrawLiquidity();
    }
}

/// @notice INV-COL-8 for `sell`, `redeem` and `withdrawLiquidity`: a collateral receive hook cannot
///         re-enter the market while one of these calls is paying out.
contract MarketReentrancyTest is Test {
    uint256 private constant LIQUIDITY = 100e6;
    uint256 private constant TRADE = 10e6;
    uint256 private constant TRADE_FEE = 0.1e6; // 1% of TRADE
    string private constant SPEC = "market rules";

    HookToken private usdc;
    MarketFactory private factory;
    IOutcomeToken private token;
    ReentrantActor private actor;
    address private admin = makeAddr("admin");
    address private alice = makeAddr("alice");
    address private arbitrator = makeAddr("arbitrator");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new HookToken();
        factory = new MarketFactory(admin, address(usdc));
        token = factory.outcomeToken();
        actor = new ReentrantActor(usdc, token);
        usdc.setHook(address(actor));
    }

    function _params() private view returns (IMarketFactory.CreateParams memory) {
        return IMarketFactory.CreateParams({
            arbitrator: arbitrator,
            closeTime: uint64(block.timestamp + 7 days),
            initialYesProbabilityBps: 5_000,
            spec: SPEC,
            initialLiquidity: LIQUIDITY
        });
    }

    /// @dev Market created by `admin`; the actor only trades.
    function _adminMarket() private returns (Market market) {
        usdc.mint(admin, LIQUIDITY);
        vm.startPrank(admin);
        usdc.approve(address(factory), LIQUIDITY);
        (, address created) = factory.createMarket(_params());
        vm.stopPrank();
        market = Market(created);
        actor.setMarket(market);
    }

    /// @dev Market created by the actor, so `withdrawLiquidity` pays the actor and fires its hook.
    function _actorMarket() private returns (Market market) {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        factory.grantRole(adminRole, address(actor));
        usdc.mint(address(actor), LIQUIDITY);
        market = actor.createMarket(factory, _params());
        actor.setMarket(market);
    }

    function _actorBuysYes(uint256 amount) private returns (uint256 shares) {
        usdc.mint(address(actor), amount);
        shares = actor.buy(IMarket.Outcome.Yes, amount);
    }

    function _resolve(Market market, IMarket.Outcome outcome) private {
        vm.warp(market.closeTime());
        vm.prank(arbitrator);
        market.resolve(outcome);
    }

    function _assertReentryBlocked() private view {
        assertEq(actor.reentryAttempts(), 1);
        assertFalse(actor.reentrySucceeded());
        assertEq(actor.reentryError(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    function test_SellCollateralCallbackCannotReenterSell() public {
        Market market = _adminMarket();
        uint256 shares = _actorBuysYes(TRADE);
        uint256 toSell = shares / 2;
        uint256 yesId = market.yesTokenId();
        (uint256 quoted, uint256 fee) = market.quoteSell(IMarket.Outcome.Yes, toSell);
        uint256 marketBefore = usdc.balanceOf(address(market));
        uint256 supplyBefore = token.totalSupply(yesId);

        actor.arm(ReentrantActor.Action.Sell, shares - toSell);
        uint256 received = actor.sell(IMarket.Outcome.Yes, toSell);

        _assertReentryBlocked();
        // Exactly one sell took effect.
        assertEq(received, quoted);
        assertEq(usdc.balanceOf(address(actor)), quoted);
        assertEq(usdc.balanceOf(address(market)), marketBefore - quoted);
        assertEq(token.balanceOf(address(actor), yesId), shares - toSell);
        assertEq(token.totalSupply(yesId), supplyBefore - (quoted + fee));
        assertEq(market.accruedFees(), TRADE_FEE + fee);
        assertEq(token.balanceOf(address(market), yesId), market.yesPool());
        assertEq(token.balanceOf(address(market), market.noTokenId()), market.noPool());
        uint256 backing = usdc.balanceOf(address(market)) - market.accruedFees();
        assertEq(token.totalSupply(yesId), backing);
        assertEq(token.totalSupply(market.noTokenId()), backing);
    }

    function test_RedeemPayoutCallbackCannotReenterRedeem() public {
        Market market = _adminMarket();
        uint256 shares = _actorBuysYes(TRADE);
        _resolve(market, IMarket.Outcome.Yes);
        uint256 yesId = market.yesTokenId();
        uint256 marketBefore = usdc.balanceOf(address(market));

        actor.arm(ReentrantActor.Action.Redeem, 0);
        uint256 payout = actor.redeem();

        _assertReentryBlocked();
        assertEq(payout, shares);
        assertEq(usdc.balanceOf(address(actor)), shares);
        assertEq(usdc.balanceOf(address(market)), marketBefore - shares);
        assertEq(token.balanceOf(address(actor), yesId), 0);
    }

    function test_WithdrawLiquidityCallbackCannotReenterWithdrawal() public {
        Market market = _actorMarket();
        usdc.mint(alice, TRADE);
        vm.startPrank(alice);
        usdc.approve(address(market), TRADE);
        uint256 aliceShares = market.buy(IMarket.Outcome.Yes, TRADE, 1, block.timestamp);
        vm.stopPrank();
        _resolve(market, IMarket.Outcome.Yes);
        uint256 expected = market.yesPool();
        uint256 marketBefore = usdc.balanceOf(address(market));

        actor.arm(ReentrantActor.Action.WithdrawLiquidity, 0);
        uint256 amount = actor.withdrawLiquidity();

        _assertReentryBlocked();
        assertEq(amount, expected);
        assertEq(usdc.balanceOf(address(actor)), expected);
        assertEq(usdc.balanceOf(address(market)), marketBefore - expected);
        assertTrue(market.liquidityWithdrawn());
        // The other holder's claim is intact.
        vm.prank(alice);
        assertEq(market.redeem(), aliceShares);
    }

    function test_WithdrawLiquidityCallbackCannotReenterRedeem() public {
        Market market = _actorMarket();
        uint256 shares = _actorBuysYes(TRADE);
        _resolve(market, IMarket.Outcome.Yes);
        uint256 yesId = market.yesTokenId();
        uint256 pool = market.yesPool();
        uint256 marketBefore = usdc.balanceOf(address(market));

        actor.arm(ReentrantActor.Action.Redeem, 0);
        uint256 amount = actor.withdrawLiquidity();

        _assertReentryBlocked();
        assertEq(amount, pool);
        assertEq(usdc.balanceOf(address(actor)), pool);
        assertEq(usdc.balanceOf(address(market)), marketBefore - pool);
        // The blocked redeem burned nothing; a later redeem pays the shares once.
        assertEq(token.balanceOf(address(actor), yesId), shares);
        assertEq(actor.redeem(), shares);
        assertEq(usdc.balanceOf(address(actor)), pool + shares);
        assertEq(usdc.balanceOf(address(market)), marketBefore - pool - shares);
    }
}
