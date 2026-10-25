// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IOutcomeToken} from "./interfaces/IOutcomeToken.sol";
import {OutcomeTokenId} from "./libraries/OutcomeTokenId.sol";

/// @title Market
/// @notice Implementation contract for one binary market. Never used directly: the factory
///         deploys EIP-1167 clones of it and initializes each clone in the same transaction.
contract Market is Initializable, ERC1155Holder, ReentrancyGuardTransient, IMarket {
    using SafeERC20 for IERC20;
    /// @dev Immutables live in the implementation's bytecode, which every clone executes, so
    ///      all clones share these values without paying for storage writes.
    address public immutable factory;
    IOutcomeToken public immutable outcomeToken;
    IERC20 public immutable collateral;

    uint16 public constant FEE_BPS = 100;
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev How long the arbitrator has after close to resolve before the market can be cancelled.
    uint64 public constant RESOLUTION_WINDOW = 7 days;

    uint256 public marketId;
    address public creator;
    address public arbitrator;
    uint64 public closeTime;
    bytes32 public specHash;

    /// @dev AMM reserves of YES and NO tokens held by this contract.
    uint256 public yesPool;
    uint256 public noPool;
    /// @notice Collateral fees owed to creator, excluded from the backing used to mint shares.
    uint256 public accruedFees;

    State internal _state;
    /// @dev Meaningful only once final; read it through `finalResolution()`.
    Resolution internal _resolution;

    /// @dev Also locks the implementation so nobody can initialize (and take over) it directly.
    constructor(address factory_, IOutcomeToken outcomeToken_, IERC20 collateral_) {
        factory = factory_;
        outcomeToken = outcomeToken_;
        collateral = collateral_;
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (msg.sender != factory) revert NotFactory(msg.sender);

        marketId = p.marketId;
        creator = p.creator;
        arbitrator = p.arbitrator;
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

        (uint256[] memory ids, uint256[] memory amounts) = _yesNoBatch(p.initialLiquidity);
        outcomeToken.mintBatch(address(this), ids, amounts);
    }

    function buy(Outcome outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        _requireTradable(deadline);
        uint256 fee;
        (sharesOut, fee) = _quoteBuy(outcome, collateralIn);
        if (sharesOut < minSharesOut) revert InsufficientOutput(sharesOut, minSharesOut);

        uint256 net = collateralIn - fee;
        collateral.safeTransferFrom(msg.sender, address(this), collateralIn);

        (uint256 outcomePool, uint256 oppositePool) = _pools(outcome);
        _setPools(outcome, outcomePool + net - sharesOut, oppositePool + net);
        accruedFees += fee;

        (uint256[] memory ids, uint256[] memory amounts) = _yesNoBatch(net);
        outcomeToken.mintBatch(address(this), ids, amounts);
        outcomeToken.safeTransferFrom(address(this), msg.sender, _tokenId(outcome), sharesOut, "");

        emit Bought(msg.sender, outcome, collateralIn, sharesOut, fee);
    }

    function sell(Outcome outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 collateralOut)
    {
        _requireTradable(deadline);
        uint256 fee;
        (collateralOut, fee) = _quoteSell(outcome, sharesIn);
        if (collateralOut < minCollateralOut) revert InsufficientOutput(collateralOut, minCollateralOut);

        uint256 gross = collateralOut + fee;
        (uint256[] memory ids, uint256[] memory amounts) = _yesNoBatch(gross);

        outcomeToken.safeTransferFrom(msg.sender, address(this), _tokenId(outcome), sharesIn, "");
        outcomeToken.burnBatch(address(this), ids, amounts);

        (uint256 outcomePool, uint256 oppositePool) = _pools(outcome);
        _setPools(outcome, outcomePool + sharesIn - gross, oppositePool - gross);
        accruedFees += fee;
        collateral.safeTransfer(msg.sender, collateralOut);

        emit Sold(msg.sender, outcome, sharesIn, collateralOut, fee);
    }

    function withdrawFees() external nonReentrant returns (uint256 amount) {
        if (state() == State.Open) revert TradingStillOpen();
        amount = accruedFees;
        if (amount == 0) revert NoFeesToWithdraw();

        accruedFees = 0;
        collateral.safeTransfer(creator, amount);
        emit FeesWithdrawn(creator, amount);
    }

    function resolve(Resolution resolution) external {
        if (msg.sender != arbitrator) revert NotArbitrator(msg.sender);
        State current = state();
        if (current != State.Closed) revert NotClosed(current);

        _resolution = resolution;
        emit MarketResolved(resolution, msg.sender);
        if (resolution == Resolution.Invalid) {
            _state = State.Cancelled;
            emit MarketCancelled();
        } else {
            _state = State.Resolved;
        }
    }

    function finalize() external {
        State current = state();
        // Only the derived timeout cancellation has anything left to store.
        if (_state != State.Open || current != State.Cancelled) revert NothingToFinalize(current);

        _state = State.Cancelled;
        _resolution = Resolution.Invalid;
        emit MarketCancelled();
    }

    function redeem(uint256 yesAmount, uint256 noAmount) external nonReentrant returns (uint256 payout) {
        if (yesAmount == 0 && noAmount == 0) revert ZeroAmount();
        payout = _payout(yesAmount, noAmount);

        // Burning first is what prevents double claims: the tokens no longer exist.
        (uint256[] memory ids, uint256[] memory amounts) = _yesNoBatch(yesAmount, noAmount);
        outcomeToken.burnBatch(msg.sender, ids, amounts);
        if (payout != 0) collateral.safeTransfer(msg.sender, payout);

        emit Redeemed(msg.sender, yesAmount, noAmount, payout);
    }

    /// @dev Uses actual balances rather than yesPool/noPool so donated tokens are not stranded.
    ///      The pool numbers are left as they were; nothing reads them once the market is final.
    function claimLiquidity() external nonReentrant returns (uint256 payout) {
        uint256 yesAmount = outcomeToken.balanceOf(address(this), yesTokenId());
        uint256 noAmount = outcomeToken.balanceOf(address(this), noTokenId());
        payout = _payout(yesAmount, noAmount);
        if (yesAmount == 0 && noAmount == 0) revert NothingToClaim();

        (uint256[] memory ids, uint256[] memory amounts) = _yesNoBatch(yesAmount, noAmount);
        outcomeToken.burnBatch(address(this), ids, amounts);
        if (payout != 0) collateral.safeTransfer(creator, payout);

        emit LiquidityClaimed(creator, yesAmount, noAmount, payout);
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

    function previewRedeem(uint256 yesAmount, uint256 noAmount) external view returns (uint256) {
        return _payout(yesAmount, noAmount);
    }

    function finalResolution() external view returns (Resolution) {
        State current = state();
        if (current == State.Resolved) return _resolution;
        if (current == State.Cancelled) return Resolution.Invalid;
        revert NotFinal(current);
    }

    /// @dev Closed and the timeout Cancelled are derived, so no transaction is needed for either.
    ///      Always use this, never `_state`, when checking what the market allows.
    function state() public view returns (State) {
        if (_state == State.Open && block.timestamp >= closeTime) {
            return block.timestamp >= resolutionDeadline() ? State.Cancelled : State.Closed;
        }
        return _state;
    }

    function resolutionDeadline() public view returns (uint64) {
        return closeTime + RESOLUTION_WINDOW;
    }

    function yesTokenId() public view returns (uint256) {
        return OutcomeTokenId.compute(marketId, Outcome.Yes);
    }

    function noTokenId() public view returns (uint256) {
        return OutcomeTokenId.compute(marketId, Outcome.No);
    }

    function _quoteBuy(Outcome outcome, uint256 collateralIn) internal view returns (uint256 sharesOut, uint256 fee) {
        if (collateralIn == 0) revert ZeroAmount();
        fee = _fee(collateralIn);
        uint256 net = collateralIn - fee;
        if (net == 0) revert ZeroOutput();

        (uint256 outcomePool, uint256 oppositePool) = _pools(outcome);
        uint256 outcomePoolAfter = Math.mulDiv(outcomePool, oppositePool, oppositePool + net, Math.Rounding.Ceil);
        sharesOut = outcomePool + net - outcomePoolAfter;
        if (sharesOut == 0) revert ZeroOutput();
    }

    function _quoteSell(Outcome outcome, uint256 sharesIn) internal view returns (uint256 collateralOut, uint256 fee) {
        if (sharesIn == 0) revert ZeroAmount();
        (uint256 outcomePool, uint256 oppositePool) = _pools(outcome);
        if (oppositePool <= 1) revert ZeroOutput();
        uint256 high = Math.min(sharesIn, oppositePool - 1);
        uint256 low;
        // Binary search for the largest collateral release that keeps the pool product from shrinking.
        while (low < high) {
            uint256 mid = low + (high - low + 1) / 2;
            if (Math.mulDiv(outcomePool + sharesIn - mid, oppositePool - mid, oppositePool) >= outcomePool) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        fee = _fee(low);
        collateralOut = low - fee;
        if (collateralOut == 0) revert ZeroOutput();
    }

    /// @dev Resolved: winning side pays 1:1. Cancelled: every token pays 0.5, rounded down, so
    ///      the total paid never exceeds the backing (totalSupply(YES) == totalSupply(NO)).
    function _payout(uint256 yesAmount, uint256 noAmount) internal view returns (uint256) {
        State current = state();
        if (current == State.Cancelled) return (yesAmount + noAmount) / 2;
        if (current != State.Resolved) revert NotFinal(current);
        return _resolution == Resolution.Yes ? yesAmount : noAmount;
    }

    /// @dev Rounds up, so every trade pays a fee of at least 1 raw unit.
    function _fee(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    function _pools(Outcome outcome) internal view returns (uint256 outcomePool, uint256 oppositePool) {
        if (outcome == Outcome.Yes) return (yesPool, noPool);
        return (noPool, yesPool);
    }

    function _setPools(Outcome outcome, uint256 outcomePool, uint256 oppositePool) internal {
        if (outcome == Outcome.Yes) (yesPool, noPool) = (outcomePool, oppositePool);
        else (noPool, yesPool) = (outcomePool, oppositePool);
    }

    function _tokenId(Outcome outcome) internal view returns (uint256) {
        return outcome == Outcome.Yes ? yesTokenId() : noTokenId();
    }

    function _yesNoBatch(uint256 amount) internal view returns (uint256[] memory ids, uint256[] memory amounts) {
        return _yesNoBatch(amount, amount);
    }

    function _yesNoBatch(uint256 yesAmount, uint256 noAmount)
        internal
        view
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        ids = new uint256[](2);
        ids[0] = yesTokenId();
        ids[1] = noTokenId();
        amounts = new uint256[](2);
        amounts[0] = yesAmount;
        amounts[1] = noAmount;
    }

    function _requireTradable(uint256 deadline) internal view {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
        _requireOpen();
    }

    function _requireOpen() internal view {
        State current = state();
        if (current != State.Open) revert TradingClosed(current);
    }
}
