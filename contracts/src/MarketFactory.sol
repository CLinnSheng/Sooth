// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IOutcomeToken} from "./interfaces/IOutcomeToken.sol";
import {Market} from "./Market.sol";
import {OutcomeToken} from "./OutcomeToken.sol";

/// @title MarketFactory
/// @notice Validates parameters, deploys a Market clone, seeds it with collateral and
///         emits MarketCreated. Only admins (DEFAULT_ADMIN_ROLE) can create markets.
contract MarketFactory is AccessControl, ReentrancyGuard, IMarketFactory {
    using SafeERC20 for IERC20;

    uint16 internal constant FIFTY_FIFTY_BPS = 5_000;

    address public immutable implementation;

    IOutcomeToken public immutable outcomeToken;
    IERC20 public immutable collateral;

    uint256 public immutable minLiquidity;

    uint256 public marketCount;
    mapping(uint256 marketId => address market) public markets;
    mapping(address market => bool) public isMarket;

    constructor(address admin, uint256 minLiquidity_, address collateral_) {
        if (admin == address(0) || collateral_ == address(0) || minLiquidity_ == 0) revert InvalidConfig();

        collateral = IERC20(collateral_);
        minLiquidity = minLiquidity_;

        OutcomeToken token = new OutcomeToken(address(this));
        outcomeToken = token;
        implementation = address(new Market(address(this), token));

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function createMarket(CreateParams calldata p)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 marketId, address market)
    {
        _validate(p);

        marketId = ++marketCount;
        market = Clones.clone(implementation);
        markets[marketId] = market;
        isMarket[market] = true;

        outcomeToken.registerMarket(marketId, market);
        collateral.safeTransferFrom(msg.sender, market, p.initialLiquidity);
        IMarket(market)
            .initialize(
                IMarket.InitParams({
                    marketId: marketId,
                    creator: msg.sender,
                    arbitrator: p.arbitrator,
                    collateral: address(collateral),
                    closeTime: p.closeTime,
                    specHash: p.specHash,
                    initialLiquidity: p.initialLiquidity
                })
            );

        emit MarketCreated(
            marketId,
            market,
            msg.sender,
            p.arbitrator,
            address(collateral),
            p.closeTime,
            p.specHash,
            p.specCID,
            p.initialLiquidity
        );
    }

    function _validate(CreateParams calldata p) internal view {
        // The arbitrator may be the creator (Q4); the risk is documented in the threat model.
        if (p.arbitrator == address(0)) revert ZeroArbitrator();

        // A market closing at or before now would start Closed with its seed liquidity locked.
        if (p.closeTime <= block.timestamp) revert CloseTimeInPast(p.closeTime, block.timestamp);
        if (p.initialYesProbabilityBps != FIFTY_FIFTY_BPS) {
            revert UnsupportedInitialProbability(p.initialYesProbabilityBps);
        }
        // minLiquidity is never 0 (checked in the constructor), so this also rejects zero liquidity.
        if (p.initialLiquidity < minLiquidity) revert LiquidityTooLow(p.initialLiquidity, minLiquidity);
        if (p.specHash == bytes32(0)) revert EmptySpecHash();
        if (bytes(p.specCID).length == 0) revert EmptySpecCID();
    }
}
