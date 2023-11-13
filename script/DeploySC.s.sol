// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {StableCoin} from "../src/StableCoin.sol";
import {SCManager} from "../src/SCManager.sol";

contract DeploySC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (StableCoin, SCManager, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        StableCoin sc = new StableCoin();
        SCManager scManager = new SCManager(
            tokenAddresses,
            priceFeedAddresses,
            address(sc)
        );
        sc.transferOwnership(address(scManager));
        vm.stopBroadcast();
        return (sc, scManager, helperConfig);
    }
}
