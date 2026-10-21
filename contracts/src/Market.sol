// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IOutcomeToken} from "./interfaces/IOutcomeToken.sol";
import {OutcomeTokenId} from "./libraries/OutcomeTokenId.sol";

/// @title Market
/// @notice Implementation contract for one binary market. Never used directly: the factory
///         deploys EIP-1167 clones of it and initializes each clone in the same transaction.
/// @dev All parameters are set once in `initialize` and have no setters (E1-2).
contract Market is Initializable, ERC1155Holder, ReentrancyGuard, IMarket {
    using SafeERC20 for IERC20;
    /// @dev Immutables live in the implementation's bytecode, which every clone executes, so
    ///      all clones share these values without paying for storage writes.
    address public immutable factory;
    IOutcomeToken public immutable outcomeToken;
    address public immutable feeBeneficiary;

    /// @dev Flat 1% fee on every trade, the same for all markets.
    uint16 public constant FEE_BPS = 100;
    /// @dev How long the arbitrator has after close to resolve before the market can be cancelled.
    uint64 public constant RESOLUTION_WINDOW = 7 days;

    uint256 public marketId;
    address public creator;
    address public arbitrator;
    IERC20 public collateral;
    uint64 public closeTime;
    bytes32 public specHash;

    /// @dev AMM reserves of YES and NO tokens held by this contract.
    uint256 public yesPool;
    uint256 public noPool;
    uint256 public accruedFees;

    State internal _state;

    /// @dev Also locks the implementation so nobody can initialize (and take over) it directly.
    constructor(address factory_, IOutcomeToken outcomeToken_, address feeBeneficiary_) {
        factory = factory_;
        outcomeToken = outcomeToken_;
        feeBeneficiary = feeBeneficiary_;
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (msg.sender != factory) revert NotFactory(msg.sender);

        marketId = p.marketId;
        creator = p.creator;
        arbitrator = p.arbitrator;
        collateral = IERC20(p.collateral);
        closeTime = p.closeTime;
        specHash = p.specHash;

        _state = State.Open;

        // Each YES+NO pair is backed by exactly 1 unit of collateral, so seeding L collateral
        // mints L YES and L NO into the pool, which gives a 50/50 starting price.
        // `>=` rather than `==`: clone addresses are predictable, so an exact check would let
        // anyone block creation by sending 1 unit to the next market's address first.
        uint256 balance = collateral.balanceOf(address(this));
        if (balance < p.initialLiquidity) revert CollateralNotReceived(p.initialLiquidity, balance);

        yesPool = p.initialLiquidity;
        noPool = p.initialLiquidity;

        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId();
        ids[1] = noTokenId();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = p.initialLiquidity;
        amounts[1] = p.initialLiquidity;
        outcomeToken.mintBatch(address(this), ids, amounts);

        uint256 yesBalance = outcomeToken.balanceOf(address(this), ids[0]);
        uint256 noBalance = outcomeToken.balanceOf(address(this), ids[1]);
        if (yesBalance != p.initialLiquidity || noBalance != p.initialLiquidity) {
            revert InitialInventoryMismatch(yesBalance, noBalance, p.initialLiquidity);
        }
    }

    function state() public view returns (State) {
        if (_state == State.Open && block.timestamp >= closeTime) return State.Closed;
        return _state;
    }

    function resolutionDeadline() external view returns (uint64) {
        return closeTime + RESOLUTION_WINDOW;
    }

    function priceYes() external view returns (uint256) {
        return Math.mulDiv(noPool, 1e18, yesPool + noPool);
    }

    function priceNo() external view returns (uint256) {
        return Math.mulDiv(yesPool, 1e18, yesPool + noPool);
    }

    function quoteBuy(Outcome outcome, uint256 collateralIn) external view returns (uint256 sharesOut, uint256 fee) {
        _requireOpen();
        return _quoteBuy(outcome, collateralIn);
    }

    function quoteSell(Outcome outcome, uint256 sharesIn) external view returns (uint256 collateralOut, uint256 fee) {
        _requireOpen();
        return _quoteSell(outcome, sharesIn);
    }

    function buy(Outcome outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        _checkTrade(deadline);
        uint256 fee;
        (sharesOut, fee) = _quoteBuy(outcome, collateralIn);
        if (sharesOut < minSharesOut) revert InsufficientOutput(sharesOut, minSharesOut);

        _executeBuy(outcome, collateralIn, sharesOut, fee);
        emit Bought(msg.sender, outcome, collateralIn, sharesOut, fee);
    }

    function _executeBuy(Outcome outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee) internal {
        uint256 net = collateralIn - fee;
        uint256 beforeBalance = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), collateralIn);
        if (collateral.balanceOf(address(this)) - beforeBalance != collateralIn) {
            revert CollateralNotReceived(collateralIn, collateral.balanceOf(address(this)) - beforeBalance);
        }

        (uint256 yesAfter, uint256 noAfter) = _reservesAfterBuy(outcome, net, sharesOut);
        yesPool = yesAfter;
        noPool = noAfter;
        accruedFees += fee;

        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId();
        ids[1] = noTokenId();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = net;
        amounts[1] = net;
        outcomeToken.mintBatch(address(this), ids, amounts);
        outcomeToken.safeTransferFrom(address(this), msg.sender, _tokenId(outcome), sharesOut, "");
    }

    function sell(Outcome outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 collateralOut)
    {
        _checkTrade(deadline);
        uint256 fee;
        (collateralOut, fee) = _quoteSell(outcome, sharesIn);
        if (collateralOut < minCollateralOut) revert InsufficientOutput(collateralOut, minCollateralOut);

        uint256 gross = collateralOut + fee;
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId();
        ids[1] = noTokenId();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = gross;
        amounts[1] = gross;

        outcomeToken.safeTransferFrom(msg.sender, address(this), _tokenId(outcome), sharesIn, "");
        outcomeToken.burnBatch(address(this), ids, amounts);

        (uint256 yesAfter, uint256 noAfter) = _reservesAfterSell(outcome, sharesIn, gross);
        yesPool = yesAfter;
        noPool = noAfter;
        accruedFees += fee;
        collateral.safeTransfer(msg.sender, collateralOut);

        emit Sold(msg.sender, outcome, sharesIn, collateralOut, fee);
    }

    function _quoteBuy(Outcome outcome, uint256 collateralIn) internal view returns (uint256 sharesOut, uint256 fee) {
        if (collateralIn == 0) revert ZeroAmount();
        fee = Math.mulDiv(collateralIn, FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 net = collateralIn - fee;
        if (net == 0) revert ZeroOutput();

        (uint256 selected, uint256 opposite) = _selectedReserves(outcome);
        uint256 selectedAfter = Math.mulDiv(selected, opposite, opposite + net, Math.Rounding.Ceil);
        sharesOut = selected + net - selectedAfter;
        if (sharesOut == 0) revert ZeroOutput();
    }

    function _quoteSell(Outcome outcome, uint256 sharesIn) internal view returns (uint256 collateralOut, uint256 fee) {
        if (sharesIn == 0) revert ZeroAmount();
        (uint256 selected, uint256 opposite) = _selectedReserves(outcome);
        if (opposite <= 1) revert ZeroOutput();
        uint256 high = Math.min(sharesIn, opposite - 1);
        uint256 low;
        // binary search to find the maximum share
        while (low < high) {
            uint256 mid = low + (high - low + 1) / 2;
            if (Math.mulDiv(selected + sharesIn - mid, opposite - mid, opposite) >= selected) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        fee = Math.mulDiv(low, FEE_BPS, 10_000, Math.Rounding.Ceil);
        collateralOut = low - fee;
        if (low == 0 || collateralOut == 0) revert ZeroOutput();
    }

    function _selectedReserves(Outcome outcome) internal view returns (uint256 selected, uint256 opposite) {
        if (outcome == Outcome.Yes) return (yesPool, noPool);
        return (noPool, yesPool);
    }

    function _tokenId(Outcome outcome) internal view returns (uint256) {
        return outcome == Outcome.Yes ? yesTokenId() : noTokenId();
    }

    function _reservesAfterBuy(Outcome outcome, uint256 net, uint256 sharesOut)
        internal
        view
        returns (uint256 yesAfter, uint256 noAfter)
    {
        if (outcome == Outcome.Yes) return (yesPool + net - sharesOut, noPool + net);
        return (yesPool + net, noPool + net - sharesOut);
    }

    function _reservesAfterSell(Outcome outcome, uint256 sharesIn, uint256 gross)
        internal
        view
        returns (uint256 yesAfter, uint256 noAfter)
    {
        if (outcome == Outcome.Yes) return (yesPool + sharesIn - gross, noPool - gross);
        return (yesPool - gross, noPool + sharesIn - gross);
    }

    function _checkTrade(uint256 deadline) internal view {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
        _requireOpen();
    }

    function _requireOpen() internal view {
        State current = state();
        if (current != State.Open) revert TradingClosed(current);
    }

    function yesTokenId() public view returns (uint256) {
        return OutcomeTokenId.compute(marketId, Outcome.Yes);
    }

    function noTokenId() public view returns (uint256) {
        return OutcomeTokenId.compute(marketId, Outcome.No);
    }
}
