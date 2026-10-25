// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal copy of Chainlink's AggregatorV3Interface, so the repo needs no Chainlink dependency.
/// @dev Source: smartcontractkit/chainlink contracts/src/v0.8/interfaces/AggregatorV3Interface.sol (MIT).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
