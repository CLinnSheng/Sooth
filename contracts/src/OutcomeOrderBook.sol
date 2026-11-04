// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IOutcomeToken} from "./interfaces/IOutcomeToken.sol";
import {IOutcomeOrderBook} from "./interfaces/IOutcomeOrderBook.sol";

/// @title OutcomeOrderBook
/// @notice Secondary market for the outcome shares of every factory market. Sellers escrow shares in a
///         listing; buyers fill from the cheapest listing first, oldest first at the same price, and pay
///         each seller directly. Only existing shares change hands: nothing is minted, burned or kept.
/// @dev Each (market, outcome) book is a doubly linked list sorted by price ascending.
///      shortcut: sellers are paid in the fill, so a seller blocked by the collateral (USDC blacklist)
///      makes fills against their listing revert until they cancel it.
contract OutcomeOrderBook is ERC1155Holder, ReentrancyGuardTransient, IOutcomeOrderBook {
    using SafeERC20 for IERC20;

    /// @dev Ends of one book. 0 means empty; listing ids start at 1.
    struct Book {
        uint256 head;
        uint256 tail;
    }

    uint256 public constant PRICE_SCALE = 1e6;

    IMarketFactory public immutable factory;
    IOutcomeToken public immutable outcomeToken;

    uint256 public listingCount;

    mapping(uint256 listingId => Listing) internal _listings;
    mapping(IMarket market => mapping(IMarket.Outcome outcome => Book)) internal _books;

    constructor(IMarketFactory factory_) {
        factory = factory_;
        outcomeToken = factory_.outcomeToken();
    }

    function list(IMarket market, IMarket.Outcome outcome, uint256 amount, uint256 price)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        if (amount == 0) revert ZeroAmount();
        if (price == 0 || price >= PRICE_SCALE) revert InvalidPrice(price);
        _requireFactoryMarket(market);
        _requireOpen(market);

        listingId = ++listingCount;
        _listings[listingId] = Listing({
            seller: msg.sender, market: market, outcome: outcome, price: price, remaining: amount, prev: 0, next: 0
        });
        _insert(_books[market][outcome], listingId, price);

        emit Listed(listingId, market, msg.sender, outcome, amount, price);
        outcomeToken.safeTransferFrom(msg.sender, address(this), _tokenId(market, outcome), amount, "");
    }

    function buy(IMarket market, IMarket.Outcome outcome, uint256 shares, uint256 maxPrice, uint256 maxListings)
        external
        nonReentrant
        returns (uint256 sharesBought, uint256 cost)
    {
        _requireBuyArgs(shares, maxListings);
        _requireFactoryMarket(market);
        _requireOpen(market);

        Book storage book = _books[market][outcome];
        IERC20 collateral = market.collateral();
        uint256 id = book.head;
        for (uint256 touched; _canFill(id, shares - sharesBought, maxPrice, touched, maxListings); ++touched) {
            (uint256 fill, uint256 fillCost, uint256 next) = _take(book, id, shares - sharesBought, collateral);
            sharesBought += fill;
            cost += fillCost;
            id = next;
        }
        if (sharesBought == 0) revert NothingFilled();

        // One transfer for the whole sweep, after every listing is settled.
        outcomeToken.safeTransferFrom(address(this), msg.sender, _tokenId(market, outcome), sharesBought, "");
    }

    function cancel(uint256 listingId) external nonReentrant returns (uint256 returned) {
        Listing storage listing = _listings[listingId];
        returned = listing.remaining;
        // Covers unknown ids too: their remaining is 0.
        if (returned == 0) revert ListingNotFound(listingId);
        if (msg.sender != listing.seller) revert NotSeller(msg.sender);

        IMarket market = listing.market;
        IMarket.Outcome outcome = listing.outcome;
        listing.remaining = 0;
        _unlink(_books[market][outcome], listing);

        emit Cancelled(listingId, market, msg.sender, returned);
        outcomeToken.safeTransferFrom(address(this), msg.sender, _tokenId(market, outcome), returned, "");
    }

    /// @dev Reverts exactly where `buy` would, except that an empty match returns (0, 0) instead of
    ///      reverting with NothingFilled, so a website can show "nothing at this price".
    function quoteBuy(IMarket market, IMarket.Outcome outcome, uint256 shares, uint256 maxPrice, uint256 maxListings)
        external
        view
        returns (uint256 sharesBought, uint256 cost)
    {
        _requireBuyArgs(shares, maxListings);
        _requireFactoryMarket(market);
        _requireOpen(market);

        uint256 id = _books[market][outcome].head;
        for (uint256 touched; _canFill(id, shares - sharesBought, maxPrice, touched, maxListings); ++touched) {
            Listing storage listing = _listings[id];
            (uint256 fill, uint256 fillCost) = _fill(listing, shares - sharesBought);
            sharesBought += fill;
            cost += fillCost;
            id = listing.next;
        }
    }

    function bestPrice(IMarket market, IMarket.Outcome outcome) external view returns (uint256) {
        uint256 head = _books[market][outcome].head;
        return head == 0 ? 0 : _listings[head].price;
    }

    /// @dev Reverts with ListingNotFound if `startAfter` is not an open listing of this book.
    function listingsOf(IMarket market, IMarket.Outcome outcome, uint256 startAfter, uint256 count)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256 first;
        if (startAfter == 0) {
            first = _books[market][outcome].head;
        } else {
            Listing storage start = _listings[startAfter];
            if (start.remaining == 0 || start.market != market || start.outcome != outcome) {
                revert ListingNotFound(startAfter);
            }
            first = start.next;
        }

        // Count first so a large `count` never allocates more memory than the book holds.
        uint256 n;
        for (uint256 id = first; id != 0 && n < count; id = _listings[id].next) {
            ++n;
        }
        ids = new uint256[](n);
        uint256 cursor = first;
        for (uint256 i; i < n; ++i) {
            ids[i] = cursor;
            cursor = _listings[cursor].next;
        }
    }

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /// @dev Fills one listing for the caller: updates (and unlinks if emptied) before paying the seller.
    function _take(Book storage book, uint256 id, uint256 wanted, IERC20 collateral)
        internal
        returns (uint256 fill, uint256 fillCost, uint256 next)
    {
        Listing storage listing = _listings[id];
        (fill, fillCost) = _fill(listing, wanted);
        next = listing.next;
        address seller = listing.seller;

        listing.remaining -= fill;
        if (listing.remaining == 0) _unlink(book, listing);

        emit Filled(id, listing.market, msg.sender, seller, listing.outcome, fill, fillCost);
        collateral.safeTransferFrom(msg.sender, seller, fillCost);
    }

    /// @dev Inserts after the last listing priced at or below `price`, so equal prices stay FIFO.
    ///      Starts at the tail when the new listing is the most expensive, else walks from the head.
    function _insert(Book storage book, uint256 id, uint256 price) internal {
        uint256 prevId = book.tail;
        if (prevId != 0 && _listings[prevId].price > price) {
            prevId = 0;
            uint256 cursor = book.head;
            while (cursor != 0 && _listings[cursor].price <= price) {
                prevId = cursor;
                cursor = _listings[cursor].next;
            }
        }

        uint256 nextId = prevId == 0 ? book.head : _listings[prevId].next;
        Listing storage listing = _listings[id];
        listing.prev = prevId;
        listing.next = nextId;
        if (prevId == 0) book.head = id;
        else _listings[prevId].next = id;
        if (nextId == 0) book.tail = id;
        else _listings[nextId].prev = id;
    }

    /// @dev Clears the listing's links too, so a closed listing reads as prev = next = 0.
    function _unlink(Book storage book, Listing storage listing) internal {
        uint256 prevId = listing.prev;
        uint256 nextId = listing.next;
        if (prevId == 0) book.head = nextId;
        else _listings[prevId].next = nextId;
        if (nextId == 0) book.tail = prevId;
        else _listings[nextId].prev = prevId;
        listing.prev = 0;
        listing.next = 0;
    }

    /// @dev The walk condition shared by `buy` and `quoteBuy`, so the two cannot drift apart.
    function _canFill(uint256 id, uint256 wanted, uint256 maxPrice, uint256 touched, uint256 maxListings)
        internal
        view
        returns (bool)
    {
        return id != 0 && wanted != 0 && touched < maxListings && _listings[id].price <= maxPrice;
    }

    /// @dev Rounds the cost up, so a fill can never be free.
    function _fill(Listing storage listing, uint256 wanted) internal view returns (uint256 fill, uint256 fillCost) {
        fill = Math.min(listing.remaining, wanted);
        fillCost = Math.mulDiv(fill, listing.price, PRICE_SCALE, Math.Rounding.Ceil);
    }

    function _requireBuyArgs(uint256 shares, uint256 maxListings) internal pure {
        if (shares == 0 || maxListings == 0) revert ZeroAmount();
    }

    function _requireFactoryMarket(IMarket market) internal view {
        if (factory.markets(market.marketId()) != address(market)) revert NotFactoryMarket(market);
    }

    function _requireOpen(IMarket market) internal view {
        IMarket.State current = market.state();
        if (current != IMarket.State.Open) revert MarketNotOpen(current);
    }

    function _tokenId(IMarket market, IMarket.Outcome outcome) internal view returns (uint256) {
        return outcome == IMarket.Outcome.Yes ? market.yesTokenId() : market.noTokenId();
    }
}
