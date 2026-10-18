// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IOutcomeToken} from "../src/interfaces/IOutcomeToken.sol";
import {OutcomeTokenId} from "../src/libraries/OutcomeTokenId.sol";

contract MarketFactoryTest is Test {
    uint64 constant MIN_DURATION = 10 minutes;
    uint256 constant MIN_LIQUIDITY = 10e6; // 10 mUSDC
    uint16 constant MAX_FEE_BPS = 500;
    uint256 constant LIQUIDITY = 100e6;
    bytes32 constant SPEC_HASH = keccak256('{"question":"Will BTC/USD exceed $150,000 before 31 Dec 2026?"}');
    string constant SPEC_CID = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    MarketFactory factory;
    MockUSDC usdc;
    IOutcomeToken token;

    address admin = makeAddr("admin");
    address arbitrator = makeAddr("arbitrator");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        factory = new MarketFactory(admin, MIN_DURATION, MIN_LIQUIDITY, MAX_FEE_BPS, address(usdc));
        token = factory.outcomeToken();

        usdc.mint(admin, 1_000_000e6);
        vm.prank(admin);
        usdc.approve(address(factory), type(uint256).max);
    }

    function _params() internal view returns (IMarketFactory.CreateParams memory) {
        return IMarketFactory.CreateParams({
            arbitrator: arbitrator,
            closeTime: uint64(block.timestamp + 7 days),
            resolutionDeadline: uint64(block.timestamp + 14 days),
            feeBps: 200,
            initialYesProbabilityBps: 5_000,
            specHash: SPEC_HASH,
            specCID: SPEC_CID,
            initialLiquidity: LIQUIDITY
        });
    }

    function _create(IMarketFactory.CreateParams memory p) internal returns (uint256 id, Market market) {
        vm.prank(admin);
        address addr;
        (id, addr) = factory.createMarket(p);
        market = Market(addr);
    }

    function _expectCreateRevert(IMarketFactory.CreateParams memory p, bytes memory err) internal {
        vm.prank(admin);
        vm.expectRevert(err);
        factory.createMarket(p);
    }

    // ---------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------

    function test_CreateMarket_StoresParameters() public {
        IMarketFactory.CreateParams memory p = _params();
        (uint256 id, Market m) = _create(p);

        assertEq(m.factory(), address(factory));
        assertEq(m.marketId(), id);
        assertEq(address(m.outcomeToken()), address(token));
        assertEq(m.creator(), admin);
        assertEq(m.arbitrator(), arbitrator);
        assertEq(address(m.collateral()), address(usdc));
        assertEq(m.closeTime(), p.closeTime);
        assertEq(m.resolutionDeadline(), p.resolutionDeadline);
        assertEq(m.feeBps(), p.feeBps);
        assertEq(m.specHash(), SPEC_HASH);
        assertEq(m.yesTokenId(), OutcomeTokenId.compute(id, IMarket.Outcome.Yes));
        assertEq(m.noTokenId(), OutcomeTokenId.compute(id, IMarket.Outcome.No));
        assertEq(uint8(m.state()), uint8(IMarket.State.Open));

        assertEq(factory.markets(id), address(m));
        assertTrue(factory.isMarket(address(m)));
        assertEq(address(factory.collateral()), address(usdc));
    }

    function test_CreateMarket_EmitsMarketCreated() public {
        IMarketFactory.CreateParams memory p = _params();
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(true, true, true, true, address(factory));
        emit IMarketFactory.MarketCreated(
            1,
            predicted,
            admin,
            arbitrator,
            address(usdc),
            p.closeTime,
            p.resolutionDeadline,
            p.feeBps,
            SPEC_HASH,
            SPEC_CID,
            LIQUIDITY
        );
        (, Market m) = _create(p);
        assertEq(address(m), predicted);
    }

    function test_CreateMarket_IdsIncrementFromOne() public {
        (uint256 id1, Market m1) = _create(_params());
        (uint256 id2, Market m2) = _create(_params());

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(factory.marketCount(), 2);
        assertTrue(address(m1) != address(m2));
    }

    function test_CreateMarket_MovesCollateralAndSeedsPools() public {
        uint256 adminBefore = usdc.balanceOf(admin);
        (, Market m) = _create(_params());

        assertEq(usdc.balanceOf(admin), adminBefore - LIQUIDITY);
        assertEq(usdc.balanceOf(address(m)), LIQUIDITY);
        assertEq(usdc.balanceOf(address(factory)), 0);

        assertEq(m.yesPool(), LIQUIDITY);
        assertEq(m.noPool(), LIQUIDITY);
        assertEq(token.balanceOf(address(m), m.yesTokenId()), LIQUIDITY);
        assertEq(token.balanceOf(address(m), m.noTokenId()), LIQUIDITY);
        assertEq(token.totalSupply(m.yesTokenId()), LIQUIDITY);
        assertEq(token.totalSupply(m.noTokenId()), LIQUIDITY);
    }

    function test_CreateMarket_StartsAtFiftyFifty() public {
        (, Market m) = _create(_params());
        assertEq(m.priceYes(), 0.5e18);
        assertEq(m.priceNo(), 0.5e18);
    }

    function test_CreateMarket_TokenIdsUniqueAcrossMarkets() public {
        (, Market m1) = _create(_params());
        (, Market m2) = _create(_params());

        assertTrue(m1.yesTokenId() != m1.noTokenId());
        assertTrue(m1.yesTokenId() != m2.yesTokenId());
        assertTrue(m1.noTokenId() != m2.noTokenId());
        assertEq(token.marketOf(m1.yesTokenId()), address(m1));
        assertEq(token.marketOf(m2.noTokenId()), address(m2));
    }

    function test_CreateMarket_ArbitratorCanBeCreator() public {
        IMarketFactory.CreateParams memory p = _params();
        p.arbitrator = admin;
        (, Market m) = _create(p);
        assertEq(m.arbitrator(), admin);
    }

    function test_CreateMarket_AcceptsExactMinimums() public {
        IMarketFactory.CreateParams memory p = _params();
        p.closeTime = uint64(block.timestamp + MIN_DURATION);
        p.resolutionDeadline = p.closeTime + 1;
        p.feeBps = MAX_FEE_BPS;
        p.initialLiquidity = MIN_LIQUIDITY;
        _create(p);
    }

    // ---------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------

    function test_RevertWhen_CallerIsNotMarketCreator() public {
        bytes32 role = factory.MARKET_CREATOR_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        factory.createMarket(_params());
    }

    function test_GrantedCreatorCanCreate() public {
        bytes32 role = factory.MARKET_CREATOR_ROLE();
        vm.prank(admin);
        factory.grantRole(role, alice);

        usdc.mint(alice, LIQUIDITY);
        vm.startPrank(alice);
        usdc.approve(address(factory), LIQUIDITY);
        (, address m) = factory.createMarket(_params());
        vm.stopPrank();

        assertEq(Market(m).creator(), alice);
    }

    function test_RevertWhen_CollateralNotApproved() public {
        bytes32 role = factory.MARKET_CREATOR_ROLE();
        vm.prank(admin);
        factory.grantRole(role, alice);
        usdc.mint(alice, LIQUIDITY);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, LIQUIDITY)
        );
        factory.createMarket(_params());
    }

    // ---------------------------------------------------------------
    // Validation (E1-2)
    // ---------------------------------------------------------------

    function test_RevertWhen_ArbitratorIsZero() public {
        IMarketFactory.CreateParams memory p = _params();
        p.arbitrator = address(0);
        _expectCreateRevert(p, abi.encodeWithSelector(IMarketFactory.ZeroArbitrator.selector));
    }

    function test_RevertWhen_CloseTimeInPast() public {
        IMarketFactory.CreateParams memory p = _params();
        p.closeTime = uint64(block.timestamp - 1);
        _expectCreateRevert(
            p,
            abi.encodeWithSelector(
                IMarketFactory.CloseTimeTooSoon.selector, p.closeTime, block.timestamp + MIN_DURATION
            )
        );
    }

    function test_RevertWhen_CloseTimeTooSoon() public {
        IMarketFactory.CreateParams memory p = _params();
        p.closeTime = uint64(block.timestamp + MIN_DURATION - 1);
        _expectCreateRevert(
            p,
            abi.encodeWithSelector(
                IMarketFactory.CloseTimeTooSoon.selector, p.closeTime, block.timestamp + MIN_DURATION
            )
        );
    }

    function test_RevertWhen_ResolutionDeadlineNotAfterClose() public {
        IMarketFactory.CreateParams memory p = _params();
        p.resolutionDeadline = p.closeTime;
        _expectCreateRevert(
            p,
            abi.encodeWithSelector(IMarketFactory.InvalidResolutionDeadline.selector, p.resolutionDeadline, p.closeTime)
        );
    }

    function test_RevertWhen_FeeTooHigh() public {
        IMarketFactory.CreateParams memory p = _params();
        p.feeBps = MAX_FEE_BPS + 1;
        _expectCreateRevert(p, abi.encodeWithSelector(IMarketFactory.FeeTooHigh.selector, p.feeBps, MAX_FEE_BPS));
    }

    function test_RevertWhen_InitialProbabilityNotFiftyFifty() public {
        IMarketFactory.CreateParams memory p = _params();
        p.initialYesProbabilityBps = 6_000;
        _expectCreateRevert(
            p, abi.encodeWithSelector(IMarketFactory.UnsupportedInitialProbability.selector, uint16(6_000))
        );
    }

    function test_RevertWhen_LiquidityTooLow() public {
        IMarketFactory.CreateParams memory p = _params();
        p.initialLiquidity = MIN_LIQUIDITY - 1;
        _expectCreateRevert(
            p, abi.encodeWithSelector(IMarketFactory.LiquidityTooLow.selector, p.initialLiquidity, MIN_LIQUIDITY)
        );
    }

    function test_RevertWhen_SpecHashEmpty() public {
        IMarketFactory.CreateParams memory p = _params();
        p.specHash = bytes32(0);
        _expectCreateRevert(p, abi.encodeWithSelector(IMarketFactory.EmptySpecHash.selector));
    }

    function test_RevertWhen_SpecCIDEmpty() public {
        IMarketFactory.CreateParams memory p = _params();
        p.specCID = "";
        _expectCreateRevert(p, abi.encodeWithSelector(IMarketFactory.EmptySpecCID.selector));
    }

    function test_RevertWhen_FactoryConfigInvalid() public {
        vm.expectRevert(IMarketFactory.InvalidConfig.selector);
        new MarketFactory(address(0), MIN_DURATION, MIN_LIQUIDITY, MAX_FEE_BPS, address(usdc));

        vm.expectRevert(IMarketFactory.InvalidConfig.selector);
        new MarketFactory(admin, MIN_DURATION, MIN_LIQUIDITY, MAX_FEE_BPS, address(0));

        vm.expectRevert(IMarketFactory.InvalidConfig.selector);
        new MarketFactory(admin, MIN_DURATION, MIN_LIQUIDITY, 10_001, address(usdc));

        vm.expectRevert(IMarketFactory.InvalidConfig.selector);
        new MarketFactory(admin, 0, MIN_LIQUIDITY, MAX_FEE_BPS, address(usdc));

        vm.expectRevert(IMarketFactory.InvalidConfig.selector);
        new MarketFactory(admin, MIN_DURATION, 0, MAX_FEE_BPS, address(usdc));
    }

    // ---------------------------------------------------------------
    // State machine (E1-3)
    // ---------------------------------------------------------------

    function test_State_ClosedIsDerivedFromCloseTime() public {
        (, Market m) = _create(_params());

        vm.warp(m.closeTime() - 1);
        assertEq(uint8(m.state()), uint8(IMarket.State.Open));

        vm.warp(m.closeTime());
        assertEq(uint8(m.state()), uint8(IMarket.State.Closed));
    }

    // ---------------------------------------------------------------
    // Clone and token safety
    // ---------------------------------------------------------------

    function test_RevertWhen_MarketInitializedTwice() public {
        (, Market m) = _create(_params());
        IMarket.InitParams memory init;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        m.initialize(init);
    }

    function test_RevertWhen_ImplementationInitialized() public {
        Market impl = Market(factory.implementation());
        IMarket.InitParams memory init;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(init);
    }

    function test_RevertWhen_NonFactoryRegistersMarket() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeToken.NotFactory.selector, alice));
        token.registerMarket(99, alice);
    }

    function test_RevertWhen_NonMarketMints() public {
        (, Market m) = _create(_params());
        uint256 yesId = m.yesTokenId();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeToken.NotMarketForToken.selector, alice, yesId));
        token.mint(alice, yesId, 1);
    }

    function test_RevertWhen_MarketMintsAnotherMarketsToken() public {
        (, Market m1) = _create(_params());
        (, Market m2) = _create(_params());
        uint256 otherYesId = m2.yesTokenId();
        vm.prank(address(m1));
        vm.expectRevert(abi.encodeWithSelector(IOutcomeToken.NotMarketForToken.selector, address(m1), otherYesId));
        token.mint(address(m1), otherYesId, 1);
    }

    function _initParams() internal view returns (IMarket.InitParams memory) {
        return IMarket.InitParams({
            marketId: 99,
            creator: admin,
            arbitrator: arbitrator,
            collateral: address(usdc),
            closeTime: uint64(block.timestamp + 7 days),
            resolutionDeadline: uint64(block.timestamp + 14 days),
            feeBps: 200,
            specHash: SPEC_HASH,
            initialLiquidity: LIQUIDITY
        });
    }

    function test_RevertWhen_NonFactoryInitializesClone() public {
        Market clone = Market(Clones.clone(factory.implementation()));
        IMarket.InitParams memory init = _initParams();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarket.NotFactory.selector, alice));
        clone.initialize(init);
    }

    function test_ClonesShareFactoryAndToken() public {
        (, Market m) = _create(_params());
        Market impl = Market(factory.implementation());
        assertEq(m.factory(), impl.factory());
        assertEq(address(m.outcomeToken()), address(impl.outcomeToken()));
    }

    function test_RevertWhen_MarketInitializedWithoutCollateral() public {
        Market clone = Market(Clones.clone(factory.implementation()));
        IMarket.InitParams memory init = _initParams();
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IMarket.CollateralNotReceived.selector, LIQUIDITY, 0));
        clone.initialize(init);
    }

    function test_OutcomeToken_MarketCanMintOwnToken() public {
        (, Market m) = _create(_params());
        uint256 noId = m.noTokenId();
        vm.prank(address(m));
        token.mint(alice, noId, 5e6);
        assertEq(token.balanceOf(alice, noId), 5e6);
    }

    function test_RevertWhen_MintBatchIncludesAnotherMarketsToken() public {
        (, Market m1) = _create(_params());
        (, Market m2) = _create(_params());
        uint256[] memory ids = new uint256[](2);
        ids[0] = m1.yesTokenId();
        ids[1] = m2.noTokenId();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        vm.prank(address(m1));
        vm.expectRevert(abi.encodeWithSelector(IOutcomeToken.NotMarketForToken.selector, address(m1), ids[1]));
        token.mintBatch(address(m1), ids, amounts);
    }

    function test_RevertWhen_MarketRegisteredTwice() public {
        (uint256 id,) = _create(_params());
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IOutcomeToken.MarketAlreadyRegistered.selector, id));
        token.registerMarket(id, alice);
    }

    function test_OutcomeToken_MarketCanBurnOwnToken() public {
        (, Market m) = _create(_params());
        uint256 yesId = m.yesTokenId();
        vm.prank(address(m));
        token.burn(address(m), yesId, 10e6);

        assertEq(token.balanceOf(address(m), yesId), LIQUIDITY - 10e6);
        assertEq(token.totalSupply(yesId), LIQUIDITY - 10e6);
    }

    function test_RevertWhen_NonMarketBurns() public {
        (, Market m) = _create(_params());
        uint256 yesId = m.yesTokenId();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOutcomeToken.NotMarketForToken.selector, alice, yesId));
        token.burn(address(m), yesId, 1);
    }

    function test_MockUSDC_HasSixDecimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    // ---------------------------------------------------------------
    // Fuzz: collateral invariant at creation (E8-4)
    // ---------------------------------------------------------------

    function testFuzz_CreateMarket_FullyCollateralized(uint64 closeOffset, uint256 liquidity, uint16 feeBps) public {
        closeOffset = uint64(bound(closeOffset, MIN_DURATION, 365 days));
        liquidity = bound(liquidity, MIN_LIQUIDITY, usdc.balanceOf(admin));
        feeBps = uint16(bound(feeBps, 0, MAX_FEE_BPS));

        IMarketFactory.CreateParams memory p = _params();
        p.closeTime = uint64(block.timestamp) + closeOffset;
        p.resolutionDeadline = p.closeTime + 1 days;
        p.initialLiquidity = liquidity;
        p.feeBps = feeBps;

        (, Market m) = _create(p);

        uint256 held = usdc.balanceOf(address(m));
        uint256 yesSupply = token.totalSupply(m.yesTokenId());
        uint256 noSupply = token.totalSupply(m.noTokenId());
        assertGe(held, yesSupply);
        assertGe(held, noSupply);
        assertEq(m.priceYes() + m.priceNo(), 1e18);
        assertEq(uint8(m.state()), uint8(IMarket.State.Open));
    }
}
