// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title StableCoin
 * @author Blockgineer
 * Pegged to USD
 * Collateral: WBTC and ETH
 *
 * This contract is owned by the  SCManager. It is a ERC20 token that can be minted and burned by the SCManager smart contract.
 */
contract StableCoin is ERC20Burnable, Ownable {
    error StableCoin__AmountMustBeMoreThanZero();
    error StableCoin__BurnAmountExceedsBalance();
    error StableCoin__NotZeroAddress();

    constructor() ERC20("StableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert StableCoin__AmountMustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert StableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert StableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert StableCoin__AmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
