// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title MockAggregator
/// @notice Test-only Chainlink feed. Rounds are set by hand; unset rounds return zeros, like OCR aggregators.
contract MockAggregator is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 roundId => Round) internal _rounds;
    uint80 public latestRoundId;

    /// @dev The highest id set so far is the latest, so phase-2 ids (phase << 64) count as newer.
    function setRound(uint80 roundId, int256 answer, uint256 updatedAt) external {
        _rounds[roundId] = Round(answer, updatedAt);
        if (roundId > latestRoundId) latestRoundId = roundId;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "ETH / USD";
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory round = _rounds[roundId];
        return (roundId, round.answer, round.updatedAt, round.updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(latestRoundId);
    }
}
