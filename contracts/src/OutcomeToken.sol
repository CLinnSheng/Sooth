// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {IOutcomeToken} from "./interfaces/IOutcomeToken.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {OutcomeTokenId} from "./libraries/OutcomeTokenId.sol";

/// @title OutcomeToken
/// @notice One ERC-1155 for all markets. Each token ID can only be minted or burned by the
///         market it was registered to, so one market can never touch another market's tokens.
contract OutcomeToken is ERC1155Supply, IOutcomeToken {
    uint8 public constant SHARE_DECIMALS = 6;
    address public immutable factory;

    mapping(uint256 id => address market) public marketOf;

    modifier onlyMarketOf(uint256 id) {
        _checkMarketOf(id);
        _;
    }

    constructor(address factory_) ERC1155("") {
        factory = factory_;
    }

    function registerMarket(uint256 marketId, address market) external {
        if (msg.sender != factory) revert NotFactory(msg.sender);

        uint256 yesId = OutcomeTokenId.compute(marketId, IMarket.Outcome.Yes);
        uint256 noId = OutcomeTokenId.compute(marketId, IMarket.Outcome.No);
        if (marketOf[yesId] != address(0)) revert MarketAlreadyRegistered(marketId);

        marketOf[yesId] = market;
        marketOf[noId] = market;
        emit MarketRegistered(marketId, market, yesId, noId);
    }

    function mint(address to, uint256 id, uint256 amount) external onlyMarketOf(id) {
        _mint(to, id, amount, "");
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        for (uint256 i; i < ids.length; ++i) {
            _checkMarketOf(ids[i]);
        }
        _mintBatch(to, ids, amounts, "");
    }

    function burn(address from, uint256 id, uint256 amount) external onlyMarketOf(id) {
        _burn(from, id, amount);
    }

    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external {
        for (uint256 i; i < ids.length; ++i) {
            _checkMarketOf(ids[i]);
        }
        _burnBatch(from, ids, amounts);
    }

    function totalSupply(uint256 id) public view override(ERC1155Supply, IOutcomeToken) returns (uint256) {
        return super.totalSupply(id);
    }

    function _checkMarketOf(uint256 id) internal view {
        if (marketOf[id] != msg.sender) revert NotMarketForToken(msg.sender, id);
    }
}
