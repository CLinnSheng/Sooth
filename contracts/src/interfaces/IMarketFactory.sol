// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOutcomeToken} from "./IOutcomeToken.sol";

/// @title IMarketFactory
/// @notice Creates binary prediction markets as EIP-1167 clones. Creation is admin-only
///         for now (DEFAULT_ADMIN_ROLE), so there is no creator bond yet. Every market
///         uses the single collateral token fixed at deployment (USDC).
interface IMarketFactory {
    struct CreateParams {
        address arbitrator;
        /// @dev The only time input. The resolution deadline is derived from it in Market.
        uint64 closeTime;
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
        bytes32 specHash,
        string specCID,
        uint256 initialLiquidity
    );

    error InvalidConfig();
    error ZeroArbitrator();
    error CloseTimeInPast(uint64 closeTime, uint256 currentTime);
    error UnsupportedInitialProbability(uint16 initialYesProbabilityBps);
    error LiquidityTooLow(uint256 initialLiquidity, uint256 minLiquidity);
    error EmptySpecHash();
    error EmptySpecCID();

    /// @notice Creates a market and seeds it with `initialLiquidity` collateral from the caller.
    ///         The caller must first approve this factory for `initialLiquidity`.
    function createMarket(CreateParams calldata p) external returns (uint256 marketId, address market);

    function implementation() external view returns (address);
    function outcomeToken() external view returns (IOutcomeToken);
    function collateral() external view returns (IERC20);
    function MIN_LIQUIDITY() external view returns (uint256);
    function marketCount() external view returns (uint256);
    function markets(uint256 marketId) external view returns (address);
    function isMarket(address market) external view returns (bool);
}
