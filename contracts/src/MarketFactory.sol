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
///         emits MarketCreated. Only MARKET_CREATOR_ROLE holders can create markets.
contract MarketFactory is AccessControl, ReentrancyGuard, IMarketFactory {
    using SafeERC20 for IERC20;

    bytes32 public constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");

    /// @dev Only supported starting probability until custom odds are implemented (Q3).
    uint16 internal constant FIFTY_FIFTY_BPS = 5_000;
    uint16 internal constant BPS = 10_000;

    address public immutable implementation;
    IOutcomeToken public immutable outcomeToken;

    uint64 public immutable minDuration;
    /// @dev In the collateral token's smallest unit (e.g. 10e6 = 10 USDC with 6 decimals).
    uint256 public immutable minLiquidity;
    uint16 public immutable maxFeeBps;

    /// @dev Market IDs start at 1, so 0 always means "no market".
    uint256 public marketCount;
    mapping(uint256 marketId => address market) public markets;
    mapping(address market => bool) public isMarket;
    mapping(address token => bool) public isCollateralAllowed;

    constructor(address admin, uint64 minDuration_, uint256 minLiquidity_, uint16 maxFeeBps_, address collateral) {
        if (admin == address(0) || minDuration_ == 0 || minLiquidity_ == 0 || maxFeeBps_ > BPS) {
            revert InvalidConfig();
        }

        minDuration = minDuration_;
        minLiquidity = minLiquidity_;
        maxFeeBps = maxFeeBps_;

        OutcomeToken token = new OutcomeToken(address(this));
        outcomeToken = token;
        implementation = address(new Market(address(this), token));

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MARKET_CREATOR_ROLE, admin);

        if (collateral != address(0)) _setCollateralAllowed(collateral, true);
    }

    function createMarket(CreateParams calldata p)
        external
        nonReentrant
        onlyRole(MARKET_CREATOR_ROLE)
        returns (uint256 marketId, address market)
    {
        _validate(p);

        marketId = ++marketCount;
        market = Clones.clone(implementation);
        markets[marketId] = market;
        isMarket[market] = true;

        outcomeToken.registerMarket(marketId, market);
        IERC20(p.collateral).safeTransferFrom(msg.sender, market, p.initialLiquidity);
        IMarket(market)
            .initialize(
                IMarket.InitParams({
                    marketId: marketId,
                    creator: msg.sender,
                    arbitrator: p.arbitrator,
                    collateral: p.collateral,
                    closeTime: p.closeTime,
                    resolutionDeadline: p.resolutionDeadline,
                    feeBps: p.feeBps,
                    specHash: p.specHash,
                    initialLiquidity: p.initialLiquidity
                })
            );

        _emitMarketCreated(marketId, market, p);
    }

    function setCollateralAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCollateralAllowed(token, allowed);
    }

    function _setCollateralAllowed(address token, bool allowed) internal {
        isCollateralAllowed[token] = allowed;
        emit CollateralAllowed(token, allowed);
    }

    /// @dev Separate function so the 11-field event doesn't overflow createMarket's stack.
    function _emitMarketCreated(uint256 marketId, address market, CreateParams calldata p) internal {
        emit MarketCreated(
            marketId,
            market,
            msg.sender,
            p.arbitrator,
            p.collateral,
            p.closeTime,
            p.resolutionDeadline,
            p.feeBps,
            p.specHash,
            p.specCID,
            p.initialLiquidity
        );
    }

    function _validate(CreateParams calldata p) internal view {
        if (!isCollateralAllowed[p.collateral]) revert CollateralNotAllowed(p.collateral);
        // The arbitrator may be the creator (Q4); the risk is documented in the threat model.
        if (p.arbitrator == address(0)) revert ZeroArbitrator();

        // minDuration and minLiquidity are never 0 (checked in the constructor), so these two
        // checks also reject a close time in the past and zero liquidity.
        uint256 earliestClose = block.timestamp + minDuration;
        if (p.closeTime < earliestClose) revert CloseTimeTooSoon(p.closeTime, earliestClose);
        if (p.resolutionDeadline <= p.closeTime) {
            revert InvalidResolutionDeadline(p.resolutionDeadline, p.closeTime);
        }
        if (p.feeBps > maxFeeBps) revert FeeTooHigh(p.feeBps, maxFeeBps);
        if (p.initialYesProbabilityBps != FIFTY_FIFTY_BPS) {
            revert UnsupportedInitialProbability(p.initialYesProbabilityBps);
        }
        if (p.initialLiquidity < minLiquidity) revert LiquidityTooLow(p.initialLiquidity, minLiquidity);
        if (p.specHash == bytes32(0)) revert EmptySpecHash();
        if (bytes(p.specCID).length == 0) revert EmptySpecCID();
    }
}
