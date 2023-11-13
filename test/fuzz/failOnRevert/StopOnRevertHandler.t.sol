// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {SCManager, AggregatorV3Interface} from "../../../src/SCManager.sol";
import {StableCoin} from "../../../src/StableCoin.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {console} from "forge-std/console.sol";

contract StopOnRevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Deployed contracts to interact with
    SCManager public scManager;
    StableCoin public sc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    // Ghost Variables
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(SCManager _scManager, StableCoin _sc) {
        scManager = _scManager;
        sc = _sc;

        address[] memory collateralTokens = scManager.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(scManager.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(scManager.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // FUNCTOINS TO INTERACT WITH

    ///////////////
    // SCManager //
    ///////////////
    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // must be more than 0
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(scManager), amountCollateral);
        scManager.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = scManager.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) {
            return;
        }
        scManager.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnSC(uint256 amountSc) public {
        // Must burn more than 0
        amountSc = bound(amountSc, 0, sc.balanceOf(msg.sender));
        if (amountSc == 0) {
            return;
        }
        scManager.burnSC(amountSc);
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = scManager.getMinHealthFactor();
        uint256 userHealthFactor = scManager.getHealthFactor(userToBeLiquidated);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        scManager.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    /////////////////////////////
    // StableCoin //
    /////////////////////////////
    function transferSc(uint256 amountSc, address to) public {
        if (to == address(0)) {
            to = address(1);
        }
        amountSc = bound(amountSc, 0, sc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        sc.transfer(to, amountSc);
    }

    /////////////////////////////
    // Aggregator //
    /////////////////////////////
    function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
        int256 intNewPrice = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(scManager.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    /// Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
