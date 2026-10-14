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
        address collateral;
        uint64 closeTime;
        uint64 resolutionDeadline;
        uint16 feeBps;
        bytes32 specHash;
        uint256 initialLiquidity;
    }

    error NotFactory(address caller);
    error CollateralNotReceived(uint256 expected, uint256 actual);

    /// @notice Called once, only by the factory, right after cloning. Mints the seed YES/NO
    ///         pairs into the pool; the factory must have transferred `initialLiquidity` first.
    function initialize(InitParams calldata p) external;

    /// @notice Current lifecycle state, with `Closed` derived from `closeTime`.
    function state() external view returns (State);

    /// @notice Implied probability of YES, 18 decimals: noPool / (yesPool + noPool).
    function priceYes() external view returns (uint256);

    /// @notice Implied probability of NO, 18 decimals: yesPool / (yesPool + noPool).
    function priceNo() external view returns (uint256);

    function factory() external view returns (address);
    function marketId() external view returns (uint256);
    function outcomeToken() external view returns (IOutcomeToken);
    function creator() external view returns (address);
    function arbitrator() external view returns (address);
    function collateral() external view returns (IERC20);
    function closeTime() external view returns (uint64);
    function resolutionDeadline() external view returns (uint64);
    function feeBps() external view returns (uint16);
    function specHash() external view returns (bytes32);
    function yesTokenId() external view returns (uint256);
    function noTokenId() external view returns (uint256);
    function yesPool() external view returns (uint256);
    function noPool() external view returns (uint256);
}
