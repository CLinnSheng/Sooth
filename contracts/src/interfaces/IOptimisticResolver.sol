// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket} from "./IMarket.sol";
import {IMarketFactory} from "./IMarketFactory.sol";

/// @title IOptimisticResolver
/// @notice Resolves markets by bonded proposal. Anyone proposes an outcome; if nobody disputes it within
///         the challenge window it stands, otherwise the owner (judge) rules. Bonds are in the factory's collateral.
interface IOptimisticResolver {
    enum Status {
        None,
        Proposed,
        Disputed,
        Settled
    }

    struct Request {
        address proposer;
        IMarket.Outcome outcome;
        Status status;
        uint64 proposedAt;
        address disputer;
    }

    event Proposed(IMarket indexed market, address indexed proposer, IMarket.Outcome outcome, string evidenceURI);
    event Disputed(IMarket indexed market, address indexed disputer, string evidenceURI);
    event Finalized(IMarket indexed market, IMarket.Outcome outcome);
    event Ruled(IMarket indexed market, IMarket.Outcome outcome, address indexed winner);
    event Refunded(IMarket indexed market);

    error InvalidConfig();
    error NotFactoryMarket(IMarket market);
    error MarketNotUsingResolver(IMarket market);
    error MarketNotClosed(IMarket.State currentState);
    error ProposalTooLate(uint256 windowEnd, uint64 resolutionDeadline);
    error WrongStatus(Status current);
    error ChallengeWindowOpen(uint256 windowEnd);
    error ChallengeWindowClosed(uint256 windowEnd);
    error MarketNotCancelled(IMarket.State currentState);

    /// @notice Anyone, while the market is Closed and has no request. Pulls `bond`; the caller must approve
    ///         it first. The window must end before the market's resolution deadline.
    function propose(IMarket market, IMarket.Outcome outcome, string calldata evidenceURI) external;

    /// @notice Anyone, during the challenge window. Pulls `bond` and hands the decision to the judge.
    function dispute(IMarket market, string calldata evidenceURI) external;

    /// @notice Anyone, after an undisputed window. Resolves the market and returns the proposer's bond.
    function finalize(IMarket market) external;

    /// @notice Judge only, on a disputed request. Resolves the market; the side that was right gets both bonds.
    function rule(IMarket market, IMarket.Outcome outcome) external;

    /// @notice Anyone, once the market is Cancelled with a request still open. Returns each bond to its owner.
    function refund(IMarket market) external;

    function factory() external view returns (IMarketFactory);
    function bondToken() external view returns (IERC20);
    function bond() external view returns (uint256);
    function challengeWindow() external view returns (uint64);
    function requestOf(IMarket market) external view returns (Request memory);
}
