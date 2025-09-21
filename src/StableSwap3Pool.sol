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
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StableSwap3Pool is ERC20, ReentrancyGuard, Ownable {


    // States variables
    uint256 private constant N_COINS =3;
    uint256 private constant FEE_DENOMINATOR = 1e10;
    uint256 private constant PRECISION = 1e18;




    constructor()ERC20("Curve.fi DAI/USDC/USDT", "3CRV") Ownable(msg.sender) {}
}


