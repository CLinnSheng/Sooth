// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IOutcomeToken} from "./interfaces/IOutcomeToken.sol";
import {OutcomeTokenId} from "./libraries/OutcomeTokenId.sol";

/// @title Market
/// @notice Implementation contract for one binary market. Never used directly: the factory
///         deploys EIP-1167 clones of it and initializes each clone in the same transaction.
/// @dev All parameters are set once in `initialize` and have no setters (E1-2).
contract Market is Initializable, ERC1155Holder, IMarket {
    /// @dev Immutables live in the implementation's bytecode, which every clone executes, so
    ///      all clones share these values without paying for storage writes.
    address public immutable factory;
    IOutcomeToken public immutable outcomeToken;

    uint256 public marketId;
    address public creator;
    address public arbitrator;
    IERC20 public collateral;
    uint64 public closeTime;
    uint64 public resolutionDeadline;
    uint16 public feeBps;
    bytes32 public specHash;

    /// @dev AMM reserves of YES and NO tokens held by this contract.
    uint256 public yesPool;
    uint256 public noPool;

    State internal _state;

    /// @dev Also locks the implementation so nobody can initialize (and take over) it directly.
    constructor(address factory_, IOutcomeToken outcomeToken_) {
        factory = factory_;
        outcomeToken = outcomeToken_;
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (msg.sender != factory) revert NotFactory(msg.sender);

        marketId = p.marketId;
        creator = p.creator;
        arbitrator = p.arbitrator;
        collateral = IERC20(p.collateral);
        closeTime = p.closeTime;
        resolutionDeadline = p.resolutionDeadline;
        feeBps = p.feeBps;
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
    }

    function state() public view returns (State) {
        if (_state == State.Open && block.timestamp >= closeTime) return State.Closed;
        return _state;
    }

    function priceYes() external view returns (uint256) {
        return (noPool * 1e18) / (yesPool + noPool);
    }

    function priceNo() external view returns (uint256) {
        return (yesPool * 1e18) / (yesPool + noPool);
    }

    function yesTokenId() public view returns (uint256) {
        return OutcomeTokenId.compute(marketId, Outcome.Yes);
    }

    function noTokenId() public view returns (uint256) {
        return OutcomeTokenId.compute(marketId, Outcome.No);
    }
}
