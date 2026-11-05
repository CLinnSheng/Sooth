// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {OutcomeOrderBook} from "../src/OutcomeOrderBook.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IOutcomeToken} from "../src/interfaces/IOutcomeToken.sol";
import {IOutcomeOrderBook} from "../src/interfaces/IOutcomeOrderBook.sol";

/// @dev Claims an id the factory knows, but is not the market stored under it.
contract FakeMarket {
    function marketId() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Buyer that, when the order book sends it shares, tries one armed re-entrant call and records the result.
contract ReentrantBuyer is ERC1155Holder {
    enum Action {
        None,
        Buy,
        Cancel,
        List
    }

    OutcomeOrderBook public immutable book;
    IMarket public immutable market;

    Action public armed;
    uint256 public cancelId;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor(OutcomeOrderBook book_, IMarket market_) {
        book = book_;
        market = market_;
        market_.collateral().approve(address(book_), type(uint256).max);
        market_.collateral().approve(address(market_), type(uint256).max);
        book_.outcomeToken().setApprovalForAll(address(book_), true);
    }

    function arm(Action action, uint256 cancelId_) external {
        armed = action;
        cancelId = cancelId_;
    }

    function ammBuy(uint256 collateralIn) external returns (uint256) {
        return market.buy(IMarket.Outcome.Yes, collateralIn, 1, block.timestamp);
    }

    function list(uint256 amount, uint256 price) external returns (uint256) {
        return book.list(market, IMarket.Outcome.Yes, amount, price);
    }

    function buy(uint256 shares, uint256 maxPrice) external returns (uint256, uint256) {
        return book.buy(market, IMarket.Outcome.Yes, shares, maxPrice, 10);
    }

    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes memory data)
        public
        override
        returns (bytes4)
    {
        if (from == address(book) && armed != Action.None) {
            Action action = armed;
            armed = Action.None;
            bytes memory call;
            if (action == Action.Buy) {
                call = abi.encodeCall(book.buy, (market, IMarket.Outcome.Yes, 1e6, 500_000, 10));
            } else if (action == Action.Cancel) {
                call = abi.encodeCall(book.cancel, (cancelId));
            } else {
                call = abi.encodeCall(book.list, (market, IMarket.Outcome.Yes, 1e6, 500_000));
            }
            reentryAttempted = true;
            (reentrySucceeded, reentryError) = address(book).call(call);
        }
        return super.onERC1155Received(operator, from, id, value, data);
    }
}

contract OutcomeOrderBookTest is Test {
    uint256 private constant LIQUIDITY = 1_000e6;
    uint256 private constant SCALE = 1e6;
    string private constant SPEC = "Will ETH close above $4,000 on 30 Nov?";

    MockUSDC private usdc;
    MarketFactory private factory;
    OutcomeOrderBook private book;
    IOutcomeToken private token;
    IMarket private market;
    uint256 private yesId;
    uint256 private noId;
    uint64 private closeTime;

    address private admin = makeAddr("admin");
    address private arbiter = makeAddr("arbiter");
    address private alice = makeAddr("alice");
    address private carol = makeAddr("carol");
    address private dave = makeAddr("dave");
    address private bob = makeAddr("bob");
    address private erin = makeAddr("erin");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        factory = new MarketFactory(admin, address(usdc));
        book = new OutcomeOrderBook(factory);
        token = factory.outcomeToken();
        market = _createMarket(factory);
        yesId = market.yesTokenId();
        noId = market.noTokenId();
        closeTime = market.closeTime();

        _fundBuyer(bob, 1_000e6);
        _fundBuyer(erin, 1_000e6);
    }

    // helpers

    function _createMarket(MarketFactory factory_) private returns (IMarket) {
        vm.startPrank(admin);
        usdc.mint(admin, LIQUIDITY);
        usdc.approve(address(factory_), LIQUIDITY);
        (, address created) = factory_.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: arbiter,
                closeTime: uint64(block.timestamp + 7 days),
                initialYesProbabilityBps: 5_000,
                spec: SPEC,
                initialLiquidity: LIQUIDITY
            })
        );
        vm.stopPrank();
        return IMarket(created);
    }

    /// @dev Buys shares from the AMM and approves the order book to escrow them.
    function _giveShares(address account, IMarket.Outcome outcome, uint256 collateralIn) private returns (uint256) {
        usdc.mint(account, collateralIn);
        vm.startPrank(account);
        usdc.approve(address(market), collateralIn);
        uint256 shares = market.buy(outcome, collateralIn, 1, block.timestamp);
        token.setApprovalForAll(address(book), true);
        vm.stopPrank();
        return shares;
    }

    function _fundBuyer(address account, uint256 amount) private {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(book), type(uint256).max);
    }

    function _list(address seller, IMarket.Outcome outcome, uint256 amount, uint256 price) private returns (uint256) {
        // Below 1:1 odds the AMM gives more shares than collateral in; 1 USDC minimum covers tiny amounts.
        if (token.balanceOf(seller, _id(outcome)) < amount) _giveShares(seller, outcome, amount < 1e6 ? 1e6 : amount);
        vm.prank(seller);
        return book.list(market, outcome, amount, price);
    }

    function _buy(address buyer, IMarket.Outcome outcome, uint256 shares, uint256 maxPrice, uint256 maxListings)
        private
        returns (uint256, uint256)
    {
        vm.prank(buyer);
        return book.buy(market, outcome, shares, maxPrice, maxListings);
    }

    function _id(IMarket.Outcome outcome) private view returns (uint256) {
        return outcome == IMarket.Outcome.Yes ? yesId : noId;
    }

    /// @dev Independent of the contract: integer ceil of amount * price / 1e6.
    function _ceilCost(uint256 amount, uint256 price) private pure returns (uint256) {
        return (amount * price + SCALE - 1) / SCALE;
    }

    function _ids(IMarket.Outcome outcome) private view returns (uint256[] memory) {
        return book.listingsOf(market, outcome, 0, type(uint256).max);
    }

    function _assertIds(IMarket.Outcome outcome, uint256[] memory expected) private view {
        uint256[] memory actual = _ids(outcome);
        assertEq(actual.length, expected.length, "book length");
        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i], expected[i], "book order");
        }
    }

    function _three(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
    }

    function _two(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _one(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    // constructor

    function test_ConstructorWiresFactoryAndToken() public view {
        assertEq(address(book.factory()), address(factory));
        assertEq(address(book.outcomeToken()), address(token));
        assertEq(book.PRICE_SCALE(), SCALE);
        assertEq(book.listingCount(), 0);
        assertEq(book.bestPrice(market, IMarket.Outcome.Yes), 0);
    }

    // OB-1 list

    function test_List_EscrowsSharesAndStoresListing() public {
        uint256 shares = _giveShares(alice, IMarket.Outcome.Yes, 20e6);

        vm.expectEmit(true, true, true, true, address(book));
        emit IOutcomeOrderBook.Listed(1, market, alice, IMarket.Outcome.Yes, 10e6, 600_000);
        vm.prank(alice);
        uint256 id = book.list(market, IMarket.Outcome.Yes, 10e6, 600_000);

        assertEq(id, 1);
        assertEq(book.listingCount(), 1);
        assertEq(token.balanceOf(alice, yesId), shares - 10e6);
        assertEq(token.balanceOf(address(book), yesId), 10e6);
        IOutcomeOrderBook.Listing memory listing = book.getListing(id);
        assertEq(listing.seller, alice);
        assertEq(address(listing.market), address(market));
        assertEq(uint8(listing.outcome), uint8(IMarket.Outcome.Yes));
        assertEq(listing.price, 600_000);
        assertEq(listing.remaining, 10e6);
        assertEq(listing.prev, 0);
        assertEq(listing.next, 0);
        assertEq(book.bestPrice(market, IMarket.Outcome.Yes), 600_000);
        _assertIds(IMarket.Outcome.Yes, _one(1));
        assertEq(_ids(IMarket.Outcome.No).length, 0, "other book untouched");
    }

    // OB-2 buy exactly one listing

    function test_Buy_ExactlyOneListing() public {
        uint256 id = _list(alice, IMarket.Outcome.Yes, 10e6, 600_000);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.expectEmit(true, true, true, true, address(book));
        emit IOutcomeOrderBook.Filled(id, market, bob, alice, IMarket.Outcome.Yes, 10e6, 6e6);
        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, 10e6, 600_000, 1);

        assertEq(bought, 10e6);
        assertEq(cost, 6e6);
        assertEq(usdc.balanceOf(alice), aliceBefore + 6e6);
        assertEq(usdc.balanceOf(bob), bobBefore - 6e6);
        assertEq(usdc.balanceOf(address(book)), 0);
        assertEq(token.balanceOf(bob, yesId), 10e6);
        assertEq(token.balanceOf(address(book), yesId), 0);
        assertEq(book.getListing(id).remaining, 0);
        assertEq(book.bestPrice(market, IMarket.Outcome.Yes), 0);
        assertEq(_ids(IMarket.Outcome.Yes).length, 0);
    }

    function test_Buy_RoundsCostUpSoNoFillIsFree() public {
        uint256 id = _list(alice, IMarket.Outcome.Yes, 3, 333_333);
        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, 3, 333_333, 1);
        assertEq(bought, 3);
        assertEq(cost, 1, "ceil(0.999999)");

        _list(alice, IMarket.Outcome.Yes, 1, 1);
        (bought, cost) = _buy(bob, IMarket.Outcome.Yes, 1, 1, 1);
        assertEq(bought, 1);
        assertEq(cost, 1, "1 raw share at the lowest price still costs 1 unit");
        assertEq(book.getListing(id).remaining, 0);
    }

    // OB-3 partial fill

    function test_Buy_PartialFillKeepsRestInPlace() public {
        uint256 first = _list(alice, IMarket.Outcome.Yes, 10e6, 550_001);
        uint256 second = _list(carol, IMarket.Outcome.Yes, 10e6, 600_000);
        uint256 aliceBefore = usdc.balanceOf(alice);

        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, 3_333_333, 999_999, 5);

        // 3_333_333 * 550_001 / 1e6 = 1_833_336.483333, rounded up.
        assertEq(bought, 3_333_333);
        assertEq(cost, 1_833_337);
        assertEq(usdc.balanceOf(alice), aliceBefore + 1_833_337);
        assertEq(book.getListing(first).remaining, 6_666_667);
        assertEq(book.getListing(first).price, 550_001);
        assertEq(token.balanceOf(address(book), yesId), 6_666_667 + 10e6);
        _assertIds(IMarket.Outcome.Yes, _two(first, second));
        assertEq(book.getListing(second).remaining, 10e6, "second untouched");
    }

    // OB-4 price priority

    function test_Buy_FillsCheapestFirst() public {
        uint256 at60 = _list(alice, IMarket.Outcome.Yes, 10e6, 600_000);
        uint256 at40 = _list(carol, IMarket.Outcome.Yes, 10e6, 400_000);
        uint256 at50 = _list(dave, IMarket.Outcome.Yes, 10e6, 500_000);
        _assertIds(IMarket.Outcome.Yes, _three(at40, at50, at60));
        assertEq(book.bestPrice(market, IMarket.Outcome.Yes), 400_000);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 carolBefore = usdc.balanceOf(carol);
        uint256 daveBefore = usdc.balanceOf(dave);

        vm.expectEmit(true, true, true, true, address(book));
        emit IOutcomeOrderBook.Filled(at40, market, bob, carol, IMarket.Outcome.Yes, 10e6, 4e6);
        vm.expectEmit(true, true, true, true, address(book));
        emit IOutcomeOrderBook.Filled(at50, market, bob, dave, IMarket.Outcome.Yes, 10e6, 5e6);
        vm.expectEmit(true, true, true, true, address(book));
        emit IOutcomeOrderBook.Filled(at60, market, bob, alice, IMarket.Outcome.Yes, 5e6, 3e6);
        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, 25e6, 999_999, 10);

        assertEq(bought, 25e6);
        assertEq(cost, 12e6);
        assertEq(usdc.balanceOf(carol), carolBefore + 4e6);
        assertEq(usdc.balanceOf(dave), daveBefore + 5e6);
        assertEq(usdc.balanceOf(alice), aliceBefore + 3e6);
        _assertIds(IMarket.Outcome.Yes, _one(at60));
        assertEq(book.getListing(at60).remaining, 5e6);
    }

    // OB-5 time priority

    function test_Buy_OldestFirstAtEqualPrice() public {
        uint256 a = _list(alice, IMarket.Outcome.Yes, 10e6, 500_000);
        uint256 b = _list(dave, IMarket.Outcome.Yes, 10e6, 600_000);
        // Same price as `a` but newer, and not the most expensive: exercises the walk, not the tail shortcut.
        uint256 c = _list(carol, IMarket.Outcome.Yes, 10e6, 500_000);
        _assertIds(IMarket.Outcome.Yes, _three(a, c, b));

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 carolBefore = usdc.balanceOf(carol);
        _buy(bob, IMarket.Outcome.Yes, 10e6, 500_000, 10);
        assertEq(usdc.balanceOf(alice), aliceBefore + 5e6, "older filled");
        assertEq(usdc.balanceOf(carol), carolBefore, "newer waits");

        _buy(bob, IMarket.Outcome.Yes, 4e6, 500_000, 10);
        assertEq(usdc.balanceOf(carol), carolBefore + 2e6);
        _assertIds(IMarket.Outcome.Yes, _two(c, b));
    }

    function test_List_EqualPriceAtTailGoesLast() public {
        uint256 a = _list(alice, IMarket.Outcome.Yes, 1e6, 500_000);
        uint256 b = _list(carol, IMarket.Outcome.Yes, 1e6, 500_000);
        uint256 c = _list(dave, IMarket.Outcome.Yes, 1e6, 400_000);
        _assertIds(IMarket.Outcome.Yes, _three(c, a, b));
        assertEq(book.getListing(a).prev, c);
        assertEq(book.getListing(a).next, b);
        assertEq(book.getListing(b).prev, a);
    }

    // OB-6 maxPrice

    function test_Buy_StopsAboveMaxPrice() public {
        uint256 cheap = _list(alice, IMarket.Outcome.Yes, 10e6, 500_000);
        uint256 dear = _list(carol, IMarket.Outcome.Yes, 10e6, 700_000);

        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, 20e6, 699_999, 10);

        assertEq(bought, 10e6);
        assertEq(cost, 5e6);
        assertEq(book.getListing(cheap).remaining, 0);
        assertEq(book.getListing(dear).remaining, 10e6);
        _assertIds(IMarket.Outcome.Yes, _one(dear));
    }

    function test_RevertWhen_NothingAtOrBelowMaxPrice() public {
        _list(alice, IMarket.Outcome.Yes, 10e6, 700_000);
        vm.expectRevert(IOutcomeOrderBook.NothingFilled.selector);
        _buy(bob, IMarket.Outcome.Yes, 1e6, 699_999, 10);
    }

    function test_RevertWhen_BookEmpty() public {
        _list(alice, IMarket.Outcome.No, 10e6, 300_000);
        vm.expectRevert(IOutcomeOrderBook.NothingFilled.selector);
        _buy(bob, IMarket.Outcome.Yes, 1e6, 999_999, 10);
    }

    // OB-7 maxListings

    function test_Buy_StopsAtMaxListings() public {
        uint256 a = _list(alice, IMarket.Outcome.Yes, 10e6, 500_000);
        uint256 b = _list(carol, IMarket.Outcome.Yes, 10e6, 500_000);
        uint256 c = _list(dave, IMarket.Outcome.Yes, 10e6, 500_000);

        (uint256 quoted, uint256 quotedCost) = book.quoteBuy(market, IMarket.Outcome.Yes, 30e6, 500_000, 2);
        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, 30e6, 500_000, 2);

        assertEq(bought, 20e6);
        assertEq(cost, 10e6);
        assertEq(quoted, bought);
        assertEq(quotedCost, cost);
        assertEq(book.getListing(a).remaining, 0);
        assertEq(book.getListing(b).remaining, 0);
        assertEq(book.getListing(c).remaining, 10e6);
        _assertIds(IMarket.Outcome.Yes, _one(c));
    }

    function test_Buy_PartialLastListingCountsAsTouched() public {
        _list(alice, IMarket.Outcome.Yes, 10e6, 500_000);
        uint256 b = _list(carol, IMarket.Outcome.Yes, 10e6, 500_000);
        (uint256 bought,) = _buy(bob, IMarket.Outcome.Yes, 5e6, 500_000, 1);
        assertEq(bought, 5e6);
        assertEq(book.getListing(b).remaining, 10e6);
    }

    // OB-8 sweep across many listings

    function test_Buy_SweepPaysEverySellerExactly() public {
        address[] memory sellers = new address[](10);
        uint256[] memory amounts = new uint256[](10);
        uint256[] memory prices = new uint256[](10);
        uint256[] memory before = new uint256[](10);
        uint256 expectedShares;
        uint256 expectedCost;
        for (uint256 i; i < 10; ++i) {
            sellers[i] = makeAddr(string.concat("seller", vm.toString(i)));
            amounts[i] = 1e6 + i * 123_457;
            prices[i] = 100_000 * (i % 9 + 1) + i * 7;
            _list(sellers[i], IMarket.Outcome.Yes, amounts[i], prices[i]);
            before[i] = usdc.balanceOf(sellers[i]);
            expectedShares += amounts[i];
            expectedCost += _ceilCost(amounts[i], prices[i]);
        }

        (uint256 quoted, uint256 quotedCost) =
            book.quoteBuy(market, IMarket.Outcome.Yes, type(uint128).max, 999_999, 10);
        uint256 bobBefore = usdc.balanceOf(bob);
        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, type(uint128).max, 999_999, 10);

        assertEq(bought, expectedShares);
        assertEq(cost, expectedCost);
        assertEq(quoted, bought);
        assertEq(quotedCost, cost);
        assertEq(usdc.balanceOf(bob), bobBefore - expectedCost);
        assertEq(token.balanceOf(bob, yesId), expectedShares);
        for (uint256 i; i < 10; ++i) {
            assertEq(usdc.balanceOf(sellers[i]), before[i] + _ceilCost(amounts[i], prices[i]), "seller paid");
        }
        assertEq(_ids(IMarket.Outcome.Yes).length, 0);
        assertEq(token.balanceOf(address(book), yesId), 0);
    }

    /// @dev Gas of `buy` sweeping 1 versus 10 listings, logged for the report (each seller is a fresh address).
    function test_Gas_BuyOneVersusTenListings() public {
        for (uint256 i; i < 10; ++i) {
            _list(makeAddr(string.concat("y", vm.toString(i))), IMarket.Outcome.Yes, 1e6, 500_000);
        }
        _list(makeAddr("n0"), IMarket.Outcome.No, 1e6, 500_000);

        vm.prank(bob);
        uint256 start = gasleft();
        book.buy(market, IMarket.Outcome.No, 1e6, 500_000, 10);
        uint256 gasOne = start - gasleft();

        vm.prank(bob);
        start = gasleft();
        book.buy(market, IMarket.Outcome.Yes, 10e6, 500_000, 10);
        uint256 gasTen = start - gasleft();

        emit log_named_uint("buy gas, 1 listing ", gasOne);
        emit log_named_uint("buy gas, 10 listings", gasTen);
        assertGt(gasTen, gasOne);
    }

    // OB-9 cancel

    function test_Cancel_MiddleReturnsSharesAndRelinks() public {
        uint256 a = _list(alice, IMarket.Outcome.Yes, 1e6, 400_000);
        uint256 b = _list(alice, IMarket.Outcome.Yes, 2e6, 500_000);
        uint256 c = _list(alice, IMarket.Outcome.Yes, 3e6, 600_000);
        uint256 aliceShares = token.balanceOf(alice, yesId);

        vm.expectEmit(true, true, true, true, address(book));
        emit IOutcomeOrderBook.Cancelled(b, market, alice, 2e6);
        vm.prank(alice);
        uint256 returned = book.cancel(b);

        assertEq(returned, 2e6);
        assertEq(token.balanceOf(alice, yesId), aliceShares + 2e6);
        assertEq(token.balanceOf(address(book), yesId), 4e6);
        IOutcomeOrderBook.Listing memory cancelled = book.getListing(b);
        assertEq(cancelled.remaining, 0);
        assertEq(cancelled.prev, 0);
        assertEq(cancelled.next, 0);
        _assertIds(IMarket.Outcome.Yes, _two(a, c));
        assertEq(book.getListing(a).next, c);
        assertEq(book.getListing(c).prev, a);
    }

    function test_Cancel_HeadThenTailEmptiesBook() public {
        uint256 a = _list(alice, IMarket.Outcome.Yes, 1e6, 400_000);
        uint256 b = _list(alice, IMarket.Outcome.Yes, 1e6, 500_000);
        uint256 c = _list(alice, IMarket.Outcome.Yes, 1e6, 600_000);

        vm.prank(alice);
        book.cancel(a);
        _assertIds(IMarket.Outcome.Yes, _two(b, c));
        assertEq(book.bestPrice(market, IMarket.Outcome.Yes), 500_000);
        assertEq(book.getListing(b).prev, 0);

        vm.prank(alice);
        book.cancel(c);
        _assertIds(IMarket.Outcome.Yes, _one(b));
        assertEq(book.getListing(b).next, 0);

        vm.prank(alice);
        book.cancel(b);
        assertEq(_ids(IMarket.Outcome.Yes).length, 0);
        assertEq(book.bestPrice(market, IMarket.Outcome.Yes), 0);
        assertEq(token.balanceOf(address(book), yesId), 0);

        // An emptied book accepts new listings again: head and tail were reset.
        uint256 d = _list(carol, IMarket.Outcome.Yes, 1e6, 700_000);
        uint256 e = _list(carol, IMarket.Outcome.Yes, 1e6, 300_000);
        _assertIds(IMarket.Outcome.Yes, _two(e, d));
    }

    function test_RevertWhen_CancelByNonSeller() public {
        uint256 id = _list(alice, IMarket.Outcome.Yes, 1e6, 400_000);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.NotSeller.selector, bob));
        vm.prank(bob);
        book.cancel(id);
    }

    function test_RevertWhen_CancelTwice() public {
        uint256 id = _list(alice, IMarket.Outcome.Yes, 1e6, 400_000);
        vm.prank(alice);
        book.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.ListingNotFound.selector, id));
        vm.prank(alice);
        book.cancel(id);
    }

    function test_RevertWhen_CancelUnknownOrFilled() public {
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.ListingNotFound.selector, 0));
        vm.prank(alice);
        book.cancel(0);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.ListingNotFound.selector, 99));
        vm.prank(alice);
        book.cancel(99);

        uint256 id = _list(alice, IMarket.Outcome.Yes, 1e6, 400_000);
        _buy(bob, IMarket.Outcome.Yes, 1e6, 400_000, 1);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.ListingNotFound.selector, id));
        vm.prank(alice);
        book.cancel(id);
    }

    // OB-10 input limits

    function test_RevertWhen_ListPriceOutOfRange() public {
        _giveShares(alice, IMarket.Outcome.Yes, 10e6);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.InvalidPrice.selector, 0));
        book.list(market, IMarket.Outcome.Yes, 1e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.InvalidPrice.selector, SCALE));
        book.list(market, IMarket.Outcome.Yes, 1e6, SCALE);
        vm.expectRevert(IOutcomeOrderBook.ZeroAmount.selector);
        book.list(market, IMarket.Outcome.Yes, 0, 500_000);

        // Boundaries just inside the range are accepted.
        book.list(market, IMarket.Outcome.Yes, 1e6, 1);
        book.list(market, IMarket.Outcome.Yes, 1e6, SCALE - 1);
        vm.stopPrank();
        assertEq(book.listingCount(), 2);
    }

    function test_RevertWhen_BuyZeroSharesOrZeroListings() public {
        _list(alice, IMarket.Outcome.Yes, 1e6, 500_000);
        vm.expectRevert(IOutcomeOrderBook.ZeroAmount.selector);
        _buy(bob, IMarket.Outcome.Yes, 0, 500_000, 10);
        vm.expectRevert(IOutcomeOrderBook.ZeroAmount.selector);
        _buy(bob, IMarket.Outcome.Yes, 1e6, 500_000, 0);
        vm.expectRevert(IOutcomeOrderBook.ZeroAmount.selector);
        book.quoteBuy(market, IMarket.Outcome.Yes, 0, 500_000, 10);
        vm.expectRevert(IOutcomeOrderBook.ZeroAmount.selector);
        book.quoteBuy(market, IMarket.Outcome.Yes, 1e6, 500_000, 0);
    }

    // OB-11 trading window

    function test_ListAndBuyWorkOneSecondBeforeClose() public {
        vm.warp(closeTime - 1);
        _list(alice, IMarket.Outcome.Yes, 1e6, 500_000);
        (uint256 bought,) = _buy(bob, IMarket.Outcome.Yes, 1e6, 500_000, 1);
        assertEq(bought, 1e6);
    }

    function test_RevertWhen_TradingAtClose_CancelStillWorks() public {
        uint256 id = _list(alice, IMarket.Outcome.Yes, 2e6, 500_000);
        vm.warp(closeTime);
        _assertClosedForTrading(IMarket.State.Closed, id);
    }

    function test_RevertWhen_TradingAfterResolve_CancelStillWorks() public {
        uint256 id = _list(alice, IMarket.Outcome.Yes, 2e6, 500_000);
        vm.warp(closeTime);
        vm.prank(arbiter);
        market.resolve(IMarket.Outcome.Yes);
        _assertClosedForTrading(IMarket.State.Resolved, id);
    }

    function test_RevertWhen_TradingAtCancelDeadline_CancelStillWorks() public {
        uint256 id = _list(alice, IMarket.Outcome.Yes, 2e6, 500_000);
        vm.warp(market.resolutionDeadline());
        _assertClosedForTrading(IMarket.State.Cancelled, id);
    }

    function _assertClosedForTrading(IMarket.State expected, uint256 id) private {
        assertEq(uint8(market.state()), uint8(expected));
        bytes memory notOpen = abi.encodeWithSelector(IOutcomeOrderBook.MarketNotOpen.selector, expected);

        vm.expectRevert(notOpen);
        vm.prank(alice);
        book.list(market, IMarket.Outcome.Yes, 1, 500_000);
        vm.expectRevert(notOpen);
        _buy(bob, IMarket.Outcome.Yes, 1e6, 500_000, 1);
        vm.expectRevert(notOpen);
        book.quoteBuy(market, IMarket.Outcome.Yes, 1e6, 500_000, 1);

        uint256 aliceShares = token.balanceOf(alice, yesId);
        vm.prank(alice);
        assertEq(book.cancel(id), 2e6);
        assertEq(token.balanceOf(alice, yesId), aliceShares + 2e6);
        assertEq(token.balanceOf(address(book), yesId), 0);
    }

    // OB-12 wrong market

    function test_RevertWhen_MarketFromAnotherFactory() public {
        MarketFactory other = new MarketFactory(admin, address(usdc));
        IMarket foreign = _createMarket(other);
        bytes memory err = abi.encodeWithSelector(IOutcomeOrderBook.NotFactoryMarket.selector, foreign);

        vm.expectRevert(err);
        vm.prank(alice);
        book.list(foreign, IMarket.Outcome.Yes, 1e6, 500_000);
        vm.expectRevert(err);
        _buyFrom(foreign);
        vm.expectRevert(err);
        book.quoteBuy(foreign, IMarket.Outcome.Yes, 1e6, 500_000, 1);
    }

    function test_RevertWhen_MarketImpersonatesFactoryId() public {
        IMarket fake = IMarket(address(new FakeMarket()));
        bytes memory err = abi.encodeWithSelector(IOutcomeOrderBook.NotFactoryMarket.selector, fake);
        vm.expectRevert(err);
        vm.prank(alice);
        book.list(fake, IMarket.Outcome.Yes, 1e6, 500_000);
        vm.expectRevert(err);
        _buyFrom(fake);
    }

    function _buyFrom(IMarket target) private {
        vm.prank(bob);
        book.buy(target, IMarket.Outcome.Yes, 1e6, 500_000, 1);
    }

    // OB-13 no double spending

    function test_RevertWhen_ListingMoreThanHeld() public {
        uint256 shares = _giveShares(alice, IMarket.Outcome.Yes, 10e6);
        vm.prank(alice);
        book.list(market, IMarket.Outcome.Yes, shares, 500_000);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 0, 1, yesId));
        vm.prank(alice);
        book.list(market, IMarket.Outcome.Yes, 1, 500_000);
    }

    function test_Buy_CannotOverfillOrSellTwice() public {
        uint256 a = _list(alice, IMarket.Outcome.Yes, 10e6, 500_000);
        uint256 b = _list(carol, IMarket.Outcome.Yes, 10e6, 500_000);
        _list(dave, IMarket.Outcome.No, 10e6, 500_000);

        (uint256 bought,) = _buy(bob, IMarket.Outcome.Yes, 15e6, 500_000, 10);
        assertEq(bought, 15e6);
        assertEq(book.getListing(a).remaining, 0);
        assertEq(book.getListing(b).remaining, 5e6);
        assertEq(token.balanceOf(address(book), yesId), 5e6);
        assertEq(token.balanceOf(address(book), noId), 10e6, "NO escrow untouched");

        // Asking for more than is listed returns only what is listed.
        (bought,) = _buy(erin, IMarket.Outcome.Yes, 100e6, 500_000, 10);
        assertEq(bought, 5e6);
        assertEq(token.balanceOf(address(book), yesId), 0);

        vm.expectRevert(IOutcomeOrderBook.NothingFilled.selector);
        _buy(erin, IMarket.Outcome.Yes, 1, 999_999, 10);
    }

    // OB-14 reentrancy

    function test_RevertWhen_ReenteringBuyFromReceiver() public {
        _assertReentryBlocked(ReentrantBuyer.Action.Buy);
    }

    function test_RevertWhen_ReenteringCancelFromReceiver() public {
        _assertReentryBlocked(ReentrantBuyer.Action.Cancel);
    }

    function test_RevertWhen_ReenteringListFromReceiver() public {
        _assertReentryBlocked(ReentrantBuyer.Action.List);
    }

    function _assertReentryBlocked(ReentrantBuyer.Action action) private {
        ReentrantBuyer attacker = new ReentrantBuyer(book, market);
        usdc.mint(address(attacker), 100e6);
        attacker.ammBuy(20e6);
        // Its own listing priced out of the outer buy, so a re-entered cancel has something to cancel.
        uint256 own = attacker.list(1e6, 900_000);
        _list(alice, IMarket.Outcome.Yes, 10e6, 500_000);

        uint256 escrowBefore = token.balanceOf(address(book), yesId);
        attacker.arm(action, own);
        (uint256 bought,) = attacker.buy(5e6, 500_000);

        assertEq(bought, 5e6, "outer buy completes");
        assertTrue(attacker.reentryAttempted(), "hook ran");
        assertFalse(attacker.reentrySucceeded(), "re-entry must fail");
        assertEq(
            attacker.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(token.balanceOf(address(book), yesId), escrowBefore - 5e6, "only the outer fill moved shares");
        assertEq(book.getListing(own).remaining, 1e6, "own listing still open");
        assertEq(book.listingCount(), 2, "no listing added");
    }

    // OB-15 conservation (fuzz)

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_ConservationAcrossRandomActions(uint256 seed) public {
        address[3] memory sellers = [alice, carol, dave];
        address[2] memory buyers = [bob, erin];
        for (uint256 i; i < 3; ++i) {
            _giveShares(sellers[i], IMarket.Outcome.Yes, 50e6);
            _giveShares(sellers[i], IMarket.Outcome.No, 50e6);
        }
        uint256[3] memory sellerUsdc0;
        uint256[2] memory buyerUsdc0;
        for (uint256 i; i < 3; ++i) {
            sellerUsdc0[i] = usdc.balanceOf(sellers[i]);
        }
        for (uint256 i; i < 2; ++i) {
            buyerUsdc0[i] = usdc.balanceOf(buyers[i]);
        }
        uint256 yesHeld0 = _heldByUsers(yesId, sellers, buyers);
        uint256 noHeld0 = _heldByUsers(noId, sellers, buyers);

        for (uint256 step; step < 30; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            IMarket.Outcome outcome = IMarket.Outcome((r >> 8) % 2);
            // 2/5 list, 2/5 buy, 1/5 cancel.
            uint256 kind = r % 5;
            if (kind < 2) {
                address seller = sellers[(r >> 16) % 3];
                uint256 held = token.balanceOf(seller, _id(outcome));
                if (held == 0) continue;
                uint256 amount = bound(r >> 24, 1, held < 8e6 ? held : 8e6);
                // A coarse grid makes equal prices common; the offset adds odd prices for rounding.
                uint256 price = ((r >> 64) % 20 + 1) * 45_000 + (r >> 72) % 3;
                vm.prank(seller);
                book.list(market, outcome, amount, price);
            } else if (kind < 4) {
                address buyer = buyers[(r >> 16) % 2];
                uint256 shares = bound(r >> 24, 1, 20e6);
                // Half the buys take any price, so sweeps across several listings are common.
                uint256 maxPrice = (r >> 200) % 2 == 0 ? SCALE - 1 : bound(r >> 64, 1, SCALE - 1);
                uint256 maxListings = (r >> 128) % 5 + 1;
                (uint256 quoted, uint256 quotedCost) = book.quoteBuy(market, outcome, shares, maxPrice, maxListings);
                if (quoted == 0) {
                    vm.expectRevert(IOutcomeOrderBook.NothingFilled.selector);
                    _buy(buyer, outcome, shares, maxPrice, maxListings);
                } else {
                    (uint256 bought, uint256 cost) = _buy(buyer, outcome, shares, maxPrice, maxListings);
                    assertEq(bought, quoted, "quote shares");
                    assertEq(cost, quotedCost, "quote cost");
                    assertLe(bought, shares);
                    assertGe(cost * SCALE, bought, "never free");
                }
            } else {
                uint256 count = book.listingCount();
                if (count == 0) continue;
                uint256 id = (r >> 16) % count + 1;
                IOutcomeOrderBook.Listing memory listing = book.getListing(id);
                if (listing.remaining == 0) {
                    vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.ListingNotFound.selector, id));
                }
                vm.prank(listing.seller);
                book.cancel(id);
            }

            _checkBook(IMarket.Outcome.Yes);
            _checkBook(IMarket.Outcome.No);
        }

        uint256 paid;
        uint256 received;
        for (uint256 i; i < 2; ++i) {
            paid += buyerUsdc0[i] - usdc.balanceOf(buyers[i]);
        }
        for (uint256 i; i < 3; ++i) {
            received += usdc.balanceOf(sellers[i]) - sellerUsdc0[i];
        }
        assertEq(paid, received, "USDC paid == USDC received");
        assertEq(usdc.balanceOf(address(book)), 0, "book holds no USDC");
        assertEq(_heldByUsers(yesId, sellers, buyers) + token.balanceOf(address(book), yesId), yesHeld0, "YES kept");
        assertEq(_heldByUsers(noId, sellers, buyers) + token.balanceOf(address(book), noId), noHeld0, "NO kept");
    }

    function _heldByUsers(uint256 id, address[3] memory sellers, address[2] memory buyers)
        private
        view
        returns (uint256 sum)
    {
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(sellers[i], id);
        }
        for (uint256 i; i < 2; ++i) {
            sum += token.balanceOf(buyers[i], id);
        }
    }

    /// @dev Escrow equals the sum of open listings; the list is sorted, FIFO at equal price, doubly linked
    ///      both ways, and holds every open listing of this book.
    function _checkBook(IMarket.Outcome outcome) private view {
        uint256[] memory ids = _ids(outcome);
        uint256 sum;
        uint256 prevId;
        for (uint256 i; i < ids.length; ++i) {
            IOutcomeOrderBook.Listing memory listing = book.getListing(ids[i]);
            assertGt(listing.remaining, 0, "listed means open");
            assertEq(uint8(listing.outcome), uint8(outcome));
            assertEq(listing.prev, prevId, "back link");
            if (i > 0) {
                IOutcomeOrderBook.Listing memory previous = book.getListing(prevId);
                assertLe(previous.price, listing.price, "sorted");
                if (previous.price == listing.price) assertLt(prevId, ids[i], "FIFO");
            }
            sum += listing.remaining;
            prevId = ids[i];
        }
        assertEq(sum, token.balanceOf(address(book), _id(outcome)), "escrow == open listings");
        assertEq(book.bestPrice(market, outcome), ids.length == 0 ? 0 : book.getListing(ids[0]).price);

        uint256 open;
        uint256 total = book.listingCount();
        for (uint256 id = 1; id <= total; ++id) {
            IOutcomeOrderBook.Listing memory listing = book.getListing(id);
            if (listing.remaining > 0 && listing.outcome == outcome) ++open;
        }
        assertEq(open, ids.length, "no orphaned listing");
    }

    // OB-16 quoteBuy matches buy

    function test_QuoteBuyMatchesBuy() public {
        _list(alice, IMarket.Outcome.No, 7_777_777, 333_333);
        _list(carol, IMarket.Outcome.No, 1_234_567, 333_334);
        _list(dave, IMarket.Outcome.No, 9e6, 410_000);

        (uint256 quoted, uint256 quotedCost) = book.quoteBuy(market, IMarket.Outcome.No, 12e6, 400_000, 10);
        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.No, 12e6, 400_000, 10);
        assertEq(bought, quoted);
        assertEq(cost, quotedCost);
        assertEq(bought, 7_777_777 + 1_234_567);
        assertEq(cost, _ceilCost(7_777_777, 333_333) + _ceilCost(1_234_567, 333_334));
    }

    function test_QuoteBuyReturnsZeroWhenNothingMatches() public {
        _list(alice, IMarket.Outcome.Yes, 1e6, 800_000);
        (uint256 quoted, uint256 quotedCost) = book.quoteBuy(market, IMarket.Outcome.Yes, 1e6, 799_999, 10);
        assertEq(quoted, 0);
        assertEq(quotedCost, 0);
    }

    // listingsOf paging

    function test_ListingsOfPagesInOrder() public {
        uint256 a = _list(alice, IMarket.Outcome.Yes, 1e6, 400_000);
        uint256 b = _list(alice, IMarket.Outcome.Yes, 1e6, 500_000);
        uint256 c = _list(alice, IMarket.Outcome.Yes, 1e6, 600_000);
        uint256 other = _list(alice, IMarket.Outcome.No, 1e6, 600_000);

        uint256[] memory page = book.listingsOf(market, IMarket.Outcome.Yes, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], a);
        assertEq(page[1], b);
        page = book.listingsOf(market, IMarket.Outcome.Yes, b, 2);
        assertEq(page.length, 1);
        assertEq(page[0], c);
        assertEq(book.listingsOf(market, IMarket.Outcome.Yes, c, 5).length, 0);
        assertEq(book.listingsOf(market, IMarket.Outcome.Yes, 0, 0).length, 0);

        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.ListingNotFound.selector, other));
        book.listingsOf(market, IMarket.Outcome.Yes, other, 5);
        vm.prank(alice);
        book.cancel(a);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeOrderBook.ListingNotFound.selector, a));
        book.listingsOf(market, IMarket.Outcome.Yes, a, 5);
    }

    // OB-17 end to end

    function test_EndToEnd_AmmBookResolveRedeem() public {
        uint256 aliceYes = _giveShares(alice, IMarket.Outcome.Yes, 50e6);
        vm.prank(alice);
        uint256 id = book.list(market, IMarket.Outcome.Yes, aliceYes, 700_000);
        uint256 aliceUsdc = usdc.balanceOf(alice);

        (uint256 bought, uint256 cost) = _buy(bob, IMarket.Outcome.Yes, 40e6, 700_000, 5);
        assertEq(bought, 40e6);
        assertEq(cost, 28e6);
        assertEq(usdc.balanceOf(alice), aliceUsdc + 28e6);

        vm.warp(closeTime);
        vm.prank(alice);
        assertEq(book.cancel(id), aliceYes - 40e6);

        vm.prank(arbiter);
        market.resolve(IMarket.Outcome.Yes);

        uint256 bobUsdc = usdc.balanceOf(bob);
        vm.prank(bob);
        assertEq(market.redeem(), 40e6);
        assertEq(usdc.balanceOf(bob), bobUsdc + 40e6);
        assertEq(token.balanceOf(bob, yesId), 0);

        vm.prank(alice);
        assertEq(market.redeem(), aliceYes - 40e6);
        assertEq(token.balanceOf(address(book), yesId), 0);
        assertEq(IERC20(address(usdc)).balanceOf(address(book)), 0);
    }
}
