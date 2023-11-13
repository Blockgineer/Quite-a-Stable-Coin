// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {StableCoin} from "../../src/StableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract StableCoinTest is StdCheats, Test {
    StableCoin sc;

    function setUp() public {
        sc = new StableCoin();
    }

    function testMustMintMoreThanZero() public {
        vm.prank(sc.owner());
        vm.expectRevert();
        sc.mint(address(this), 0);
    }

    function testMustBurnMoreThanZero() public {
        vm.startPrank(sc.owner());
        sc.mint(address(this), 100);
        vm.expectRevert();
        sc.burn(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanYouHave() public {
        vm.startPrank(sc.owner());
        sc.mint(address(this), 100);
        vm.expectRevert();
        sc.burn(101);
        vm.stopPrank();
    }

    function testCantMintToZeroAddress() public {
        vm.startPrank(sc.owner());
        vm.expectRevert();
        sc.mint(address(0), 100);
        vm.stopPrank();
    }
}
