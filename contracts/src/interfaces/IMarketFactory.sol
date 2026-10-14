// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOutcomeToken} from "./IOutcomeToken.sol";

/// @title IMarketFactory
/// @notice Creates binary prediction markets as EIP-1167 clones. Creation is admin-only
///         for now (MARKET_CREATOR_ROLE), so there is no creator bond yet.
interface IMarketFactory {
    struct CreateParams {
        address collateral;
        address arbitrator;
        uint64 closeTime;
        uint64 resolutionDeadline;
        uint16 feeBps;
        /// @dev Starting YES probability in basis points. Must be 5000 (50/50) for now;
        ///      kept in the interface so custom odds can be added without an ABI change.
        uint16 initialYesProbabilityBps;
        /// @dev keccak256 of the exact spec JSON bytes uploaded to IPFS.
        bytes32 specHash;
        /// @dev IPFS CID of the spec JSON. Emitted in MarketCreated, not stored.
        string specCID;
        uint256 initialLiquidity;
    }

    event MarketCreated(
        uint256 indexed marketId,
        address indexed market,
        address indexed creator,
        address arbitrator,
        address collateral,
        uint64 closeTime,
        uint64 resolutionDeadline,
        uint16 feeBps,
        bytes32 specHash,
        string specCID,
        uint256 initialLiquidity
    );

    event CollateralAllowed(address indexed token, bool allowed);

    error InvalidConfig();
    error CollateralNotAllowed(address token);
    error ZeroArbitrator();
    error CloseTimeTooSoon(uint64 closeTime, uint256 earliestAllowed);
    error InvalidResolutionDeadline(uint64 resolutionDeadline, uint64 closeTime);
    error FeeTooHigh(uint16 feeBps, uint16 maxFeeBps);
    error UnsupportedInitialProbability(uint16 initialYesProbabilityBps);
    error LiquidityTooLow(uint256 initialLiquidity, uint256 minLiquidity);
    error EmptySpecHash();
    error EmptySpecCID();

    /// @notice Creates a market and seeds it with `initialLiquidity` collateral from the caller.
    ///         The caller must first approve this factory for `initialLiquidity`.
    function createMarket(CreateParams calldata p) external returns (uint256 marketId, address market);

    function setCollateralAllowed(address token, bool allowed) external;

    function MARKET_CREATOR_ROLE() external view returns (bytes32);
    function implementation() external view returns (address);
    function outcomeToken() external view returns (IOutcomeToken);
    function minDuration() external view returns (uint64);
    function minLiquidity() external view returns (uint256);
    function maxFeeBps() external view returns (uint16);
    function marketCount() external view returns (uint256);
    function markets(uint256 marketId) external view returns (address);
    function isMarket(address market) external view returns (bool);
    function isCollateralAllowed(address token) external view returns (bool);
}
