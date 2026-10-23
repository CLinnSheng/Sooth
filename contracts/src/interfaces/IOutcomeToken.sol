// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title IOutcomeToken
/// @notice Shared ERC-1155 holding the YES/NO tokens of every market. Token IDs are
///         keccak256(abi.encode(marketId, outcome)) (see OutcomeTokenId).
/// @dev Shares use the collateral's raw units: 1e6 units is one whole share with six-decimal collateral.
interface IOutcomeToken is IERC1155 {
    error NotFactory(address caller);
    error NotMarketForToken(address caller, uint256 id);
    error MarketAlreadyRegistered(uint256 marketId);

    event MarketRegistered(uint256 indexed marketId, address indexed market, uint256 yesTokenId, uint256 noTokenId);

    /// @notice Links a market's YES/NO token IDs to its contract. Only the factory can call this.
    function registerMarket(uint256 marketId, address market) external;

    /// @notice Only the market that owns `id` can mint it.
    function mint(address to, uint256 id, uint256 amount) external;

    /// @notice Mints several token IDs in one call. Every ID must belong to the caller.
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external;

    /// @notice Only the market that owns `id` can burn it.
    function burn(address from, uint256 id, uint256 amount) external;

    /// @notice Burns several token IDs. Every ID must belong to the calling market.
    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external;

    function factory() external view returns (address);
    function marketOf(uint256 id) external view returns (address);
    function totalSupply(uint256 id) external view returns (uint256);
}
