// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IOutcomeToken} from "./interfaces/IOutcomeToken.sol";
import {Market} from "./Market.sol";
import {OutcomeToken} from "./OutcomeToken.sol";

/// @title MarketFactory
/// @notice Validates parameters, deploys a Market clone, seeds it with collateral and
///         emits MarketCreated. Only admins (DEFAULT_ADMIN_ROLE) can create markets.
contract MarketFactory is AccessControl, IMarketFactory {
    using SafeERC20 for IERC20;

    uint16 internal constant FIFTY_FIFTY_BPS = 5_000;
    /// @dev Smallest seed, 10 USDC
    uint256 public constant MIN_LIQUIDITY = 10e6;

    address public immutable implementation;

    IOutcomeToken public immutable outcomeToken;
    IERC20 public immutable collateral;

    uint256 public marketCount;
    mapping(uint256 marketId => address market) public markets;

    constructor(address admin, address collateral_) {
        if (admin == address(0) || collateral_ == address(0)) revert InvalidConfig();

        uint8 decimals_ = IERC20Metadata(collateral_).decimals();
        if (decimals_ != 6) revert InvalidCollateralDecimals(decimals_);

        collateral = IERC20(collateral_);

        OutcomeToken token = new OutcomeToken(address(this));
        outcomeToken = token;

        implementation = address(new Market(address(this), token, collateral));

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function createMarket(CreateParams calldata p)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 marketId, address market)
    {
        _validate(p);
        bytes32 specHash = keccak256(bytes(p.spec));

        marketId = ++marketCount;
        market = Clones.clone(implementation);
        markets[marketId] = market;

        outcomeToken.registerMarket(marketId, market);

        collateral.safeTransferFrom(msg.sender, market, p.initialLiquidity);

        IMarket(market)
            .initialize(
                IMarket.InitParams({
                    marketId: marketId,
                    creator: msg.sender,
                    arbitrator: p.arbitrator,
                    closeTime: p.closeTime,
                    specHash: specHash,
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
            specHash,
            p.spec,
            p.initialLiquidity
        );
    }

    function _validate(CreateParams calldata p) internal view {
        // The arbitrator may be the creator; the risk is documented in the threat model.
        if (p.arbitrator == address(0)) revert ZeroArbitrator();

        // A market closing at or before now would start Closed with its seed liquidity locked.
        if (p.closeTime <= block.timestamp) revert CloseTimeInPast(p.closeTime, block.timestamp);
        if (p.initialYesProbabilityBps != FIFTY_FIFTY_BPS) {
            revert UnsupportedInitialProbability(p.initialYesProbabilityBps);
        }
        if (p.initialLiquidity < MIN_LIQUIDITY) revert LiquidityTooLow(p.initialLiquidity, MIN_LIQUIDITY);
        if (bytes(p.spec).length == 0) revert EmptySpec();
    }
}
