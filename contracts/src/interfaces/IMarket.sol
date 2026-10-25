// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOutcomeToken} from "./IOutcomeToken.sol";

/// @title IMarket
/// @notice A single binary (YES/NO) prediction market. Each market is an EIP-1167 clone
///         deployed and initialized by MarketFactory in one transaction.
/// @dev Amounts are raw collateral units: 1e6 is one USDC or one whole outcome share.
interface IMarket {
    /// @dev `Closed` is never stored. It is derived from `closeTime` in `state()`, so no
    ///      transaction is needed to close a market. Likewise, an unresolved market reports
    ///      `Cancelled` once `resolutionDeadline` passes. `Proposed` is unused until phase 2.
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

    /// @dev Final result set by the arbitrator. Kept apart from `Outcome` so `Invalid` can
    ///      never be traded or turned into a token ID. `Invalid` cancels the market.
    enum Resolution {
        Yes,
        No,
        Invalid
    }

    struct InitParams {
        uint256 marketId;
        address creator;
        address arbitrator;
        uint64 closeTime;
        bytes32 specHash;
        uint256 initialLiquidity;
    }

    event Bought(address indexed trader, Outcome indexed outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee);
    event Sold(address indexed trader, Outcome indexed outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event MarketResolved(Resolution indexed resolution, address indexed arbitrator);
    event MarketCancelled();
    event Redeemed(address indexed account, uint256 yesAmount, uint256 noAmount, uint256 payout);
    event LiquidityClaimed(address indexed recipient, uint256 yesAmount, uint256 noAmount, uint256 payout);

    error NotFactory(address caller);
    error CollateralNotReceived(uint256 expected, uint256 actual);
    error TradingClosed(State currentState);
    error TradingStillOpen();
    error NoFeesToWithdraw();
    error ZeroAmount();
    error ZeroOutput();
    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error InsufficientOutput(uint256 actual, uint256 minimum);
    error NotArbitrator(address caller);
    error NotClosed(State currentState);
    error NotFinal(State currentState);
    error NothingToFinalize(State currentState);
    error NothingToClaim();

    /// @notice Called once, only by the factory, right after cloning. Mints the seed YES/NO
    ///         pairs into the pool; the factory must have transferred `initialLiquidity` first.
    function initialize(InitParams calldata p) external;

    /// @notice Spends `collateralIn` (fee included) on `outcome` shares. The caller must first
    ///         approve this market for `collateralIn` on the collateral token.
    ///         Reverts if fewer than `minSharesOut` come out or `deadline` has passed.
    function buy(Outcome outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline)
        external
        returns (uint256 sharesOut);

    /// @notice Sells `sharesIn` of `outcome` for collateral (fee deducted). The caller must first
    ///         call `setApprovalForAll(market, true)` on the outcome token.
    ///         Reverts if less than `minCollateralOut` comes out or `deadline` has passed.
    function sell(Outcome outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline)
        external
        returns (uint256 collateralOut);

    /// @notice Anyone may trigger withdrawal once trading ends; fees are always sent to creator.
    function withdrawFees() external returns (uint256 amount);

    /// @notice Arbitrator sets the final result, only while Closed (after closeTime, before
    ///         resolutionDeadline). Yes/No resolves the market; Invalid cancels it.
    /// @dev Phase 1 (direct resolution). A propose/challenge flow may replace this in phase 2.
    function resolve(Resolution resolution) external;

    /// @notice Stores a cancellation that is already in effect because nobody resolved before
    ///         resolutionDeadline, and emits MarketCancelled. Optional: redeem works without it.
    function finalize() external;

    /// @notice Burns the caller's YES and NO tokens and pays them out.
    ///         Resolved: 1 per winning token, 0 per losing token. Cancelled: 0.5 per token.
    function redeem(uint256 yesAmount, uint256 noAmount) external returns (uint256 payout);

    /// @notice Redeems every outcome token the market itself holds (the AMM pool) and pays
    ///         the result to `creator`. Anyone may call it once the market is final.
    function claimLiquidity() external returns (uint256 payout);

    /// @notice Implied probability of YES, 18 decimals: noPool / (yesPool + noPool).
    function priceYes() external view returns (uint256);

    /// @notice Implied probability of NO, 18 decimals: yesPool / (yesPool + noPool).
    function priceNo() external view returns (uint256);

    /// @notice closeTime + RESOLUTION_WINDOW. After this, an unresolved market can be cancelled.
    function resolutionDeadline() external view returns (uint64);

    /// @notice What `buy` would return now. Reverts once trading is closed.
    function quoteBuy(Outcome outcome, uint256 collateralIn) external view returns (uint256 sharesOut, uint256 fee);

    /// @notice What `sell` would return now. Reverts once trading is closed.
    function quoteSell(Outcome outcome, uint256 sharesIn) external view returns (uint256 collateralOut, uint256 fee);

    /// @notice What `redeem(yesAmount, noAmount)` would pay right now. Reverts unless final.
    function previewRedeem(uint256 yesAmount, uint256 noAmount) external view returns (uint256 payout);

    /// @notice The final result: Yes or No when Resolved, Invalid when Cancelled. Reverts unless final.
    function finalResolution() external view returns (Resolution);

    /// @notice Current lifecycle state, with `Closed` and timeout `Cancelled` derived from time.
    function state() external view returns (State);
    function factory() external view returns (address);
    function outcomeToken() external view returns (IOutcomeToken);
    function collateral() external view returns (IERC20);
    function FEE_BPS() external view returns (uint16);
    function RESOLUTION_WINDOW() external view returns (uint64);
    function marketId() external view returns (uint256);
    function creator() external view returns (address);
    function arbitrator() external view returns (address);
    function closeTime() external view returns (uint64);
    function specHash() external view returns (bytes32);
    function yesTokenId() external view returns (uint256);
    function noTokenId() external view returns (uint256);
    function yesPool() external view returns (uint256);
    function noPool() external view returns (uint256);
    function accruedFees() external view returns (uint256);
}
