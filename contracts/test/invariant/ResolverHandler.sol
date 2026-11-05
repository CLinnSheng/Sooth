// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HandlerBase, Clock} from "./HandlerBase.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {IMarket} from "../../src/interfaces/IMarket.sol";
import {IOutcomeToken} from "../../src/interfaces/IOutcomeToken.sol";
import {IOptimisticResolver} from "../../src/interfaces/IOptimisticResolver.sol";

/// @notice Drives propose, dispute, finalize, rule (judge), refund and challenge-window warps on the
///         markets `firstMarket ..` whose arbitrator is the OptimisticResolver. Ghosts are keyed by the
///         global market index, the same as in MarketHandler.
contract ResolverHandler is HandlerBase {
    string internal constant EVIDENCE = "ipfs://evidence";

    IOptimisticResolver public immutable resolver;
    address public immutable judge;
    address public immutable donor;
    uint256 public immutable firstMarket;
    uint256 public immutable bond;
    uint256 public immutable window;

    mapping(uint256 => uint256) public bondsIn; // collateral pulled by propose and dispute
    mapping(uint256 => uint256) public bondsOut; // collateral pushed by finalize, rule and refund
    mapping(uint256 => uint256) public resolves;
    mapping(uint256 => IMarket.Outcome) public firstOutcome;
    /// @dev Net bond flow of each address on each market's request: + paid to it, - pulled from it.
    uint256 public donated;

    // Violation counters: each must stay 0.
    uint256 public bondPullMismatches;
    uint256 public bondPayoutMismatches;
    uint256 public refundMismatches;
    uint256 public settledOnWrongStatus;

    mapping(bytes32 => uint256) public calls;

    struct Balances {
        uint256 proposer;
        uint256 disputer;
        uint256 resolver;
    }

    constructor(
        MockUSDC usdc_,
        IOutcomeToken token_,
        Clock clock_,
        IMarket[] memory markets_,
        address[] memory actors_,
        IOptimisticResolver resolver_,
        address judge_,
        address donor_,
        uint256 firstMarket_
    ) HandlerBase(usdc_, token_, clock_, markets_, actors_) {
        resolver = resolver_;
        judge = judge_;
        donor = donor_;
        firstMarket = firstMarket_;
        bond = resolver_.bond();
        window = resolver_.challengeWindow();
    }

    function _index(uint256 seed) internal view returns (uint256) {
        return firstMarket + seed % (_markets.length - firstMarket);
    }

    /// @dev Half the time the market the seed names, whatever its status (so wrong-status calls are tried);
    ///      otherwise the first market whose request has status `want` (or `alt`), if any.
    function _pick(uint256 seed, IOptimisticResolver.Status want, IOptimisticResolver.Status alt)
        internal
        view
        returns (uint256)
    {
        uint256 named = _index(seed >> 1);
        if (seed & 1 == 1) return named;
        for (uint256 k = firstMarket; k < _markets.length; ++k) {
            IOptimisticResolver.Status s = resolver.requestOf(_markets[k]).status;
            if (s == want || s == alt) return k;
        }
        return named;
    }

    function propose(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed) external synced {
        uint256 i = _pick(marketSeed, IOptimisticResolver.Status.None, IOptimisticResolver.Status.None);
        address actor = _actor(actorSeed);
        usdc.mint(actor, bond);
        uint256 before = usdc.balanceOf(address(resolver));
        vm.prank(actor);
        try resolver.propose(_markets[i], _outcome(outcomeSeed), EVIDENCE) {
            if (usdc.balanceOf(address(resolver)) != before + bond) ++bondPullMismatches;
            bondsIn[i] += bond;
            ++calls["propose"];
        } catch {}
    }

    function dispute(uint256 actorSeed, uint256 marketSeed) external synced {
        uint256 i = _pick(marketSeed, IOptimisticResolver.Status.Proposed, IOptimisticResolver.Status.Proposed);
        address actor = _actor(actorSeed);
        usdc.mint(actor, bond);
        uint256 before = usdc.balanceOf(address(resolver));
        vm.prank(actor);
        try resolver.dispute(_markets[i], EVIDENCE) {
            if (usdc.balanceOf(address(resolver)) != before + bond) ++bondPullMismatches;
            bondsIn[i] += bond;
            ++calls["dispute"];
        } catch {}
    }

    /// @dev Tried in every status; success on anything but an undisputed request is a violation.
    function finalize(uint256 callerSeed, uint256 marketSeed) external synced {
        uint256 i = _pick(marketSeed, IOptimisticResolver.Status.Proposed, IOptimisticResolver.Status.Proposed);
        IMarket market = _markets[i];
        IOptimisticResolver.Request memory r = resolver.requestOf(market);
        Balances memory b = _balances(r);
        vm.prank(_actor(callerSeed));
        try resolver.finalize(market) {
            if (r.status != IOptimisticResolver.Status.Proposed) ++settledOnWrongStatus;
            if (usdc.balanceOf(r.proposer) != b.proposer + bond) ++bondPayoutMismatches;
            if (usdc.balanceOf(address(resolver)) + bond != b.resolver) ++bondPayoutMismatches;
            bondsOut[i] += bond;
            _recordResolve(i, r.outcome);
            ++calls["finalize"];
        } catch {}
    }

    function rule(uint256 marketSeed, uint256 outcomeSeed) external synced {
        uint256 i = _pick(marketSeed, IOptimisticResolver.Status.Disputed, IOptimisticResolver.Status.Disputed);
        IMarket market = _markets[i];
        IMarket.Outcome outcome = _outcome(outcomeSeed);
        IOptimisticResolver.Request memory r = resolver.requestOf(market);
        Balances memory b = _balances(r);
        vm.prank(judge);
        try resolver.rule(market, outcome) {
            if (r.status != IOptimisticResolver.Status.Disputed) ++settledOnWrongStatus;
            address winner = outcome == r.outcome ? r.proposer : r.disputer;
            // The winner gets both bonds; the other side gets nothing (they may be the same address).
            uint256 wantProposer = b.proposer + (winner == r.proposer ? 2 * bond : 0);
            uint256 wantDisputer = b.disputer + (winner == r.disputer ? 2 * bond : 0);
            if (r.proposer == r.disputer) wantDisputer = wantProposer;
            if (usdc.balanceOf(r.proposer) != wantProposer || usdc.balanceOf(r.disputer) != wantDisputer) {
                ++bondPayoutMismatches;
            }
            if (usdc.balanceOf(address(resolver)) + 2 * bond != b.resolver) ++bondPayoutMismatches;
            bondsOut[i] += 2 * bond;
            _recordResolve(i, outcome);
            ++calls["rule"];
        } catch {}
    }

    function refund(uint256 callerSeed, uint256 marketSeed) external synced {
        uint256 i = _pick(marketSeed, IOptimisticResolver.Status.Proposed, IOptimisticResolver.Status.Disputed);
        IMarket market = _markets[i];
        IOptimisticResolver.Request memory r = resolver.requestOf(market);
        Balances memory b = _balances(r);
        bool disputed = r.status == IOptimisticResolver.Status.Disputed;
        vm.prank(_actor(callerSeed));
        try resolver.refund(market) {
            if (r.status != IOptimisticResolver.Status.Proposed && !disputed) ++settledOnWrongStatus;
            if (market.state() != IMarket.State.Cancelled) ++refundMismatches;
            uint256 wantProposer = b.proposer + bond;
            uint256 wantDisputer = disputed ? b.disputer + bond : b.disputer;
            if (disputed && r.proposer == r.disputer) {
                wantProposer = b.proposer + 2 * bond;
                wantDisputer = wantProposer;
            }
            if (usdc.balanceOf(r.proposer) != wantProposer) ++refundMismatches;
            if (disputed && usdc.balanceOf(r.disputer) != wantDisputer) ++refundMismatches;
            uint256 out = disputed ? 2 * bond : bond;
            if (usdc.balanceOf(address(resolver)) + out != b.resolver) ++refundMismatches;
            bondsOut[i] += out;
            ++calls["refund"];
        } catch {}
    }

    function donate(uint256 amount) external synced {
        amount = _bound(amount, 1, 20e6);
        usdc.mint(donor, amount);
        vm.prank(donor);
        usdc.transfer(address(resolver), amount);
        donated += amount;
        ++calls["donate"];
    }

    function warpInWindow(uint256 dt) external synced {
        _advanceTo(vm.getBlockTimestamp() + _bound(dt, 1, 2 * window));
        ++calls["warpInWindow"];
    }

    /// @dev Exact edges: window end and one second before it for a live proposal; otherwise close, the
    ///      last second a proposal fits (deadline - window - 1) and the first that does not. The deadline
    ///      itself is an edge of MarketHandler.warpToEdge.
    function warpToEdge(uint256 marketSeed, uint256 edgeSeed) external synced {
        IMarket market =
            _markets[_pick(marketSeed, IOptimisticResolver.Status.Proposed, IOptimisticResolver.Status.Disputed)];
        IOptimisticResolver.Request memory r = resolver.requestOf(market);
        uint256 t;
        if (r.status == IOptimisticResolver.Status.Proposed || r.status == IOptimisticResolver.Status.Disputed) {
            uint256 e = edgeSeed % 3;
            t = e == 2 ? market.resolutionDeadline() : r.proposedAt + window - e;
        } else {
            uint256 deadline = market.resolutionDeadline();
            uint256 e = edgeSeed % 4;
            t = e < 2 ? market.closeTime() : e == 2 ? deadline - window - 1 : deadline - window;
        }
        _advanceTo(t);
        ++calls["warpToEdge"];
    }

    function _recordResolve(uint256 i, IMarket.Outcome outcome) internal {
        if (++resolves[i] == 1) firstOutcome[i] = outcome;
    }

    function _balances(IOptimisticResolver.Request memory r) internal view returns (Balances memory b) {
        b.proposer = usdc.balanceOf(r.proposer);
        b.disputer = usdc.balanceOf(r.disputer);
        b.resolver = usdc.balanceOf(address(resolver));
    }
}
