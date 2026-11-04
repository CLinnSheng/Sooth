// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {OptimisticResolver} from "../../src/OptimisticResolver.sol";
import {OutcomeOrderBook} from "../../src/OutcomeOrderBook.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IOutcomeToken} from "../../src/interfaces/IOutcomeToken.sol";
import {IOutcomeOrderBook} from "../../src/interfaces/IOutcomeOrderBook.sol";
import {IOptimisticResolver} from "../../src/interfaces/IOptimisticResolver.sol";
import {Clock} from "./HandlerBase.sol";
import {MarketHandler} from "./MarketHandler.sol";
import {ResolverHandler} from "./ResolverHandler.sol";

/// @notice Stateful invariants for docs/invariants.md (rows of task P1-2) and the order book (INV-OB-*).
///         Four real markets from one factory: 0 and 1 resolved by an EOA arbitrator, 2 and 3 by the
///         OptimisticResolver. Five traders, a whale, a donor, the judge and a shared clock that crosses
///         close, deadline and challenge-window edges exactly.
contract SoothInvariantsTest is StdInvariant, Test {
    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant LIQUIDITY = 100e6;
    uint256 internal constant BOND = 10e6;
    uint256 internal constant SEED_BUY = 20e6;
    uint64 internal constant WINDOW = 2 hours;
    uint256 internal constant EOA_MARKETS = 2;
    uint256 internal constant MARKETS = 4;
    /// @dev `_books` is the third storage slot of OutcomeOrderBook (`forge inspect OutcomeOrderBook storageLayout`).
    uint256 internal constant BOOKS_SLOT = 2;

    MockUSDC internal usdc;
    MarketFactory internal factory;
    IOutcomeToken internal token;
    OptimisticResolver internal resolver;
    OutcomeOrderBook internal book;
    Clock internal clock;
    MarketHandler internal mh;
    ResolverHandler internal rh;
    IMarket[] internal markets;
    address[] internal actors;

    address internal admin = makeAddr("admin");
    address internal arbitrator = makeAddr("arbitrator");
    address internal judge = makeAddr("judge");
    address internal whale = makeAddr("whale");
    address internal donor = makeAddr("donor");

    function setUp() public {
        vm.warp(START);
        usdc = new MockUSDC();
        factory = new MarketFactory(admin, address(usdc));
        token = factory.outcomeToken();
        resolver = new OptimisticResolver(judge, factory, BOND, WINDOW);
        book = new OutcomeOrderBook(factory);
        clock = new Clock(START);

        // Staggered closes so markets settle at different times in one sequence.
        markets.push(_create(arbitrator, 1 days));
        markets.push(_create(arbitrator, 4 days));
        markets.push(_create(address(resolver), 1 days));
        markets.push(_create(address(resolver), 3 days));

        string[5] memory names = ["alice", "bob", "carol", "dave", "erin"];
        for (uint256 k; k < names.length; ++k) {
            actors.push(makeAddr(names[k]));
            _approveAll(actors[k]);
        }
        _approveAll(whale);

        mh = new MarketHandler(
            usdc, token, clock, markets, actors, book, arbitrator, whale, donor, EOA_MARKETS, LIQUIDITY
        );
        rh = new ResolverHandler(usdc, token, clock, markets, actors, resolver, judge, donor, EOA_MARKETS);

        // Every trader starts with both sides of every market, bought through the handler so the ghosts
        // record it. Without this, early listings and sells are mostly no-ops.
        for (uint256 k; k < actors.length; ++k) {
            for (uint256 i; i < MARKETS; ++i) {
                mh.buy(k, i, 0, SEED_BUY);
                mh.buy(k, i, 1, SEED_BUY);
            }
        }

        targetContract(address(mh));
        targetContract(address(rh));

        // A selector listed twice is called about twice as often (seen in the call table).
        bytes4[] memory m = new bytes4[](24);
        m[0] = MarketHandler.buy.selector;
        m[1] = MarketHandler.buy.selector;
        m[2] = MarketHandler.sell.selector;
        m[3] = MarketHandler.sell.selector;
        m[4] = MarketHandler.roundTrip.selector;
        m[5] = MarketHandler.list.selector;
        m[6] = MarketHandler.list.selector;
        m[7] = MarketHandler.list.selector;
        m[8] = MarketHandler.bookBuy.selector;
        m[9] = MarketHandler.bookBuy.selector;
        m[10] = MarketHandler.bookBuy.selector;
        m[11] = MarketHandler.cancel.selector;
        m[12] = MarketHandler.transferShares.selector;
        m[13] = MarketHandler.donateCollateral.selector;
        m[14] = MarketHandler.donateShares.selector;
        m[15] = MarketHandler.bulkDonateShares.selector;
        m[16] = MarketHandler.warp.selector;
        m[17] = MarketHandler.warpToEdge.selector;
        m[18] = MarketHandler.resolve.selector;
        m[19] = MarketHandler.resolve.selector;
        m[20] = MarketHandler.redeem.selector;
        m[21] = MarketHandler.redeem.selector;
        m[22] = MarketHandler.withdrawLiquidity.selector;
        m[23] = MarketHandler.withdrawFees.selector;
        targetSelector(FuzzSelector({addr: address(mh), selectors: m}));

        bytes4[] memory r = new bytes4[](11);
        r[0] = ResolverHandler.propose.selector;
        r[1] = ResolverHandler.propose.selector;
        r[2] = ResolverHandler.dispute.selector;
        r[3] = ResolverHandler.dispute.selector;
        r[4] = ResolverHandler.finalize.selector;
        r[5] = ResolverHandler.rule.selector;
        r[6] = ResolverHandler.rule.selector;
        r[7] = ResolverHandler.refund.selector;
        r[8] = ResolverHandler.donate.selector;
        r[9] = ResolverHandler.warpInWindow.selector;
        r[10] = ResolverHandler.warpToEdge.selector;
        targetSelector(FuzzSelector({addr: address(rh), selectors: r}));
    }

    function _create(address arbiter, uint256 closeIn) internal returns (IMarket) {
        usdc.mint(admin, LIQUIDITY);
        vm.startPrank(admin);
        usdc.approve(address(factory), LIQUIDITY);
        (, address created) = factory.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: arbiter,
                closeTime: uint64(block.timestamp + closeIn),
                initialYesProbabilityBps: 5_000,
                spec: "Will it happen?",
                initialLiquidity: LIQUIDITY
            })
        );
        vm.stopPrank();
        return IMarket(created);
    }

    function _approveAll(address account) internal {
        vm.startPrank(account);
        for (uint256 i; i < markets.length; ++i) {
            usdc.approve(address(markets[i]), type(uint256).max);
            token.setApprovalForAll(address(markets[i]), true);
        }
        usdc.approve(address(book), type(uint256).max);
        usdc.approve(address(resolver), type(uint256).max);
        token.setApprovalForAll(address(book), true);
        vm.stopPrank();
    }

    modifier synced() {
        vm.warp(clock.time());
        _;
    }

    // ------------------------------------------------------------------ collateral

    function invariant_COL_1_yesSupplyEqualsNoSupplyBeforeExits() public synced {
        for (uint256 i; i < MARKETS; ++i) {
            if (mh.exits(i) != 0) continue;
            IMarket m = markets[i];
            assertEq(token.totalSupply(m.yesTokenId()), token.totalSupply(m.noTokenId()), "YES supply == NO supply");
        }
    }

    function invariant_COL_2_backingMatchesSupplyBeforeSettlement() public synced {
        for (uint256 i; i < MARKETS; ++i) {
            if (mh.exits(i) != 0) continue;
            IMarket m = markets[i];
            uint256 backing = usdc.balanceOf(address(m)) - m.accruedFees();
            uint256 supply = token.totalSupply(m.yesTokenId());
            assertEq(backing, supply + mh.donatedCollateral(i), "backing == supply + donations");
            assertGe(backing, supply, "backing >= supply");
        }
    }

    function invariant_COL_3_feesAccountedApartFromBacking() public synced {
        for (uint256 i; i < MARKETS; ++i) {
            assertEq(
                markets[i].accruedFees(), mh.feesExpected(i) - mh.feesWithdrawn(i), "accruedFees == fees - withdrawn"
            );
        }
        assertEq(mh.feeMismatches(), 0, "a trade's fee was not ceil(1%) or minted shares");
        assertEq(mh.feeWithdrawnWhileOpen(), 0, "fees withdrawn while Open");
    }

    function invariant_COL_5_inventoryMatchesPools() public synced {
        for (uint256 i; i < MARKETS; ++i) {
            IMarket m = markets[i];
            uint256 yesHeld = token.balanceOf(address(m), m.yesTokenId());
            uint256 noHeld = token.balanceOf(address(m), m.noTokenId());
            if (m.liquidityWithdrawn()) {
                assertEq(yesHeld, mh.donatedYes(i), "after withdrawal only donated YES remain");
                assertEq(noHeld, mh.donatedNo(i), "after withdrawal only donated NO remain");
            } else {
                assertEq(yesHeld, m.yesPool() + mh.donatedYes(i), "YES held == yesPool + donated");
                assertEq(noHeld, m.noPool() + mh.donatedNo(i), "NO held == noPool + donated");
            }
            assertGt(m.yesPool(), 0, "yesPool > 0");
            assertGt(m.noPool(), 0, "noPool > 0");
        }
    }

    function invariant_COL_6_productNeverFallsAndRoundTripNeverProfits() public view {
        assertEq(mh.productDecreases(), 0, "a trade lowered yesPool * noPool");
        assertEq(mh.roundTripProfits(), 0, "buy then sell returned more than paid");
    }

    // ------------------------------------------------------------------ time

    function invariant_TIME_2_tradingOnlyWhileOpen() public view {
        assertEq(mh.tradesOutsideOpen(), 0, "AMM or book trade succeeded outside Open");
    }

    // ------------------------------------------------------------------ resolution

    function invariant_RES_1_resolvedAtMostOnce() public synced {
        for (uint256 i; i < MARKETS; ++i) {
            uint256 n = _resolves(i);
            assertLe(n, 1, "resolved more than once");
            assertEq(n == 1, markets[i].state() == IMarket.State.Resolved, "Resolved iff one resolve");
        }
        assertEq(mh.resolvesOutsideClosed(), 0, "resolve succeeded outside Closed");
    }

    function invariant_RES_2_winningOutcomeNeverChanges() public synced {
        for (uint256 i; i < MARKETS; ++i) {
            if (_resolves(i) == 0) continue;
            IMarket.Outcome first = i < EOA_MARKETS ? mh.firstOutcome(i) : rh.firstOutcome(i);
            assertEq(uint8(markets[i].state()), uint8(IMarket.State.Resolved), "Resolved sticks");
            assertEq(uint8(markets[i].winningOutcome()), uint8(first), "winningOutcome unchanged");
        }
    }

    // ------------------------------------------------------------------ redemption

    function invariant_RED_1_payoutsNeverExceedReceipts() public synced {
        for (uint256 i; i < MARKETS; ++i) {
            IMarket m = markets[i];
            uint256 received = mh.deposited(i) + mh.donatedCollateral(i);
            uint256 balance = usdc.balanceOf(address(m));
            assertLe(mh.paidOut(i), received, "paid out more than received");
            assertEq(balance + mh.paidOut(i), received, "balance == received - paid");

            uint256 backing = balance - m.accruedFees() - mh.donatedCollateral(i);
            uint256 supplyYes = token.totalSupply(m.yesTokenId());
            uint256 supplyNo = token.totalSupply(m.noTokenId());
            IMarket.State st = m.state();
            if (st == IMarket.State.Resolved) {
                uint256 winning = m.winningOutcome() == IMarket.Outcome.Yes ? supplyYes : supplyNo;
                assertEq(backing, winning, "Resolved: backing == winning supply");
            } else if (st == IMarket.State.Cancelled) {
                assertGe(2 * backing, supplyYes + supplyNo, "Cancelled: solvent");
                assertLe(
                    2 * backing - (supplyYes + supplyNo), mh.cancelledExits(i), "Cancelled: <= half a unit per exit"
                );
            }
        }
    }

    function invariant_RED_2_redeemPaysOnePerWinningShare() public view {
        assertEq(mh.redeemMismatches(), 0, "Resolved redeem paid other than the winning balance");
        assertEq(
            mh.liquidityPayoutMismatches(), 0, "withdrawLiquidity paid other than the settlement value of the pools"
        );
    }

    /// @dev INV-RED-3 is not in the P1-2 list; the redeem action checks it anyway.
    function invariant_RED_3_cancelledRedeemPaysHalf() public view {
        assertEq(mh.cancelledRedeemMismatches(), 0, "Cancelled redeem paid other than (yes + no) / 2");
    }

    function invariant_RED_4_noDoubleClaims() public view {
        assertEq(mh.doubleClaims(), 0, "second redeem or withdrawFees succeeded");
        for (uint256 i; i < MARKETS; ++i) {
            assertLe(mh.liquidityWithdrawals(i), 1, "withdrawLiquidity succeeded twice");
            assertEq(mh.liquidityWithdrawals(i) == 1, markets[i].liquidityWithdrawn(), "flag matches withdrawals");
        }
    }

    // ------------------------------------------------------------------ bonds

    function invariant_BND_1_resolverHoldsExactlyOpenBonds() public view {
        uint256 open;
        uint256 net;
        for (uint256 i = EOA_MARKETS; i < MARKETS; ++i) {
            IOptimisticResolver.Status s = resolver.requestOf(markets[i]).status;
            if (s == IOptimisticResolver.Status.Proposed) open += 1;
            else if (s == IOptimisticResolver.Status.Disputed) open += 2;
            net += rh.bondsIn(i) - rh.bondsOut(i);
        }
        uint256 balance = usdc.balanceOf(address(resolver));
        assertEq(balance, BOND * open + rh.donated(), "balance == bond * open bonds + donations");
        assertEq(net, BOND * open, "ghost pulls - pushes == open bonds");
        assertGe(balance, BOND * open, "balance >= open bonds");
        assertEq(rh.bondPullMismatches(), 0, "propose or dispute pulled other than one bond");
    }

    function invariant_BND_4_refundMakesEveryoneWhole() public view {
        assertEq(rh.refundMismatches(), 0, "refund paid wrong amounts or someone gained or lost");
    }

    function invariant_BND_5_eachBondPaidOnce() public view {
        for (uint256 i = EOA_MARKETS; i < MARKETS; ++i) {
            IOptimisticResolver.Status s = resolver.requestOf(markets[i]).status;
            assertLe(rh.bondsOut(i), rh.bondsIn(i), "paid out more bonds than pulled");
            if (s == IOptimisticResolver.Status.Settled) assertEq(rh.bondsOut(i), rh.bondsIn(i), "settled pays all");
            else assertEq(rh.bondsOut(i), 0, "nothing paid before settlement");
        }
        assertEq(rh.settledOnWrongStatus(), 0, "finalize, rule or refund succeeded on the wrong status");
        assertEq(rh.bondPayoutMismatches(), 0, "finalize or rule paid wrong amounts");
    }

    /// @dev Every funded request has a working exit right now, tried in a snapshot that is then dropped.
    function invariant_BND_7_openBondsAlwaysHaveAnExit() public synced {
        for (uint256 i = EOA_MARKETS; i < MARKETS; ++i) {
            IMarket m = markets[i];
            IOptimisticResolver.Request memory r = resolver.requestOf(m);
            if (r.status != IOptimisticResolver.Status.Proposed && r.status != IOptimisticResolver.Status.Disputed) {
                continue;
            }
            IMarket.State st = m.state();
            assertTrue(st == IMarket.State.Closed || st == IMarket.State.Cancelled, "open request on Closed/Cancelled");
            uint256 snap = vm.snapshotState();
            bool ok = true;
            if (st == IMarket.State.Cancelled) {
                try resolver.refund(m) {}
                catch {
                    ok = false;
                }
            } else if (r.status == IOptimisticResolver.Status.Disputed) {
                vm.prank(judge);
                try resolver.rule(m, IMarket.Outcome.Yes) {}
                catch {
                    ok = false;
                }
            } else if (vm.getBlockTimestamp() >= r.proposedAt + WINDOW) {
                try resolver.finalize(m) {}
                catch {
                    ok = false;
                }
            } else {
                // Window still open: it must end before the deadline, so finalize will be possible.
                ok = r.proposedAt + WINDOW < m.resolutionDeadline();
            }
            vm.revertToState(snap);
            assertTrue(ok, "an open request has no working exit");
        }
    }

    // ------------------------------------------------------------------ order book

    function invariant_OB_1_escrowEqualsOpenListings() public view {
        uint256 count = book.listingCount();
        for (uint256 i; i < MARKETS; ++i) {
            for (uint256 o; o < 2; ++o) {
                IMarket.Outcome outcome = IMarket.Outcome(o);
                uint256 sum;
                for (uint256 id = 1; id <= count; ++id) {
                    IOutcomeOrderBook.Listing memory l = book.getListing(id);
                    if (l.remaining > 0 && l.market == markets[i] && l.outcome == outcome) sum += l.remaining;
                }
                assertEq(token.balanceOf(address(book), _tokenId(markets[i], outcome)), sum, "escrow == open listings");
            }
        }
        assertEq(mh.cancelMismatches(), 0, "cancel returned the wrong amount or failed");
    }

    function invariant_OB_2_booksSortedFifoAndLinked() public view {
        for (uint256 i; i < MARKETS; ++i) {
            _checkBook(markets[i], IMarket.Outcome.Yes);
            _checkBook(markets[i], IMarket.Outcome.No);
        }
    }

    function invariant_OB_3_bookHoldsNoCollateral() public view {
        assertEq(usdc.balanceOf(address(book)), 0, "book holds collateral");
    }

    function invariant_OB_4_buyersPayExactlyWhatSellersReceive() public view {
        assertEq(mh.bookPaid(), mh.bookReceived(), "buyers' payments == sellers' receipts");
        assertEq(mh.bookModelMismatches(), 0, "a fill differed from the cheapest-first FIFO ceil-cost model");
    }

    function _checkBook(IMarket market, IMarket.Outcome outcome) internal view {
        (uint256 head, uint256 tail) = _ends(market, outcome);
        uint256[] memory ids = book.listingsOf(market, outcome, 0, type(uint256).max);
        assertEq(head, ids.length == 0 ? 0 : ids[0], "head is the first listing");
        assertEq(tail, ids.length == 0 ? 0 : ids[ids.length - 1], "tail is the last listing");
        assertEq(book.bestPrice(market, outcome), ids.length == 0 ? 0 : book.getListing(ids[0]).price, "best price");
        uint256 prevId;
        uint256 prevPrice;
        for (uint256 k; k < ids.length; ++k) {
            IOutcomeOrderBook.Listing memory l = book.getListing(ids[k]);
            assertGt(l.remaining, 0, "linked means open");
            assertEq(address(l.market), address(market), "right market");
            assertEq(uint8(l.outcome), uint8(outcome), "right outcome");
            assertEq(l.prev, prevId, "back link");
            if (k > 0) {
                assertLe(prevPrice, l.price, "sorted ascending");
                if (prevPrice == l.price) assertLt(prevId, ids[k], "FIFO at equal price");
            }
            assertEq(l.next, k + 1 < ids.length ? ids[k + 1] : 0, "forward link");
            prevId = ids[k];
            prevPrice = l.price;
        }
        uint256 open;
        uint256 count = book.listingCount();
        for (uint256 id = 1; id <= count; ++id) {
            IOutcomeOrderBook.Listing memory l = book.getListing(id);
            if (l.remaining > 0 && l.market == market && l.outcome == outcome) ++open;
            if (l.remaining == 0) assertTrue(l.prev == 0 && l.next == 0, "closed listing is unlinked");
        }
        assertEq(open, ids.length, "every open listing is in its book");
    }

    /// @dev Reads `_books[market][outcome]` (head, tail) straight from storage; the contract exposes no getter.
    function _ends(IMarket market, IMarket.Outcome outcome) internal view returns (uint256 head, uint256 tail) {
        bytes32 inner = keccak256(abi.encode(address(market), BOOKS_SLOT));
        bytes32 slot = keccak256(abi.encode(uint256(outcome), inner));
        head = uint256(vm.load(address(book), slot));
        tail = uint256(vm.load(address(book), bytes32(uint256(slot) + 1)));
    }

    // ------------------------------------------------------------------ end of run

    /// @dev INV-RED-1 "after everyone exits" and INV-BND-7 "no bond is stuck": run past every deadline,
    ///      settle every open request, cancel every listing, and let every holder and the creator exit.
    function afterInvariant() public synced {
        uint256 endResolved;
        uint256 endCancelled;
        for (uint256 i; i < MARKETS; ++i) {
            IMarket.State st = markets[i].state();
            if (st == IMarket.State.Resolved) ++endResolved;
            else if (st == IMarket.State.Cancelled) ++endCancelled;
        }
        uint256 end;
        for (uint256 i; i < MARKETS; ++i) {
            uint256 d = markets[i].resolutionDeadline();
            if (d > end) end = d;
        }
        if (vm.getBlockTimestamp() < end) vm.warp(end);

        for (uint256 i = EOA_MARKETS; i < MARKETS; ++i) {
            IOptimisticResolver.Status s = resolver.requestOf(markets[i]).status;
            if (s == IOptimisticResolver.Status.Proposed || s == IOptimisticResolver.Status.Disputed) {
                resolver.refund(markets[i]);
            }
        }
        assertEq(usdc.balanceOf(address(resolver)), rh.donated(), "no bond left in the resolver");

        uint256 count = book.listingCount();
        for (uint256 id = 1; id <= count; ++id) {
            IOutcomeOrderBook.Listing memory l = book.getListing(id);
            if (l.remaining == 0) continue;
            vm.prank(l.seller);
            book.cancel(id);
        }

        address[] memory h = mh.holders();
        for (uint256 i; i < MARKETS; ++i) {
            _exitAll(i, h);
        }
        _summary(endResolved, endCancelled);
    }

    function _exitAll(uint256 i, address[] memory h) internal {
        IMarket m = markets[i];
        bool cancelled = m.state() == IMarket.State.Cancelled;
        uint256 exitsNow;
        for (uint256 k; k < h.length; ++k) {
            uint256 y = token.balanceOf(h[k], m.yesTokenId());
            uint256 n = token.balanceOf(h[k], m.noTokenId());
            uint256 value = cancelled ? (y + n) / 2 : (m.winningOutcome() == IMarket.Outcome.Yes ? y : n);
            if (value == 0) continue;
            vm.prank(h[k]);
            assertEq(m.redeem(), value, "exit pays the settlement value");
            ++exitsNow;
        }
        if (!m.liquidityWithdrawn()) {
            m.withdrawLiquidity();
            ++exitsNow;
        }
        if (m.accruedFees() > 0) m.withdrawFees();

        uint256 left = usdc.balanceOf(address(m));
        uint256 donatedCol = mh.donatedCollateral(i);
        uint256 supplyYes = token.totalSupply(m.yesTokenId());
        uint256 supplyNo = token.totalSupply(m.noTokenId());
        assertGe(left, donatedCol, "donations stay");
        if (cancelled) {
            uint256 dust2 = 2 * (left - donatedCol);
            // Unredeemable remainders: donated shares and holders' single leftover units.
            assertGe(dust2, supplyYes + supplyNo, "Cancelled: every remaining share is still backed");
            assertLe(
                dust2 - (supplyYes + supplyNo),
                mh.cancelledExits(i) + exitsNow,
                "Cancelled: dust <= half a unit per exit"
            );
        } else {
            bool yesWon = m.winningOutcome() == IMarket.Outcome.Yes;
            uint256 winning = yesWon ? supplyYes : supplyNo;
            assertEq(winning, yesWon ? mh.donatedYes(i) : mh.donatedNo(i), "Resolved: only donated winners remain");
            assertEq(left, donatedCol + winning, "Resolved: nothing left but donations");
        }
    }

    /// @dev SOOTH_INVARIANT_SUMMARY=true: sums reach counters over all runs in process env vars and logs
    ///      the running totals, so the last run's log shows totals for the whole campaign. Seed buys from
    ///      setUp (2 per trader per market) are included in "buy".
    function _summary(uint256 endResolved, uint256 endCancelled) internal {
        if (!vm.envOr("SOOTH_INVARIANT_SUMMARY", false)) return;
        string[13] memory mk = [
            "buy",
            "sell",
            "roundTrip",
            "list",
            "bookBuy",
            "cancel",
            "resolve",
            "redeem",
            "withdrawLiquidity",
            "withdrawFees",
            "bulkDonate",
            "transfer",
            "donateCollateral"
        ];
        for (uint256 k; k < mk.length; ++k) {
            console.log(mk[k], _total(string.concat("SOOTH_MH_", mk[k]), mh.calls(bytes32(bytes(mk[k])))));
        }
        string[6] memory rk = ["propose", "dispute", "finalize", "rule", "refund", "donate"];
        for (uint256 k; k < rk.length; ++k) {
            console.log(rk[k], _total(string.concat("SOOTH_RH_", rk[k]), rh.calls(bytes32(bytes(rk[k])))));
        }
        console.log("markets Resolved before the final warp", _total("SOOTH_END_RESOLVED", endResolved));
        console.log("markets Cancelled before the final warp", _total("SOOTH_END_CANCELLED", endCancelled));
        console.log("runs", _total("SOOTH_RUNS", 1));
    }

    function _total(string memory key, uint256 add) internal returns (uint256 total) {
        total = vm.envOr(key, uint256(0)) + add;
        vm.setEnv(key, vm.toString(total));
    }

    function _resolves(uint256 i) internal view returns (uint256) {
        return i < EOA_MARKETS ? mh.resolves(i) : rh.resolves(i);
    }

    function _tokenId(IMarket market, IMarket.Outcome outcome) internal view returns (uint256) {
        return outcome == IMarket.Outcome.Yes ? market.yesTokenId() : market.noTokenId();
    }
}
