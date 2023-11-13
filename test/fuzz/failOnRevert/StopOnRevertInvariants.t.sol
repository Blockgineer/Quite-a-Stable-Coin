// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Invariants:
// protocol must never be insolvent / undercollateralized

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SCManager} from "../../../src/SCManager.sol";
import {StableCoin} from "../../../src/StableCoin.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeploySC} from "../../../script/DeploySC.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {StopOnRevertHandler} from "./StopOnRevertHandler.t.sol";
import {console} from "forge-std/console.sol";

contract StopOnRevertInvariants is StdInvariant, Test {
    SCManager public scm;
    StableCoin public dsc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    address public constant USER = address(1);
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    StopOnRevertHandler public handler;

    function setUp() external {
        DeploySC deployer = new DeploySC();
        (dsc, scm, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        handler = new StopOnRevertHandler(scm, dsc);
        targetContract(address(handler));
        // targetContract(address(ethUsdPriceFeed)); Why can't we just do this?
    }

    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(scm));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(scm));

        uint256 wethValue = scm.getUsdValue(weth, wethDeposted);
        uint256 wbtcValue = scm.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersCantRevert() public view {
        scm.getAdditionalFeedPrecision();
        scm.getCollateralTokens();
        scm.getLiquidationBonus();
        scm.getLiquidationBonus();
        scm.getLiquidationThreshold();
        scm.getMinHealthFactor();
        scm.getPrecision();
        scm.getSC();
        // scm.getTokenAmountFromUsd();
        // scm.getCollateralTokenPriceFeed();
        // scm.getCollateralBalanceOfUser();
        // getAccountCollateralValue();
    }
}
