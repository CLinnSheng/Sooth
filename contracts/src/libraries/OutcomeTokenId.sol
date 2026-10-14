// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMarket} from "../interfaces/IMarket.sol";

/// @title OutcomeTokenId
/// @notice ERC-1155 token ID scheme shared by the factory, markets, tests and frontend.
library OutcomeTokenId {
    function compute(uint256 marketId, IMarket.Outcome outcome) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(marketId, outcome)));
    }
}
