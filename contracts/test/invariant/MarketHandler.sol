// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HandlerBase, Clock} from "./HandlerBase.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {IOutcomeToken} from "../../src/interfaces/IOutcomeToken.sol";
import {IOutcomeOrderBook} from "../../src/interfaces/IOutcomeOrderBook.sol";

/// @notice Drives the AMM, the order book, the EOA arbitrator, redemption, withdrawals and donations
///         across every market. Markets `0 .. eoaMarkets - 1` are resolved by `arbitrator`; the others
///         belong to the OptimisticResolver and are resolved by ResolverHandler.
contract MarketHandler is HandlerBase {
    uint256 internal constant PRICE_SCALE = 1e6;
    uint256 internal constant MAX_BUY = 200e6;
    uint256 internal constant WHALE_BUY = 1_000e6;

    IOutcomeOrderBook public immutable book;
    address public immutable arbitrator;
    address public immutable whale;
    address public immutable donor;
    uint256 public immutable eoaMarkets;

    // Per-market ghosts, keyed by market index.
    mapping(uint256 => uint256) public deposited; // seed + collateralIn of every buy
    mapping(uint256 => uint256) public paidOut; // sell, redeem, withdrawLiquidity, withdrawFees
    mapping(uint256 => uint256) public donatedCollateral;
    mapping(uint256 => uint256) public donatedYes;
    mapping(uint256 => uint256) public donatedNo;
    mapping(uint256 => uint256) public feesExpected; // sum of ceil(1% of gross) over trades
    mapping(uint256 => uint256) public feesWithdrawn;
    mapping(uint256 => uint256) public exits; // successful redeem + withdrawLiquidity
    mapping(uint256 => uint256) public cancelledExits; // exits while Cancelled
    mapping(uint256 => uint256) public liquidityWithdrawals;
    mapping(uint256 => uint256) public resolves;
    mapping(uint256 => IMarket.Outcome) public firstOutcome;

    // Order-book ghosts.
    uint256 public bookPaid; // sum of `cost` returned by successful buys
    uint256 public bookReceived; // sum of measured seller receipts

    // Violation counters: each must stay 0.
    uint256 public feeMismatches;
    uint256 public feeWithdrawnWhileOpen;
    uint256 public productDecreases;
    uint256 public roundTripProfits;
    uint256 public tradesOutsideOpen;
    uint256 public resolvesOutsideClosed;
    uint256 public redeemMismatches;
    uint256 public cancelledRedeemMismatches;
    uint256 public liquidityPayoutMismatches;
    uint256 public doubleClaims;
    uint256 public bookModelMismatches;
    uint256 public cancelMismatches;

    // Reach counters (not invariants): show the sequence got somewhere.
    mapping(bytes32 => uint256) public calls;

    struct Snap {
        uint256 supplyYes;
        uint256 supplyNo;
        uint256 fees;
        uint256 balance;
        uint256 product;
    }

    struct BookBuy {
        IMarket market;
        IMarket.Outcome outcome;
        uint256 shares;
        uint256 maxPrice;
        uint256 maxListings;
        uint256 buyerIdx;
        address buyer;
        uint256 id;
        uint256 escrowBefore;
        uint256 buyerSharesBefore;
        uint256[] usdcBefore;
    }

    struct Fill {
        uint256 shares;
        uint256 cost;
        uint256[] receipts; // per actor index
    }

    constructor(
        MockUSDC usdc_,
        IOutcomeToken token_,
        Clock clock_,
        IMarket[] memory markets_,
        address[] memory actors_,
        IOutcomeOrderBook book_,
        address arbitrator_,
        address whale_,
        address donor_,
        uint256 eoaMarkets_,
        uint256 seed
    ) HandlerBase(usdc_, token_, clock_, markets_, actors_) {
        book = book_;
        arbitrator = arbitrator_;
        whale = whale_;
        donor = donor_;
        eoaMarkets = eoaMarkets_;
        for (uint256 i; i < markets_.length; ++i) {
            deposited[i] = seed;
        }
    }

    // ---------------------------------------------------------------- AMM

    function buy(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amount) external synced {
        uint256 i = marketSeed % _markets.length;
        amount = _bound(amount, 1, MAX_BUY);
        _doBuy(i, _actor(actorSeed), _outcome(outcomeSeed), amount);
    }

    function sell(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amount) external synced {
        uint256 i = marketSeed % _markets.length;
        address actor = _actor(actorSeed);
        IMarket.Outcome outcome = _outcome(outcomeSeed);
        uint256 held = token.balanceOf(actor, _id(_markets[i], outcome));
        if (held == 0) return;
        _doSell(i, actor, outcome, _bound(amount, 1, held));
    }

    /// @dev INV-COL-6 second half: a buy then a sell of exactly the shares bought never profits.
    function roundTrip(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amount) external synced {
        uint256 i = marketSeed % _markets.length;
        address actor = _actor(actorSeed);
        IMarket.Outcome outcome = _outcome(outcomeSeed);
        amount = _bound(amount, 1, MAX_BUY);
        (bool bought, uint256 shares) = _doBuy(i, actor, outcome, amount);
        if (!bought) return;
        (bool sold, uint256 out) = _doSell(i, actor, outcome, shares);
        if (sold && out > amount) ++roundTripProfits;
        ++calls["roundTrip"];
    }

    function _doBuy(uint256 i, address actor, IMarket.Outcome outcome, uint256 amount)
        internal
        returns (bool ok, uint256 shares)
    {
        IMarket market = _markets[i];
        usdc.mint(actor, amount);
        IMarket.State st = market.state();
        Snap memory before = _snap(market);
        vm.prank(actor);
        try market.buy(outcome, amount, 0, vm.getBlockTimestamp()) returns (uint256 out) {
            ok = true;
            shares = out;
            if (st != IMarket.State.Open) ++tradesOutsideOpen;
            Snap memory afterwards = _snap(market);
            uint256 fee = _ceilFee(amount);
            uint256 net = amount - fee;
            // The fee is booked apart from backing and mints nothing (INV-COL-3).
            if (afterwards.fees != before.fees + fee) ++feeMismatches;
            if (afterwards.supplyYes != before.supplyYes + net || afterwards.supplyNo != before.supplyNo + net) {
                ++feeMismatches;
            }
            if (afterwards.balance != before.balance + amount) ++feeMismatches;
            if (afterwards.product < before.product) ++productDecreases;
            deposited[i] += amount;
            feesExpected[i] += fee;
            ++calls["buy"];
        } catch {}
    }

    function _doSell(uint256 i, address actor, IMarket.Outcome outcome, uint256 shares)
        internal
        returns (bool ok, uint256 out)
    {
        IMarket market = _markets[i];
        IMarket.State st = market.state();
        Snap memory before = _snap(market);
        vm.prank(actor);
        try market.sell(outcome, shares, 0, vm.getBlockTimestamp()) returns (uint256 collateralOut) {
            ok = true;
            out = collateralOut;
            if (st != IMarket.State.Open) ++tradesOutsideOpen;
            Snap memory afterwards = _snap(market);
            // gross = what was burned from both supplies; the fee is ceil(1%) of it and stays in the market.
            if (afterwards.supplyYes > before.supplyYes || afterwards.supplyNo > before.supplyNo) {
                ++feeMismatches;
            } else {
                uint256 gross = before.supplyYes - afterwards.supplyYes;
                uint256 fee = _ceilFee(gross);
                if (before.supplyNo - afterwards.supplyNo != gross) ++feeMismatches;
                if (afterwards.fees != before.fees + fee || collateralOut + fee != gross) ++feeMismatches;
                feesExpected[i] += fee;
            }
            if (afterwards.balance + collateralOut != before.balance) ++feeMismatches;
            if (afterwards.product < before.product) ++productDecreases;
            paidOut[i] += collateralOut;
            ++calls["sell"];
        } catch {}
    }

    function _snap(IMarket market) internal view returns (Snap memory s) {
        s.supplyYes = token.totalSupply(market.yesTokenId());
        s.supplyNo = token.totalSupply(market.noTokenId());
        s.fees = market.accruedFees();
        s.balance = usdc.balanceOf(address(market));
        s.product = market.yesPool() * market.noPool();
    }

    // ---------------------------------------------------------------- order book

    function list(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amount, uint256 priceSeed)
        external
        synced
    {
        IMarket market = _markets[marketSeed % _markets.length];
        address actor = _actor(actorSeed);
        IMarket.Outcome outcome = _outcome(outcomeSeed);
        uint256 held = token.balanceOf(actor, _id(market, outcome));
        if (held == 0) return;
        amount = _bound(amount, 1, held);
        uint256 price = _price(priceSeed);
        IMarket.State st = market.state();
        vm.prank(actor);
        try book.list(market, outcome, amount, price) {
            if (st != IMarket.State.Open) ++tradesOutsideOpen;
            ++calls["list"];
        } catch {}
    }

    /// @dev A coarse grid makes equal prices (FIFO) common; the offset and the two extremes add rounding cases.
    function _price(uint256 seed) internal pure returns (uint256) {
        uint256 r = seed % 23;
        if (r == 0) return 1;
        if (r == 1) return PRICE_SCALE - 1;
        return ((seed >> 8) % 20 + 1) * 45_000 + (seed >> 16) % 3;
    }

    function bookBuy(
        uint256 actorSeed,
        uint256 marketSeed,
        uint256 outcomeSeed,
        uint256 shares,
        uint256 maxPriceSeed,
        uint256 maxListingsSeed
    ) external synced {
        BookBuy memory a;
        a.market = _markets[marketSeed % _markets.length];
        a.outcome = _outcome(outcomeSeed);
        // Mostly aim at a book that has (or had) listings; books are sparse otherwise.
        uint256 count = book.listingCount();
        if (count > 0 && marketSeed % 4 != 0) {
            IOutcomeOrderBook.Listing memory l = book.getListing((marketSeed >> 2) % count + 1);
            a.market = l.market;
            a.outcome = l.outcome;
        }
        a.buyerIdx = actorSeed % _actors.length;
        a.buyer = _actors[a.buyerIdx];
        a.shares = _bound(shares, 1, 300e6);
        a.maxPrice = maxPriceSeed % 2 == 0 ? PRICE_SCALE - 1 : _bound(maxPriceSeed >> 1, 1, PRICE_SCALE - 1);
        a.maxListings = _bound(maxListingsSeed, 1, 6);
        a.id = _id(a.market, a.outcome);

        Fill memory model = _model(a.market, a.outcome, a.shares, a.maxPrice, a.maxListings);
        usdc.mint(a.buyer, model.cost);
        a.usdcBefore = _actorBalances();
        a.escrowBefore = token.balanceOf(address(book), a.id);
        a.buyerSharesBefore = token.balanceOf(a.buyer, a.id);
        IMarket.State st = a.market.state();

        vm.prank(a.buyer);
        try book.buy(a.market, a.outcome, a.shares, a.maxPrice, a.maxListings) returns (uint256 bought, uint256 cost) {
            if (st != IMarket.State.Open) ++tradesOutsideOpen;
            _checkFill(a, model, bought, cost);
            ++calls["bookBuy"];
        } catch {
            // The model found a fill in an Open market, so the buy had to succeed.
            if (st == IMarket.State.Open && model.shares > 0) ++bookModelMismatches;
        }
    }

    function _checkFill(BookBuy memory a, Fill memory model, uint256 bought, uint256 cost) internal {
        if (bought != model.shares || cost != model.cost) ++bookModelMismatches;
        if (a.escrowBefore != token.balanceOf(address(book), a.id) + bought) ++bookModelMismatches;
        if (token.balanceOf(a.buyer, a.id) != a.buyerSharesBefore + bought) ++bookModelMismatches;
        _checkReceipts(a.usdcBefore, model.receipts, a.buyerIdx, cost);
        bookPaid += cost;
    }

    /// @dev Independent walk of the book: cheapest first, FIFO, at most `maxListings`, ceil cost per listing.
    function _model(IMarket market, IMarket.Outcome outcome, uint256 shares, uint256 maxPrice, uint256 maxListings)
        internal
        view
        returns (Fill memory f)
    {
        f.receipts = new uint256[](_actors.length);
        uint256[] memory ids = book.listingsOf(market, outcome, 0, maxListings);
        uint256 wanted = shares;
        for (uint256 k; k < ids.length && wanted > 0; ++k) {
            IOutcomeOrderBook.Listing memory l = book.getListing(ids[k]);
            if (l.price > maxPrice) break;
            uint256 fill = l.remaining < wanted ? l.remaining : wanted;
            uint256 cost = (fill * l.price + PRICE_SCALE - 1) / PRICE_SCALE;
            f.receipts[_actorIndex(l.seller)] += cost;
            f.shares += fill;
            f.cost += cost;
            wanted -= fill;
        }
    }

    function _checkReceipts(uint256[] memory before, uint256[] memory expected, uint256 buyerIdx, uint256 cost)
        internal
    {
        uint256 received;
        for (uint256 k; k < _actors.length; ++k) {
            uint256 nowBal = usdc.balanceOf(_actors[k]);
            uint256 credit = nowBal + (k == buyerIdx ? cost : 0);
            if (credit != before[k] + expected[k]) ++bookModelMismatches;
            if (credit >= before[k]) received += credit - before[k];
        }
        bookReceived += received;
    }

    function cancel(uint256 listingSeed, uint256 callerSeed) external synced {
        uint256 count = book.listingCount();
        if (count == 0) return;
        uint256 listingId = listingSeed % count + 1;
        IOutcomeOrderBook.Listing memory l = book.getListing(listingId);
        uint256 id = _id(l.market, l.outcome);
        if (l.remaining == 0) {
            // Filled or cancelled: nobody can take anything out of it.
            vm.prank(_actor(callerSeed));
            try book.cancel(listingId) {
                ++cancelMismatches;
            } catch {}
            return;
        }
        uint256 sellerBefore = token.balanceOf(l.seller, id);
        vm.prank(l.seller);
        try book.cancel(listingId) returns (uint256 returned) {
            if (returned != l.remaining || token.balanceOf(l.seller, id) != sellerBefore + returned) {
                ++cancelMismatches;
            }
            ++calls["cancel"];
        } catch {
            // Cancel works in every market state, so the seller's shares are never stuck.
            ++cancelMismatches;
        }
    }

    // ---------------------------------------------------------------- transfers and donations

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amount)
        external
        synced
    {
        IMarket market = _markets[marketSeed % _markets.length];
        address from = _actor(fromSeed);
        uint256 id = _id(market, _outcome(outcomeSeed));
        uint256 held = token.balanceOf(from, id);
        if (held == 0) return;
        vm.prank(from);
        token.safeTransferFrom(from, _actor(toSeed), id, _bound(amount, 1, held), "");
        ++calls["transfer"];
    }

    function donateCollateral(uint256 marketSeed, uint256 amount) external synced {
        uint256 i = marketSeed % _markets.length;
        amount = _bound(amount, 1, 50e6);
        usdc.mint(donor, amount);
        vm.prank(donor);
        usdc.transfer(address(_markets[i]), amount);
        donatedCollateral[i] += amount;
        ++calls["donateCollateral"];
    }

    function donateShares(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amount) external synced {
        uint256 i = marketSeed % _markets.length;
        IMarket.Outcome outcome = _outcome(outcomeSeed);
        address actor = _actor(actorSeed);
        uint256 id = _id(_markets[i], outcome);
        uint256 held = token.balanceOf(actor, id);
        if (held == 0) return;
        amount = _bound(amount, 1, held);
        _donateShares(i, actor, outcome, amount);
    }

    /// @dev A whale buys a lot of both sides and sends it all to the market, so the market holds more
    ///      YES and NO than its pools. Without this, a second `withdrawLiquidity` is blocked by the burn
    ///      and the `liquidityWithdrawn` flag cannot be told apart from it (mutation check b).
    function bulkDonateShares(uint256 marketSeed) external synced {
        uint256 i = marketSeed % _markets.length;
        if (_markets[i].state() != IMarket.State.Open) return;
        (bool yesOk, uint256 yesShares) = _doBuy(i, whale, IMarket.Outcome.Yes, WHALE_BUY);
        (bool noOk, uint256 noShares) = _doBuy(i, whale, IMarket.Outcome.No, WHALE_BUY);
        if (yesOk) _donateShares(i, whale, IMarket.Outcome.Yes, yesShares);
        if (noOk) _donateShares(i, whale, IMarket.Outcome.No, noShares);
        ++calls["bulkDonate"];
    }

    function _donateShares(uint256 i, address from, IMarket.Outcome outcome, uint256 amount) internal {
        IMarket market = _markets[i];
        // The id is read first: an external call between prank and transfer would use up the prank.
        uint256 id = _id(market, outcome);
        vm.prank(from);
        token.safeTransferFrom(from, address(market), id, amount, "");
        if (outcome == IMarket.Outcome.Yes) donatedYes[i] += amount;
        else donatedNo[i] += amount;
        ++calls["donateShares"];
    }

    // ---------------------------------------------------------------- time

    function warp(uint256 dt) external synced {
        _advanceTo(vm.getBlockTimestamp() + _bound(dt, 1, 6 hours));
        ++calls["warp"];
    }

    /// @dev Lands exactly on a market's close or deadline, or one second either side. Deadlines are picked
    ///      less often than closes, since a deadline jump settles most markets for the rest of the run.
    function warpToEdge(uint256 marketSeed, uint256 edgeSeed) external synced {
        IMarket market = _markets[marketSeed % _markets.length];
        uint256 close = market.closeTime();
        uint256 deadline = market.resolutionDeadline();
        uint256 e = edgeSeed % 6;
        uint256 t =
            e == 0 || e == 3 ? close - 1 : e == 1 ? close : e == 2 ? close + 1 : e == 4 ? deadline - 1 : deadline;
        _advanceTo(t);
        ++calls["warpToEdge"];
    }

    // ---------------------------------------------------------------- settlement

    /// @dev Tried in every state, so a resolve outside Closed or a second resolve would be seen.
    function resolve(uint256 marketSeed, uint256 outcomeSeed) external synced {
        uint256 i = marketSeed % eoaMarkets;
        IMarket market = _markets[i];
        IMarket.Outcome outcome = _outcome(outcomeSeed);
        IMarket.State st = market.state();
        vm.prank(arbitrator);
        try market.resolve(outcome) {
            if (st != IMarket.State.Closed) ++resolvesOutsideClosed;
            if (++resolves[i] == 1) firstOutcome[i] = outcome;
            ++calls["resolve"];
        } catch {}
    }

    function redeem(uint256 actorSeed, uint256 marketSeed) external synced {
        uint256 i = marketSeed % _markets.length;
        _redeem(i, _actor(actorSeed));
    }

    function _redeem(uint256 i, address actor) internal {
        IMarket market = _markets[i];
        uint256 y = token.balanceOf(actor, market.yesTokenId());
        uint256 n = token.balanceOf(actor, market.noTokenId());
        IMarket.State st = market.state();
        uint256 expected = _value(market, st, y, n);
        uint256 balBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        try market.redeem() returns (uint256 payout) {
            bool wrong = payout != expected || usdc.balanceOf(actor) != balBefore + payout
                || token.balanceOf(actor, market.yesTokenId()) != 0 || token.balanceOf(actor, market.noTokenId()) != 0;
            if (wrong) {
                if (st == IMarket.State.Cancelled) ++cancelledRedeemMismatches;
                else ++redeemMismatches;
            }
            ++exits[i];
            if (st == IMarket.State.Cancelled) ++cancelledExits[i];
            paidOut[i] += payout;
            ++calls["redeem"];
            // No double claim: the shares are burned, so the same holder gets nothing more.
            vm.prank(actor);
            try market.redeem() {
                ++doubleClaims;
            } catch {}
        } catch {
            // A settled holder with a non-zero claim must be paid.
            if (expected > 0) {
                if (st == IMarket.State.Cancelled) ++cancelledRedeemMismatches;
                else ++redeemMismatches;
            }
        }
    }

    /// @dev Settlement value from the documented rules, independent of Market._settlementValue.
    function _value(IMarket market, IMarket.State st, uint256 y, uint256 n) internal view returns (uint256) {
        if (st == IMarket.State.Resolved) return market.winningOutcome() == IMarket.Outcome.Yes ? y : n;
        if (st == IMarket.State.Cancelled) return (y + n) / 2;
        return 0;
    }

    function withdrawLiquidity(uint256 callerSeed, uint256 marketSeed) external synced {
        uint256 i = marketSeed % _markets.length;
        IMarket market = _markets[i];
        IMarket.State st = market.state();
        uint256 expected = _value(market, st, market.yesPool(), market.noPool());
        address creator = market.creator();
        uint256 creatorBefore = usdc.balanceOf(creator);
        vm.prank(_actor(callerSeed));
        try market.withdrawLiquidity() returns (uint256 amount) {
            if (amount != expected || usdc.balanceOf(creator) != creatorBefore + amount) ++liquidityPayoutMismatches;
            ++liquidityWithdrawals[i];
            ++exits[i];
            if (st == IMarket.State.Cancelled) ++cancelledExits[i];
            paidOut[i] += amount;
            ++calls["withdrawLiquidity"];
        } catch {}
    }

    function withdrawFees(uint256 callerSeed, uint256 marketSeed) external synced {
        uint256 i = marketSeed % _markets.length;
        IMarket market = _markets[i];
        IMarket.State st = market.state();
        uint256 fees = market.accruedFees();
        address creator = market.creator();
        uint256 creatorBefore = usdc.balanceOf(creator);
        address caller = _actor(callerSeed);
        vm.prank(caller);
        try market.withdrawFees() returns (uint256 amount) {
            if (st == IMarket.State.Open) ++feeWithdrawnWhileOpen;
            if (amount != fees || usdc.balanceOf(creator) != creatorBefore + amount) ++feeMismatches;
            feesWithdrawn[i] += amount;
            paidOut[i] += amount;
            ++calls["withdrawFees"];
            vm.prank(caller);
            try market.withdrawFees() {
                ++doubleClaims;
            } catch {}
        } catch {}
    }

    // ---------------------------------------------------------------- helpers

    function _actorBalances() internal view returns (uint256[] memory b) {
        b = new uint256[](_actors.length);
        for (uint256 k; k < _actors.length; ++k) {
            b[k] = usdc.balanceOf(_actors[k]);
        }
    }

    function _actorIndex(address a) internal view returns (uint256) {
        for (uint256 k; k < _actors.length; ++k) {
            if (_actors[k] == a) return k;
        }
        revert("unknown seller");
    }

    /// @dev For afterInvariant: every holder (traders and the whale) exits every market.
    function holders() external view returns (address[] memory h) {
        h = new address[](_actors.length + 1);
        for (uint256 k; k < _actors.length; ++k) {
            h[k] = _actors[k];
        }
        h[_actors.length] = whale;
    }
}
