// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IOptimisticResolver} from "./interfaces/IOptimisticResolver.sol";

/// @title OptimisticResolver
/// @notice Arbitrator for markets without a price feed. A bonded proposal stands unless disputed within
///         the challenge window; disputes go to the owner, who acts as judge.
/// @dev shortcut: bonds are pushed, so a recipient blocked by the token (USDC blacklist) makes that
///      settlement revert; switch to pull payments before using real USDC.
contract OptimisticResolver is Ownable2Step, ReentrancyGuardTransient, IOptimisticResolver {
    using SafeERC20 for IERC20;

    IMarketFactory public immutable factory;
    IERC20 public immutable bondToken;
    uint256 public immutable bond;
    uint64 public immutable challengeWindow;

    mapping(IMarket market => Request) internal _requests;

    constructor(address judge, IMarketFactory factory_, uint256 bond_, uint64 challengeWindow_) Ownable(judge) {
        if (address(factory_) == address(0) || bond_ == 0 || challengeWindow_ == 0) revert InvalidConfig();
        // A window as long as the market's resolution window would leave no time to propose.
        if (challengeWindow_ >= IMarket(factory_.implementation()).RESOLUTION_WINDOW()) revert InvalidConfig();

        factory = factory_;
        bondToken = factory_.collateral();
        bond = bond_;
        challengeWindow = challengeWindow_;
    }

    function propose(IMarket market, IMarket.Outcome outcome, string calldata evidenceURI) external nonReentrant {
        _requireOwnMarket(market);
        IMarket.State marketState = market.state();
        if (marketState != IMarket.State.Closed) revert MarketNotClosed(marketState);
        Status status = _requests[market].status;
        if (status != Status.None) revert WrongStatus(status);
        // Strict: at the deadline the market is already Cancelled, so finalize would fail.
        uint256 windowEnd = block.timestamp + challengeWindow;
        uint64 deadline = market.resolutionDeadline();
        if (windowEnd >= deadline) revert ProposalTooLate(windowEnd, deadline);

        _requests[market] = Request({
            proposer: msg.sender,
            outcome: outcome,
            status: Status.Proposed,
            proposedAt: uint64(block.timestamp),
            disputer: address(0)
        });
        bondToken.safeTransferFrom(msg.sender, address(this), bond);
        emit Proposed(market, msg.sender, outcome, evidenceURI);
    }

    function dispute(IMarket market, string calldata evidenceURI) external nonReentrant {
        Request storage request = _requests[market];
        if (request.status != Status.Proposed) revert WrongStatus(request.status);
        uint256 windowEnd = _windowEnd(request);
        if (block.timestamp >= windowEnd) revert ChallengeWindowClosed(windowEnd);

        request.status = Status.Disputed;
        request.disputer = msg.sender;
        bondToken.safeTransferFrom(msg.sender, address(this), bond);
        emit Disputed(market, msg.sender, evidenceURI);
    }

    function finalize(IMarket market) external nonReentrant {
        Request storage request = _requests[market];
        if (request.status != Status.Proposed) revert WrongStatus(request.status);
        uint256 windowEnd = _windowEnd(request);
        if (block.timestamp < windowEnd) revert ChallengeWindowOpen(windowEnd);

        request.status = Status.Settled;
        market.resolve(request.outcome);
        bondToken.safeTransfer(request.proposer, bond);
        emit Finalized(market, request.outcome);
    }

    function rule(IMarket market, IMarket.Outcome outcome) external onlyOwner nonReentrant {
        Request storage request = _requests[market];
        if (request.status != Status.Disputed) revert WrongStatus(request.status);

        request.status = Status.Settled;
        address winner = outcome == request.outcome ? request.proposer : request.disputer;
        market.resolve(outcome);
        bondToken.safeTransfer(winner, 2 * bond);
        emit Ruled(market, outcome, winner);
    }

    function refund(IMarket market) external nonReentrant {
        Request storage request = _requests[market];
        Status status = request.status;
        if (status != Status.Proposed && status != Status.Disputed) revert WrongStatus(status);
        IMarket.State marketState = market.state();
        if (marketState != IMarket.State.Cancelled) revert MarketNotCancelled(marketState);

        request.status = Status.Settled;
        bondToken.safeTransfer(request.proposer, bond);
        if (status == Status.Disputed) bondToken.safeTransfer(request.disputer, bond);
        emit Refunded(market);
    }

    function requestOf(IMarket market) external view returns (Request memory) {
        return _requests[market];
    }

    function _requireOwnMarket(IMarket market) internal view {
        if (factory.markets(market.marketId()) != address(market)) revert NotFactoryMarket(market);
        if (market.arbitrator() != address(this)) revert MarketNotUsingResolver(market);
    }

    function _windowEnd(Request storage request) internal view returns (uint256) {
        return request.proposedAt + challengeWindow;
    }
}
