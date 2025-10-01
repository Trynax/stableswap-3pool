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

error StableSwap3Pool__InvalidAddress();
error StableSwap3Pool__CantSwapSameToken();
error StableSwap3Pool__InvalidToken(uint256 tokenId);
error StableSwap3Pool__SwapAmountMustBeGreaterThanZero();
error StableSwap3Pool__SlippageTooHigh();
error StableSwap3Pool__InvariantDMustIncrease();
error StableSwap3Pool__BurnAmountMustBeGreaterThanZero();
error StableSwap3Pool__InsufficientBalance();

contract StableSwap3Pool is ERC20, ReentrancyGuard, Ownable {
    // State variables
    // Constants
    uint256 private constant N_COINS = 3;
    uint256 private constant FEE_DENOMINATOR = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256[N_COINS] private constant RATES = [1e18, 1e30, 1e30];


    uint256 public A; // Amplification coefficient
    uint256 public fee;
    uint256 public admin_fee;

    IERC20[N_COINS] public coins;
    uint256[N_COINS] public balances;

    // Events
    event TokenSwap(
        address indexed buyer, uint256 sold_id, uint256 tokens_sold, uint256 bought_id, uint256 tokens_bought
    );
    event AddLiquidity(
        address indexed provider,
        uint256[N_COINS] token_amounts,
        uint256[N_COINS] fees,
        uint256 invariant,
        uint256 token_supply
    );
    event RemoveLiquidity(address indexed provider, uint256[N_COINS] token_amounts, uint256 token_supply);

    constructor(IERC20[N_COINS] memory _coins, uint256 _A, uint256 _fee, uint256 _admin_fee)
        ERC20("Curve.fi DAI/USDC/USDT", "3CRV")
        Ownable(msg.sender)
    {
        for (uint256 i = 0; i < N_COINS; i++) {
            if (address(_coins[i]) == address(0)) {
                revert StableSwap3Pool__InvalidAddress();
            }
            coins[i] = _coins[i];
        }
        A = _A;
        fee = _fee;
        admin_fee = _admin_fee;
    }

    //External functions

    /**
     * @notice Exchange tokens in the pool
     * @param i Index of token to sell
     * @param j Index of token to buy
     * @param dx Amount of token i to sell
     * @param minDy Minimum amount of token j expected (slippage protection)
     * @return dy Amount of token j received
     */
    function swap(uint256 i, uint256 j, uint256 dx, uint256 minDy) external nonReentrant returns (uint256 dy) {
        if (dx <= 0) {
            revert StableSwap3Pool__SwapAmountMustBeGreaterThanZero();
        }

        uint256[N_COINS] memory oldBalances = balances;
        uint256[N_COINS] memory xp = _xp(oldBalances);

        uint256 x = xp[i] + dx * RATES[i] / PRECISION;
        uint256 y = _getY(i, j, x, oldBalances);

        dy = (xp[j] - y) * PRECISION / RATES[j];

        if (dy < minDy) {
            revert StableSwap3Pool__SlippageTooHigh();
        }
        balances[i] = oldBalances[i] + dx;
        balances[j] = oldBalances[j] - dy;

        coins[i].transferFrom(msg.sender, address(this), dx);
        coins[j].transfer(msg.sender, dy);

        emit TokenSwap(msg.sender, i, dx, j, dy);
        return dy;
    }

    /**
     * @notice Add liquidity to the pool
     * @param amounts Amounts of each token to add
     * @param minMintAmount Minimum amount of LP tokens to mint
     * @return mintAmount Amount of LP tokens minted
     */
    function addLiquidity(uint256[N_COINS] memory amounts, uint256 minMintAmount)
        external
        nonReentrant
        returns (uint256 mintAmount)
    {
        uint256[N_COINS] memory oldBalances = balances;
        uint256 initialD = _getD(oldBalances);

        uint256[N_COINS] memory newBalances;

        for (uint256 i = 0; i < N_COINS; i++) {
            newBalances[i] = oldBalances[i] + amounts[i];
        }
        uint256 newD = _getD(newBalances);

        if (newD <= initialD) {
            revert StableSwap3Pool__InvariantDMustIncrease();
        }

        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            mintAmount = newD;
        } else {
            mintAmount = totalSupply * (newD - initialD) / initialD;
        }

        if (mintAmount < minMintAmount) {
            revert StableSwap3Pool__SlippageTooHigh();
        }
        for (uint256 i = 0; i < N_COINS; i++) {
            if (amounts[i] > 0) {
                coins[i].transferFrom(msg.sender, address(this), amounts[i]);
            }
        }

        balances = newBalances;
        _mint(msg.sender, mintAmount);

        uint256[N_COINS] memory fees; // will work on fees later
        emit AddLiquidity(msg.sender, amounts, fees, newD, totalSupply + mintAmount);

        return mintAmount;
    }

    /**
     * @notice Remove liquidity from the pool
     * @param burnAmount Amount of LP tokens to burn
     * @param minAmounts Minimum amounts of each token to receive
     * @return amounts Amounts of each token received
     */
    function removeLiquidity(uint256 burnAmount, uint256[N_COINS] memory minAmounts)
        external
        nonReentrant
        returns (uint256[N_COINS] memory amounts)
    {
        uint256 totalSupply = totalSupply();

        if (burnAmount <= 0) {
            revert StableSwap3Pool__BurnAmountMustBeGreaterThanZero();
        }
        if (burnAmount > balanceOf(msg.sender)) {
            revert StableSwap3Pool__InsufficientBalance();
        }

        for (uint256 i = 0; i < N_COINS; i++) {
            amounts[i] = balances[i] * burnAmount / totalSupply;
            if (amounts[i] < minAmounts[i]) {
                revert StableSwap3Pool__SlippageTooHigh();
            }
        }

        for (uint256 i = 0; i < N_COINS; i++) {
            if (amounts[i] > 0) {
                balances[i] -= amounts[i];
            }
        }

        _burn(msg.sender, burnAmount);

        for (uint256 i = 0; i < N_COINS; i++) {
            if (amounts[i] > 0) {
                coins[i].transfer(msg.sender, amounts[i]);
            }
        }
        emit RemoveLiquidity(msg.sender, amounts, totalSupply - burnAmount);
        return amounts;
    }


    /**
     * @notice Remove liquidity from the pool in one token
     * @param burnAmount Amount of LP tokens to burn
     * @param i Index of token to receive
     * @param minAmount Minimum amount of token i to receive
     * @return dy Amount of token i received
     */

     function removeLiquidityOneToken(uint256 burnAmount, uint256 i, uint256 minAmount)
        external
        nonReentrant
        returns (uint256 dy){

    }

    /**
     * @notice Remove speicific amounts of liquidity from the pool
     * @param amounts Amounts of each token to receive
     * @param maxBurnAmount Maximum amount of LP tokens to burn
     * @return burnAmount Amount of LP tokens burned
     */

     function removeLiquidityImbalance(uint256[N_COINS] memory amounts, uint256 maxBurnAmount)
        external
        nonReentrant
        returns (uint256 burnAmount){

        }



    // Internal functions

    /**
     * @notice Calculate the StableSwap invariant D
     * @param _balances an array of token balances
     * @return D the invariant
     */
    function _getD(uint256[N_COINS] memory _balances) internal view returns (uint256 D) {

        uint256[N_COINS] memory xp = _xp(_balances);
        uint256 sum = 0;

        for (uint256 i = 0; i < N_COINS; i++) {
            sum += xp[i];
        }

        if (sum == 0) return 0;

        D = sum;
        uint256 Ann = A * N_COINS;

        for (uint256 i = 0; i < 255; i++) {
            uint256 D_P = D;
            for (uint256 j = 0; j < N_COINS; j++) {
                D_P = D_P * D / (xp[j] * N_COINS);
            }

            uint256 D_prev = D;
            D = (Ann * sum + D_P * N_COINS) * D / ((Ann - 1) * D + (N_COINS + 1) * D_P);

            if (D > D_prev) {
                if (D - D_prev <= 1) break;
            } else {
                if (D_prev - D <= 1) break;
            }
        }
        return D;
    }

    /**
     * @notice Calculate the amount of token j received when trading token i
     * @param i Index of token being sold
     * @param j Index of token being bought
     * @param x New balance of token i (after adding the sold amount)
     * @param _balances Current balances of all tokens
     * @return y New balance of token j (after the trade)
     */
    function _getY(uint256 i, uint256 j, uint256 x, uint256[N_COINS] memory _balances)
        internal
        view
        returns (uint256 y)
    {
        if (i == j) {
            revert StableSwap3Pool__CantSwapSameToken();
        }

        if (i >= N_COINS) {
            revert StableSwap3Pool__InvalidToken(i);
        }
        if (j >= N_COINS) {
            revert StableSwap3Pool__InvalidToken(j);
        }

        uint256[N_COINS] memory xp = _xp(_balances);
        uint256 D = _getD(_balances);
        uint256 Ann = A * N_COINS;
        uint256 c = D;
        uint256 S = 0;

        for (uint256 k = 0; k < N_COINS; k++) {
            uint256 _x = 0;
            if (k == i) {
                _x = x; 
            } else if (k == j) {
                continue;
            } else {
                _x = xp[k];
            }
            S += _x;
            c = c * D / (_x * N_COINS);
        }

        c = c * D / (Ann * N_COINS);
        uint256 b = S + D / Ann;
        uint256 prevY = 0;
        y = D;

        for (uint256 _i = 0; _i < 255; _i++) {
            prevY = y;
            y = (y * y + c) / (2 * y + b - D);
            if (y > prevY) {
                if (y - prevY <= 1) break;
            } else {
                if (prevY - y <= 1) break;
            }
        }
        return y;
    }



    // Internal & private view & pure functions

    function _xp (uint256[N_COINS] memory _balances) internal pure returns (uint256[N_COINS] memory results){
        for (uint256 i = 0; i < N_COINS; i++) {
            results[i] = _balances[i] * RATES[i] / PRECISION;
        }
        return results;
    }




    // External & public view & pure functions  

    function getDy(uint256 i, uint256 j, uint256 dx) external view returns (uint256 dy) {
        uint256[N_COINS] memory xp = _xp(balances);
        uint256 x = xp[i] + dx * RATES[i] / PRECISION;
        uint256 y = _getY(i, j, x, balances);
        dy = (xp[j] - y - 1) * PRECISION / RATES[j];
        return dy;
    }

    function getA() external view returns (uint256) {
        return A;
    }
    function getFee() external view returns (uint256) {
        return fee;
    }
}
