// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOutcomeToken} from "./IOutcomeToken.sol";

/// @title IMarket
/// @notice A single binary (YES/NO) prediction market. Each market is an EIP-1167 clone
///         deployed and initialized by MarketFactory in one transaction.
interface IMarket {
    /// @dev `Closed` is never stored. It is derived from `closeTime` in `state()`, so no
    ///      transaction is needed to close a market.
    enum State {
        Open,
        Closed,
        Proposed,
        Resolved,
        Cancelled
    }

    enum Outcome {
        Yes,
        No
    }

    struct InitParams {
        uint256 marketId;
        address creator;
        address arbitrator;
        uint64 closeTime;
        bytes32 specHash;
        uint256 initialLiquidity;
    }

    error NotFactory(address caller);
    error CollateralNotReceived(uint256 expected, uint256 actual);
    error InitialInventoryMismatch(uint256 yesBalance, uint256 noBalance, uint256 expected);
    error TradingClosed(State currentState);
    error TradingStillOpen();
    error NoFeesToWithdraw();
    error ZeroAmount();
    error ZeroOutput();
    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error InsufficientOutput(uint256 actual, uint256 minimum);

    /// @notice Called once, only by the factory, right after cloning. Mints the seed YES/NO
    ///         pairs into the pool; the factory must have transferred `initialLiquidity` first.
    function initialize(InitParams calldata p) external;

    /// @notice Current lifecycle state, with `Closed` derived from `closeTime`.
    function state() external view returns (State);

    /// @notice Implied probability of YES, 18 decimals: noPool / (yesPool + noPool).
    function priceYes() external view returns (uint256);

    /// @notice Implied probability of NO, 18 decimals: yesPool / (yesPool + noPool).
    function priceNo() external view returns (uint256);

    function quoteBuy(Outcome outcome, uint256 collateralIn) external view returns (uint256 sharesOut, uint256 fee);

    function quoteSell(Outcome outcome, uint256 sharesIn) external view returns (uint256 collateralOut, uint256 fee);

    function buy(Outcome outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline)
        external
        returns (uint256 sharesOut);

    function sell(Outcome outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline)
        external
        returns (uint256 collateralOut);

    function factory() external view returns (address);
    function marketId() external view returns (uint256);
    function outcomeToken() external view returns (IOutcomeToken);
    function creator() external view returns (address);
    function arbitrator() external view returns (address);
    function collateral() external view returns (IERC20);
    function closeTime() external view returns (uint64);
    /// @notice closeTime + RESOLUTION_WINDOW. After this, an unresolved market can be cancelled.
    function resolutionDeadline() external view returns (uint64);
    function FEE_BPS() external view returns (uint16);
    function RESOLUTION_WINDOW() external view returns (uint64);
    function specHash() external view returns (bytes32);
    function yesTokenId() external view returns (uint256);
    function noTokenId() external view returns (uint256);
    function yesPool() external view returns (uint256);
    function noPool() external view returns (uint256);
    function accruedFees() external view returns (uint256);

    /// @notice Anyone may trigger withdrawal once trading ends; fees are always sent to creator.
    /// @dev Withdraws only accrued fees, never pool backing or unsolicited collateral donations.
    function withdrawFees() external returns (uint256 amount);

    event Bought(address indexed trader, Outcome indexed outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee);
    event Sold(address indexed trader, Outcome indexed outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
}
