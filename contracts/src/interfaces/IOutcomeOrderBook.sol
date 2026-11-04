// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMarket} from "./IMarket.sol";
import {IMarketFactory} from "./IMarketFactory.sol";
import {IOutcomeToken} from "./IOutcomeToken.sol";

/// @title IOutcomeOrderBook
/// @notice Secondary market for outcome shares. Holders list YES or NO shares at a fixed price; buyers are
///         matched against the cheapest listings first (oldest first at the same price). Shares sit in escrow
///         here while listed. Trading follows the AMM window: only while the market is Open. No fee.
/// @dev Prices are collateral units per whole share (1e6 units), strictly between 0 and PRICE_SCALE.
interface IOutcomeOrderBook {
    struct Listing {
        address seller;
        IMarket market;
        IMarket.Outcome outcome;
        uint256 price;
        uint256 remaining;
        uint256 prev;
        uint256 next;
    }

    event Listed(
        uint256 indexed listingId,
        IMarket indexed market,
        address indexed seller,
        IMarket.Outcome outcome,
        uint256 amount,
        uint256 price
    );
    event Filled(
        uint256 indexed listingId,
        IMarket indexed market,
        address indexed buyer,
        address seller,
        IMarket.Outcome outcome,
        uint256 shares,
        uint256 cost
    );
    event Cancelled(uint256 indexed listingId, IMarket indexed market, address indexed seller, uint256 returned);

    error NotFactoryMarket(IMarket market);
    error MarketNotOpen(IMarket.State currentState);
    error ZeroAmount();
    error InvalidPrice(uint256 price);
    error NotSeller(address caller);
    error ListingNotFound(uint256 listingId);
    error NothingFilled();

    /// @notice Moves `amount` shares of `outcome` into escrow and adds a listing at `price`. The caller must
    ///         first call `setApprovalForAll(orderBook, true)` on the outcome token. Only while Open.
    function list(IMarket market, IMarket.Outcome outcome, uint256 amount, uint256 price)
        external
        returns (uint256 listingId);

    /// @notice Buys up to `shares` from the cheapest listings priced at or below `maxPrice`, touching at most
    ///         `maxListings` listings. Each seller is paid ceil(fill * price / PRICE_SCALE) in collateral, pulled
    ///         from the caller (approve this contract first). Reverts with NothingFilled if nothing matched.
    function buy(IMarket market, IMarket.Outcome outcome, uint256 shares, uint256 maxPrice, uint256 maxListings)
        external
        returns (uint256 sharesBought, uint256 cost);

    /// @notice Seller only, in any market state. Removes the listing and returns its remaining shares.
    function cancel(uint256 listingId) external returns (uint256 returned);

    /// @notice What `buy` would fill and cost right now, with the same arguments.
    function quoteBuy(IMarket market, IMarket.Outcome outcome, uint256 shares, uint256 maxPrice, uint256 maxListings)
        external
        view
        returns (uint256 sharesBought, uint256 cost);

    /// @notice Lowest listed price for this market and outcome, or 0 if there are no listings.
    function bestPrice(IMarket market, IMarket.Outcome outcome) external view returns (uint256);

    /// @notice Up to `count` listing ids in price order, starting after `startAfter` (0 = from the cheapest).
    function listingsOf(IMarket market, IMarket.Outcome outcome, uint256 startAfter, uint256 count)
        external
        view
        returns (uint256[] memory ids);

    /// @notice A listing by id. `remaining == 0` means it was filled or cancelled.
    function getListing(uint256 listingId) external view returns (Listing memory);

    function PRICE_SCALE() external view returns (uint256);
    function factory() external view returns (IMarketFactory);
    function outcomeToken() external view returns (IOutcomeToken);
    function listingCount() external view returns (uint256);
}
