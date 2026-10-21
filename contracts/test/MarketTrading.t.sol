// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IOutcomeToken} from "../src/interfaces/IOutcomeToken.sol";

contract WrongDecimalsToken is ERC20 {
    constructor() ERC20("Wrong decimals", "WRONG") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract CallbackBuyer is IERC1155Receiver {
    Market public immutable market;
    IERC20 public immutable collateral;
    bool public reentryBlocked;

    constructor(Market market_, IERC20 collateral_) {
        market = market_;
        collateral = collateral_;
    }

    function buy(uint256 amount) external {
        collateral.approve(address(market), amount);
        market.buy(IMarket.Outcome.Yes, amount, 1, block.timestamp);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        try market.buy(IMarket.Outcome.Yes, 1e6, 0, block.timestamp) returns (uint256) {
            reentryBlocked = false;
        } catch {
            reentryBlocked = true;
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

contract MarketTradingTest is Test {
    uint256 private constant LIQUIDITY = 100e6;
    uint256 private constant TRADE = 10e6;
    bytes32 private constant SPEC_HASH = keccak256("market rules");
    string private constant SPEC_CID = "bafy-market-rules";

    MockUSDC private usdc;
    IOutcomeToken private token;
    Market private market;
    MarketFactory private factory;
    address private admin = makeAddr("admin");
    address private alice = makeAddr("alice");
    address private treasury = makeAddr("treasury");
    address private arbitrator = makeAddr("arbitrator");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        factory = new MarketFactory(admin, address(usdc), treasury);
        token = factory.outcomeToken();
        usdc.mint(admin, 1_000e6);
        vm.prank(admin);
        usdc.approve(address(factory), type(uint256).max);

        vm.prank(admin);
        (, address marketAddress) = factory.createMarket(
            IMarketFactory.CreateParams({
                arbitrator: arbitrator,
                closeTime: uint64(block.timestamp + 7 days),
                initialYesProbabilityBps: 5_000,
                specHash: SPEC_HASH,
                specCID: SPEC_CID,
                initialLiquidity: LIQUIDITY
            })
        );
        market = Market(marketAddress);
        usdc.mint(alice, 1_000e6);
    }

    function _buy(IMarket.Outcome outcome, uint256 amount) private returns (uint256 shares) {
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        shares = market.buy(outcome, amount, 1, block.timestamp);
        vm.stopPrank();
    }

    function _assertInventoryMatchesReserves() private view {
        assertEq(token.balanceOf(address(market), market.yesTokenId()), market.yesPool());
        assertEq(token.balanceOf(address(market), market.noTokenId()), market.noPool());
        assertGt(market.yesPool(), 0);
        assertGt(market.noPool(), 0);
    }

    function test_InitialSeedIsEqualNonzeroInventoryAndUsesSixDecimals() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(token.SHARE_DECIMALS(), 6);
        assertEq(market.feeBeneficiary(), treasury);
        _assertInventoryMatchesReserves();
        assertEq(market.yesPool(), LIQUIDITY);
        assertEq(market.noPool(), LIQUIDITY);
    }

    function test_FactoryRejectsCollateralWithWrongDecimals() public {
        WrongDecimalsToken wrong = new WrongDecimalsToken();
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.InvalidCollateralDecimals.selector, uint8(18)));
        new MarketFactory(admin, address(wrong), treasury);
    }

    function test_MarketCloneAdvertisesReceiverInterface() public view {
        assertTrue(market.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function test_BuyQuoteMatchesExecutionAndAccountsForFee() public {
        uint256 productBefore = market.yesPool() * market.noPool();
        (uint256 quoted, uint256 fee) = market.quoteBuy(IMarket.Outcome.Yes, TRADE);
        assertEq(fee, 100_000);
        uint256 userBefore = token.balanceOf(alice, market.yesTokenId());
        uint256 shares = _buy(IMarket.Outcome.Yes, TRADE);

        assertEq(shares, quoted);
        assertEq(token.balanceOf(alice, market.yesTokenId()), userBefore + quoted);
        assertEq(market.accruedFees(), fee);
        assertEq(usdc.balanceOf(address(market)), LIQUIDITY + TRADE);
        assertLt(market.yesPool(), LIQUIDITY);
        assertGt(market.noPool(), LIQUIDITY);
        assertGt(market.priceYes(), 0.5e18);
        assertGe(market.yesPool() * market.noPool(), productBefore);
        _assertInventoryMatchesReserves();
        assertGe(usdc.balanceOf(address(market)) - market.accruedFees(), token.totalSupply(market.yesTokenId()));
        assertGe(usdc.balanceOf(address(market)) - market.accruedFees(), token.totalSupply(market.noTokenId()));
    }

    function test_BuyEmitsTradeEvent() public {
        (uint256 quoted, uint256 fee) = market.quoteBuy(IMarket.Outcome.Yes, TRADE);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.expectEmit(true, true, false, true, address(market));
        emit IMarket.Bought(alice, IMarket.Outcome.Yes, TRADE, quoted, fee);
        vm.prank(alice);
        market.buy(IMarket.Outcome.Yes, TRADE, 1, block.timestamp);
    }

    function test_BuyNoMovesPriceInOppositeDirection() public {
        _buy(IMarket.Outcome.No, TRADE);
        assertLt(market.priceYes(), 0.5e18);
        assertGt(market.priceNo(), 0.5e18);
        _assertInventoryMatchesReserves();
    }

    function test_SellQuoteMatchesExecutionAndBurnsFromMarketCustody() public {
        uint256 shares = _buy(IMarket.Outcome.Yes, TRADE);
        uint256 productBeforeSell = market.yesPool() * market.noPool();
        uint256 toSell = shares / 2;
        (uint256 quoted, uint256 fee) = market.quoteSell(IMarket.Outcome.Yes, toSell);
        uint256 priceAfterBuy = market.priceYes();
        uint256 supplyBeforeYes = token.totalSupply(market.yesTokenId());
        uint256 supplyBeforeNo = token.totalSupply(market.noTokenId());
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        token.setApprovalForAll(address(market), true);
        uint256 received = market.sell(IMarket.Outcome.Yes, toSell, quoted, block.timestamp);
        vm.stopPrank();

        assertEq(received, quoted);
        assertEq(usdc.balanceOf(alice), balanceBefore + quoted);
        assertEq(market.accruedFees(), 100_000 + fee);
        uint256 gross = quoted + fee;
        assertEq(token.totalSupply(market.yesTokenId()), supplyBeforeYes - gross);
        assertEq(token.totalSupply(market.noTokenId()), supplyBeforeNo - gross);
        assertLt(market.priceYes(), priceAfterBuy);
        assertGe(market.yesPool() * market.noPool(), productBeforeSell);
        _assertInventoryMatchesReserves();
        assertGe(usdc.balanceOf(address(market)) - market.accruedFees(), token.totalSupply(market.yesTokenId()));
        assertGe(usdc.balanceOf(address(market)) - market.accruedFees(), token.totalSupply(market.noTokenId()));
    }

    function test_SellNoMovesPriceInOppositeDirection() public {
        uint256 shares = _buy(IMarket.Outcome.No, TRADE);
        uint256 priceAfterBuy = market.priceYes();
        vm.startPrank(alice);
        token.setApprovalForAll(address(market), true);
        market.sell(IMarket.Outcome.No, shares, 1, block.timestamp);
        vm.stopPrank();
        assertGt(market.priceYes(), priceAfterBuy);
        assertLe(market.priceYes(), 0.5e18);
        _assertInventoryMatchesReserves();
    }

    function test_SellEmitsTradeEvent() public {
        uint256 shares = _buy(IMarket.Outcome.No, TRADE);
        (uint256 quoted, uint256 fee) = market.quoteSell(IMarket.Outcome.No, shares);
        vm.startPrank(alice);
        token.setApprovalForAll(address(market), true);
        vm.expectEmit(true, true, false, true, address(market));
        emit IMarket.Sold(alice, IMarket.Outcome.No, shares, quoted, fee);
        market.sell(IMarket.Outcome.No, shares, quoted, block.timestamp);
        vm.stopPrank();
    }

    function test_DirectRoundTripDoesNotProfit() public {
        uint256 beforeBalance = usdc.balanceOf(alice);
        uint256 shares = _buy(IMarket.Outcome.Yes, TRADE);
        vm.startPrank(alice);
        token.setApprovalForAll(address(market), true);
        market.sell(IMarket.Outcome.Yes, shares, 1, block.timestamp);
        vm.stopPrank();
        assertLe(usdc.balanceOf(alice), beforeBalance);
    }

    function test_RevertWhen_BuyerFailsSlippageOrApproval() public {
        (uint256 quoted,) = market.quoteBuy(IMarket.Outcome.Yes, TRADE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarket.InsufficientOutput.selector, quoted, quoted + 1));
        market.buy(IMarket.Outcome.Yes, TRADE, quoted + 1, block.timestamp);
        assertEq(market.yesPool(), LIQUIDITY);

        vm.prank(alice);
        vm.expectRevert();
        market.buy(IMarket.Outcome.Yes, TRADE, 1, block.timestamp);
        assertEq(market.noPool(), LIQUIDITY);
    }

    function test_RevertWhen_BuyerBalanceIsInsufficient() public {
        uint256 amount = 2_000e6;
        vm.startPrank(alice);
        usdc.approve(address(market), amount);
        vm.expectRevert();
        market.buy(IMarket.Outcome.Yes, amount, 1, block.timestamp);
        vm.stopPrank();
        assertEq(market.yesPool(), LIQUIDITY);
        assertEq(market.accruedFees(), 0);
    }

    function test_RevertWhen_SellerHasNotApprovedMarket() public {
        uint256 shares = _buy(IMarket.Outcome.Yes, TRADE);
        vm.prank(alice);
        vm.expectRevert();
        market.sell(IMarket.Outcome.Yes, shares, 1, block.timestamp);
    }

    function test_RevertWhen_SellerShareBalanceIsInsufficient() public {
        vm.startPrank(alice);
        token.setApprovalForAll(address(market), true);
        vm.expectRevert();
        market.sell(IMarket.Outcome.Yes, 1e6, 1, block.timestamp);
        vm.stopPrank();
        assertEq(market.noPool(), LIQUIDITY);
    }

    function test_RevertWhen_SellOutputBelowMinimum() public {
        uint256 shares = _buy(IMarket.Outcome.Yes, TRADE);
        (uint256 quoted,) = market.quoteSell(IMarket.Outcome.Yes, shares);
        vm.startPrank(alice);
        token.setApprovalForAll(address(market), true);
        vm.expectRevert(abi.encodeWithSelector(IMarket.InsufficientOutput.selector, quoted, quoted + 1));
        market.sell(IMarket.Outcome.Yes, shares, quoted + 1, block.timestamp);
        vm.stopPrank();
        assertEq(market.accruedFees(), 100_000);
    }

    function test_RevertWhen_DeadlineExpiredOrMarketClosed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarket.DeadlineExpired.selector, block.timestamp - 1, block.timestamp));
        market.buy(IMarket.Outcome.Yes, TRADE, 1, block.timestamp - 1);

        vm.warp(market.closeTime());
        vm.expectRevert(abi.encodeWithSelector(IMarket.TradingClosed.selector, IMarket.State.Closed));
        market.quoteBuy(IMarket.Outcome.Yes, TRADE);
        vm.expectRevert(abi.encodeWithSelector(IMarket.TradingClosed.selector, IMarket.State.Closed));
        market.buy(IMarket.Outcome.Yes, TRADE, 1, block.timestamp);
    }

    function test_RevertWhen_ZeroInputOrDustOutput() public {
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.quoteBuy(IMarket.Outcome.Yes, 0);
        vm.expectRevert(IMarket.ZeroOutput.selector);
        market.quoteBuy(IMarket.Outcome.Yes, 1);
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.quoteSell(IMarket.Outcome.Yes, 0);
    }

    function test_BuyerReceiverCannotReenterMarket() public {
        CallbackBuyer receiver = new CallbackBuyer(market, usdc);
        usdc.mint(address(receiver), TRADE);
        receiver.buy(TRADE);
        assertTrue(receiver.reentryBlocked());
        assertGt(token.balanceOf(address(receiver), market.yesTokenId()), 0);
        _assertInventoryMatchesReserves();
    }

    function test_DonationsDoNotChangeRecordedReserves() public {
        _buy(IMarket.Outcome.Yes, TRADE);
        uint256 yesReserve = market.yesPool();
        uint256 noReserve = market.noPool();
        vm.prank(alice);
        token.setApprovalForAll(address(this), true);
        token.safeTransferFrom(alice, address(market), market.yesTokenId(), 1, "");
        usdc.mint(address(market), 3e6);
        assertEq(market.yesPool(), yesReserve);
        assertEq(market.noPool(), noReserve);
        assertGt(token.balanceOf(address(market), market.yesTokenId()), market.yesPool());
        assertGt(usdc.balanceOf(address(market)) - market.accruedFees(), token.totalSupply(market.yesTokenId()));
    }

    function testFuzz_BuyThenSellCannotProfit(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1e6, 100e6);
        uint256 productBefore = market.yesPool() * market.noPool();
        uint256 beforeBalance = usdc.balanceOf(alice);
        uint256 shares = _buy(IMarket.Outcome.Yes, amount);
        assertGe(market.yesPool() * market.noPool(), productBefore);
        vm.startPrank(alice);
        token.setApprovalForAll(address(market), true);
        market.sell(IMarket.Outcome.Yes, shares, 1, block.timestamp);
        vm.stopPrank();
        assertLe(usdc.balanceOf(alice), beforeBalance);
        assertGe(market.yesPool() * market.noPool(), productBefore);
        assertGe(usdc.balanceOf(address(market)) - market.accruedFees(), token.totalSupply(market.yesTokenId()));
        assertGe(usdc.balanceOf(address(market)) - market.accruedFees(), token.totalSupply(market.noTokenId()));
        _assertInventoryMatchesReserves();
    }
}
