// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DeploySC} from "../../script/DeploySC.s.sol";
import {SCManager} from "../../src/SCManager.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtSC} from "../mocks/MockMoreDebtSC.sol";
import {MockFailedMintSC} from "../mocks/MockFailedMintSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract SCManagerTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

    SCManager public scm;
    StableCoin public sc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        DeploySC deployer = new DeploySC();
        (sc, scm, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        // Should we put our integration tests here?
        // else {
        //     user = vm.addr(deployerKey);
        //     ERC20Mock mockErc = new ERC20Mock("MOCK", "MOCK", user, 100e18);
        //     MockV3Aggregator aggregatorMock = new MockV3Aggregator(
        //         helperConfig.DECIMALS(),
        //         helperConfig.ETH_USD_PRICE()
        //     );
        //     vm.etch(weth, address(mockErc).code);
        //     vm.etch(wbtc, address(mockErc).code);
        //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
        //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
        // }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(SCManager.SCManager__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new SCManager(tokenAddresses, feedAddresses, address(sc));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = scm.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 usdValue = scm.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockSc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockSc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        SCManager mockScm = new SCManager(
            tokenAddresses,
            feedAddresses,
            address(mockSc)
        );
        mockSc.mint(user, amountCollateral);

        vm.prank(owner);
        mockSc.transferOwnership(address(mockScm));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockSc)).approve(address(mockScm), amountCollateral);
        // Act / Assert
        vm.expectRevert(SCManager.SCManager__TransferFailed.selector);
        mockScm.depositCollateral(address(mockSc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);

        vm.expectRevert(SCManager.SCManager__NeedsMoreThanZero.selector);
        scm.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(SCManager.SCManager__TokenNotAllowed.selector, address(randToken)));
        scm.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = sc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalSCMinted, uint256 collateralValueInUsd) = scm.getAccountInformation(user);
        uint256 expectedDepositedAmount = scm.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalSCMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintSC Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedSCBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * scm.getAdditionalFeedPrecision())) / scm.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);

        uint256 expectedHealthFactor = scm.calculateHealthFactor(amountToMint, scm.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(SCManager.SCManager__BreaksHealthFactor.selector, expectedHealthFactor));
        scm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedSC() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedSC {
        uint256 userBalance = sc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintSC Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintSC mockSc = new MockFailedMintSC();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        SCManager mockScm = new SCManager(
            tokenAddresses,
            feedAddresses,
            address(mockSc)
        );
        mockSc.transferOwnership(address(mockScm));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockScm), amountCollateral);

        vm.expectRevert(SCManager.SCManager__MintFailed.selector);
        mockScm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(SCManager.SCManager__NeedsMoreThanZero.selector);
        scm.mintSC(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * scm.getAdditionalFeedPrecision())) / scm.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor = scm.calculateHealthFactor(amountToMint, scm.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(SCManager.SCManager__BreaksHealthFactor.selector, expectedHealthFactor));
        scm.mintSC(amountToMint);
        vm.stopPrank();
    }

    function testCanmintSC() public depositedCollateral {
        vm.prank(user);
        scm.mintSC(amountToMint);

        uint256 userBalance = sc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnSC Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(SCManager.SCManager__NeedsMoreThanZero.selector);
        scm.burnSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        scm.burnSC(1);
    }

    function testCanburnSC() public depositedCollateralAndMintedSC {
        vm.startPrank(user);
        sc.approve(address(scm), amountToMint);
        scm.burnSC(amountToMint);
        vm.stopPrank();

        uint256 userBalance = sc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockSc = new MockFailedTransfer();
        tokenAddresses = [address(mockSc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        SCManager mockScm = new SCManager(
            tokenAddresses,
            feedAddresses,
            address(mockSc)
        );
        mockSc.mint(user, amountCollateral);

        vm.prank(owner);
        mockSc.transferOwnership(address(mockScm));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockSc)).approve(address(mockScm), amountCollateral);
        // Act / Assert
        mockScm.depositCollateral(address(mockSc), amountCollateral);
        vm.expectRevert(SCManager.SCManager__TransferFailed.selector);
        mockScm.redeemCollateral(address(mockSc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(SCManager.SCManager__NeedsMoreThanZero.selector);
        scm.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        scm.redeemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, amountCollateral);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(scm));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        scm.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }
    ///////////////////////////////////
    // redeemCollateralForSC Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedSC {
        vm.startPrank(user);
        sc.approve(address(scm), amountToMint);
        vm.expectRevert(SCManager.SCManager__NeedsMoreThanZero.selector);
        scm.redeemCollateralForSC(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        sc.approve(address(scm), amountToMint);
        scm.redeemCollateralForSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = sc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedSC {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = scm.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedSC {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = scm.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalSCMinted) = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtSC mockSc = new MockMoreDebtSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        SCManager mockScm = new SCManager(
            tokenAddresses,
            feedAddresses,
            address(mockSc)
        );
        mockSc.transferOwnership(address(mockScm));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockScm), amountCollateral);
        mockScm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockScm), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockScm.depositCollateralAndMintSC(weth, collateralToCover, amountToMint);
        mockSc.approve(address(mockScm), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(SCManager.SCManager__HealthFactorNotImproved.selector);
        mockScm.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedSC {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(scm), collateralToCover);
        scm.depositCollateralAndMintSC(weth, collateralToCover, amountToMint);
        sc.approve(address(scm), amountToMint);

        vm.expectRevert(SCManager.SCManager__HealthFactorOk.selector);
        scm.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateralAndMintSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = scm.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(scm), collateralToCover);
        scm.depositCollateralAndMintSC(weth, collateralToCover, amountToMint);
        sc.approve(address(scm), amountToMint);
        scm.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = scm.getTokenAmountFromUsd(weth, amountToMint)
            + (scm.getTokenAmountFromUsd(weth, amountToMint) / scm.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = scm.getTokenAmountFromUsd(weth, amountToMint)
            + (scm.getTokenAmountFromUsd(weth, amountToMint) / scm.getLiquidationBonus());

        uint256 usdAmountLiquidated = scm.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = scm.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = scm.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70000000000000000020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorSCMinted,) = scm.getAccountInformation(liquidator);
        assertEq(liquidatorSCMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userSCMinted,) = scm.getAccountInformation(user);
        assertEq(userSCMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = scm.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = scm.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = scm.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = scm.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = scm.getAccountInformation(user);
        uint256 expectedCollateralValue = scm.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = scm.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(scm), amountCollateral);
        scm.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = scm.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = scm.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetSC() public {
        address scAddress = scm.getSC();
        assertEq(scAddress, address(sc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = scm.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
