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
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {console} from "forge-std/console.sol";

error StableSwap3Pool__InvalidAddress();
error StableSwap3Pool__CantSwapSameToken();
error StableSwap3Pool__InvalidToken(uint256 tokenId);
error StableSwap3Pool__SwapAmountMustBeGreaterThanZero();
error StableSwap3Pool__SlippageTooHigh();
error StableSwap3Pool__InvariantDMustIncrease();
error StableSwap3Pool__BurnAmountMustBeGreaterThanZero();
error StableSwap3Pool__InsufficientBalance();
error StableSwap3Pool__RampingTooSoon();
error StableSwap3Pool__RampinngParameterIsOutOfRange();
error StableSwap3Pool__AChangeTooBig();

contract StableSwap3Pool is ERC20, ReentrancyGuard, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    // State variables 
    // Slot 0: Pack all A parameters together
    uint32 private A;         // 4 bytes 
    uint32 private futureA;   // 4 bytes  
    uint32 private initialA;  // 4 bytes
    uint160 private _reservedA; // 20 bytes 
    
    // Slot 1: Pack time variables together 
    uint40 private initialATime; // 5 bytes 
    uint40 private futureATime;  // 5 bytes
    uint176 private _reservedTime; // 22 bytes
    
    // Slot 2: Pack fee variables together 
    uint32 private fee;        // 4 bytes 
    uint32 private adminFee;   // 4 bytes
    uint192 private _reservedFee; // 24 bytes

    // Constants 
    uint8 private constant N_COINS = 3;
    uint64 private constant FEE_DENOMINATOR = 1e10;
    uint64 private constant PRECISION = 1e18;
    
    // RATES 
    uint128[N_COINS] private RATES;
    
    uint32 private constant MAX_A = 1e6;
    uint8 private constant MAX_A_CHANGE = 10;
    uint256 private constant MIN_RAMP_TIME = 1 days;

    IERC20[N_COINS] private coins;
    uint256[N_COINS] private balances;

    // Events
    event TokenSwap(address indexed buyer, uint256 soldId, uint256 tokensSold, uint256 boughtId, uint256 tokensBought);
    event AddLiquidity(
        address indexed provider,
        uint256[N_COINS] tokenAmounts,
        uint256[N_COINS] fees,
        uint256 invariant,
        uint256 tokenSupply
    );
    event RemoveLiquidity(address indexed provider, uint256[N_COINS] tokenAmounts, uint256 tokenSupply);
    event RemoveLiquidityOne(address indexed provider, uint256 tokenAmount, uint256 coinId, uint256 tokenSupply);
    event RemoveLiquidityImbalance(address indexed provider, uint256[N_COINS] tokenAmounts, uint256 burnAmount);
    event RampA(uint256 initialA, uint256 futureA, uint256 initialATime, uint256 futureATime);
    event StopRampA(uint256 currentA, uint256 time);

    constructor(IERC20[N_COINS] memory _coins, uint32 _Acoeff, uint32 _fee, uint32 _adminFee)
        ERC20("Curve.fi DAI/USDC/USDT", "3CRV")
        Ownable(msg.sender)
    {
        RATES[0] = 1e18; // DAI
        RATES[1] = 1e30; // USDC 
        RATES[2] = 1e30; // USDT
        for (uint8 i = 0; i < N_COINS; ++i) {
            if (address(_coins[i]) == address(0)) {
                revert StableSwap3Pool__InvalidAddress();
            }
            coins[i] = _coins[i];
        }
        A = _Acoeff;
        futureA = _Acoeff;
        initialA = _Acoeff;
        fee = _fee;
        adminFee = _adminFee;
        initialATime = uint40(block.timestamp);
        futureATime = uint40(block.timestamp);
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
    function swap(uint8 i, uint8 j, uint256 dx, uint256 minDy) external nonReentrant returns (uint256 dy) {
        if (dx <= 0) {
            revert StableSwap3Pool__SwapAmountMustBeGreaterThanZero();
        }

        uint256[N_COINS] memory oldBalances = balances;
        uint256[N_COINS] memory xp = _xp(oldBalances);

        uint256 x = xp[i] + dx.mulDiv(RATES[i], PRECISION);
        uint256 y = _getY(i, j, x, oldBalances);

        dy = (xp[j] - y).mulDiv(PRECISION, RATES[j]);

        uint256 _fee = dy.mulDiv(uint256(fee), FEE_DENOMINATOR);
        dy = dy - _fee;

        uint256 adminFeeAmount = _fee.mulDiv(uint256(adminFee), FEE_DENOMINATOR);

        if (dy < minDy) {
            revert StableSwap3Pool__SlippageTooHigh();
        }
        balances[i] = oldBalances[i] + dx;
        balances[j] = oldBalances[j] - dy - adminFeeAmount;

        address(coins[i]).safeTransferFrom(msg.sender, address(this), dx);
        address(coins[j]).safeTransfer(msg.sender, dy);

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
        uint256[N_COINS] memory fees;

        for (uint8 i = 0; i < N_COINS; ++i) {
            newBalances[i] = oldBalances[i] + amounts[i];
        }
        uint256 newD = _getD(newBalances);

        if (newD <= initialD) {
            revert StableSwap3Pool__InvariantDMustIncrease();
        }

        uint256 totalSupply = totalSupply();
        uint256 D2 = newD;

        if (totalSupply > 0) {
            uint256 _fee = uint256(fee).mulDiv(N_COINS, 4 * (N_COINS - 1)); //
            for (uint8 i = 0; i < N_COINS; ++i) {
                uint256 idealBalance = newD.mulDiv(oldBalances[i], initialD);
                uint256 difference = 0;

                if (idealBalance > newBalances[i]) {
                    difference = idealBalance - newBalances[i];
                } else {
                    difference = newBalances[i] - idealBalance;
                }

                fees[i] = _fee.mulDiv(difference, FEE_DENOMINATOR);

                uint256 adminFeeAmount = fees[i].mulDiv(uint256(adminFee), FEE_DENOMINATOR);

                balances[i] = newBalances[i] - adminFeeAmount;
                newBalances[i] -= fees[i];
            }

            D2 = _getD(newBalances);
        } else {
            balances = newBalances;
        }

        if (totalSupply == 0) {
            mintAmount = D2;
        } else {
            mintAmount = totalSupply.mulDiv(D2 - initialD, initialD);
        }

        if (mintAmount < minMintAmount) {
            revert StableSwap3Pool__SlippageTooHigh();
        }

        for (uint8 i = 0; i < N_COINS; ++i) {
            if (amounts[i] > 0) {
                coins[i].transferFrom(msg.sender, address(this), amounts[i]);
            }
        }

        _mint(msg.sender, mintAmount);
        emit AddLiquidity(msg.sender, amounts, fees, D2, totalSupply + mintAmount);

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

        for (uint8 i = 0; i < N_COINS; ++i) {
            amounts[i] = balances[i].mulDiv(burnAmount, totalSupply);
            if (amounts[i] < minAmounts[i]) {
                revert StableSwap3Pool__SlippageTooHigh();
            }
        }

        for (uint8 i = 0; i < N_COINS; ++i) {
            if (amounts[i] > 0) {
                balances[i] -= amounts[i];
            }
        }

        _burn(msg.sender, burnAmount);

        for (uint8 i = 0; i < N_COINS; ++i) {
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
    function removeLiquidityOneToken(uint256 burnAmount, uint8 i, uint256 minAmount)
        external
        nonReentrant
        returns (uint256 dy)
    {
        if (burnAmount <= 0) {
            revert StableSwap3Pool__BurnAmountMustBeGreaterThanZero();
        }
        if (burnAmount > balanceOf(msg.sender)) {
            revert StableSwap3Pool__InsufficientBalance();
        }
        if (i >= N_COINS) {
            revert StableSwap3Pool__InvalidToken(i);
        }

        uint256 totalSupply = totalSupply();
        uint256[N_COINS] memory xp = _xp(balances);

        uint256 initialD = _getD(balances);
        uint256 newD = initialD - burnAmount.mulDiv(initialD, totalSupply);

        uint256 newY = _getYD(i, newD, xp);
        uint256 initialDy = (xp[i] - newY).mulDiv(PRECISION, RATES[i]);

        uint256 _fee = uint256(fee).mulDiv(N_COINS, 4 * (N_COINS - 1));

        uint256 idealWithdrawal = balances[i].mulDiv(burnAmount, totalSupply);

        uint256 difference = initialDy > idealWithdrawal ? initialDy - idealWithdrawal : idealWithdrawal - initialDy;

        uint256 feeAmount = _fee.mulDiv(difference, FEE_DENOMINATOR);
        dy = initialDy - feeAmount;

        uint256 adminFeeAmount = feeAmount.mulDiv(uint256(adminFee), FEE_DENOMINATOR);

        if (dy < minAmount) {
            revert StableSwap3Pool__SlippageTooHigh();
        }
        balances[i] -= (dy + adminFeeAmount);
        _burn(msg.sender, burnAmount);
        coins[i].transfer(msg.sender, dy);

        emit RemoveLiquidityOne(msg.sender, dy, i, totalSupply - burnAmount);
        return dy;
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
        returns (uint256 burnAmount)
    {
        uint256 totalSupply = totalSupply();
        uint256[N_COINS] memory oldBalances = balances;
        uint256[N_COINS] memory newBalances;
        uint256 _fee = uint256(fee).mulDiv(N_COINS, 4 * (N_COINS - 1));
        uint256 _adminFee = uint256(adminFee);

        for (uint8 i = 0; i < N_COINS; ++i) {
            if (amounts[i] > oldBalances[i]) {
                revert StableSwap3Pool__InsufficientBalance();
            }
            newBalances[i] = oldBalances[i] - amounts[i];
        }

        uint256 D0 = _getD(oldBalances);
        uint256 D1 = _getD(newBalances);

        uint256[N_COINS] memory fees;

        for (uint8 i = 0; i < N_COINS; ++i) {
            uint256 idealBalance = D1.mulDiv(oldBalances[i], D0);

            uint256 difference =
                idealBalance > newBalances[i] ? idealBalance - newBalances[i] : newBalances[i] - idealBalance;

            fees[i] = _fee.mulDiv(difference, FEE_DENOMINATOR);
            uint256 adminFeeAmount = fees[i].mulDiv(_adminFee, FEE_DENOMINATOR);

            balances[i] = newBalances[i] - adminFeeAmount;
            newBalances[i] -= fees[i];
        }

        uint256 D2 = _getD(newBalances);

        burnAmount = (D0 - D2).mulDiv(totalSupply, D0);

        if (burnAmount <= 0) {
            revert StableSwap3Pool__BurnAmountMustBeGreaterThanZero();
        }
        burnAmount = burnAmount + 1;
        if (burnAmount > maxBurnAmount) {
            revert StableSwap3Pool__SlippageTooHigh();
        }

        if (burnAmount > balanceOf(msg.sender)) {
            revert StableSwap3Pool__InsufficientBalance();
        }

        _burn(msg.sender, burnAmount);

        for (uint8 i = 0; i < N_COINS; ++i) {
            if (amounts[i] > 0) {
                coins[i].transfer(msg.sender, amounts[i]);
            }
        }

        emit RemoveLiquidityImbalance(msg.sender, amounts, burnAmount);
        return burnAmount;
    }

    /**
     * @notice withdraw admin fee collected from trades
     * @param recipient address to receive the admin fees
     */
    function withdrawAdminFee(address recipient) external onlyOwner {
        for (uint8 i = 0; i < N_COINS; ++i) {
            uint256 adminBalance = coins[i].balanceOf(address(this)) - balances[i];
            if (adminBalance > 0) {
                coins[i].transfer(recipient, adminBalance);
            }
        }
    }

    function rampA(uint256 _futureA, uint256 _futureATime) external onlyOwner {
        // Check parameter validity first
        if (_futureA <= 0 || _futureA > MAX_A) {
            revert StableSwap3Pool__RampinngParameterIsOutOfRange();
        }

        // Check if there's an active ramp that hasn't finished yet
        if (block.timestamp < futureATime && initialATime + MIN_RAMP_TIME > block.timestamp) {
            revert StableSwap3Pool__RampingTooSoon();
        }
        
        // Check minimum ramp duration
        if (_futureATime < block.timestamp + MIN_RAMP_TIME) {
            revert StableSwap3Pool__RampingTooSoon();
        }

        uint256 _initialA = _A();

        bool validIncrease = (_futureA >= _initialA && _futureA <= _initialA * MAX_A_CHANGE);
        bool validDecrease = (_futureA < _initialA && _futureA * MAX_A_CHANGE >= _initialA);

        if (!validIncrease && !validDecrease) {
            revert StableSwap3Pool__AChangeTooBig();
        }

        initialA = uint32(_initialA);
        futureA = uint32(_futureA);
        initialATime = uint40(block.timestamp);
        futureATime = uint40(_futureATime);

        emit RampA(_initialA, _futureA, block.timestamp, _futureATime);
    }

    function stopRampA() external onlyOwner {
        uint256 currentA = _A();
        initialA = uint32(currentA);
        futureA = uint32(currentA);
        initialATime = uint40(block.timestamp);
        futureATime = uint40(block.timestamp);

        emit StopRampA(currentA, block.timestamp);
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

        for (uint8 i = 0; i < N_COINS; ++i) {
            sum += xp[i];
        }

        if (sum == 0) return 0;

        D = sum;
        uint256 Ann = _A() * N_COINS;

        for (uint8 i = 0; i < 255; ++i) {
            uint256 D_P = D;
            for (uint8 j = 0; j < N_COINS; j++) {
                D_P = D_P.mulDiv(D, xp[j] * N_COINS);
            }

            uint256 D_prev = D;
            D = (Ann * sum + D_P * N_COINS).mulDiv(D, (Ann - 1) * D + (N_COINS + 1) * D_P);

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
    function _getY(uint8 i, uint8 j, uint256 x, uint256[N_COINS] memory _balances)
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
        uint256 Ann = _A() * N_COINS;
        uint256 c = D;
        uint256 S = 0;

        for (uint8 k = 0; k < N_COINS; k++) {
            uint256 _x = 0;
            if (k == i) {
                _x = x;
            } else if (k == j) {
                continue;
            } else {
                _x = xp[k];
            }
            S += _x;
            c = c.mulDiv(D, _x * N_COINS);
        }

        c = c.mulDiv(D, Ann * N_COINS);
        uint256 b = S + D / Ann;
        uint256 prevY = 0;
        y = D;

        for (uint8 _i = 0; _i < 255; ++_i) {
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

    /**
     * @notice Calculate token balance given D value
     * @param i Index of token to calculate
     * @param D Target invariant
     * @param xp normalized balances of all tokens
     * @return y Balance of token i for target D
     */
    function _getYD(uint8 i, uint256 D, uint256[N_COINS] memory xp) internal view returns (uint256 y) {
        if (i >= N_COINS) {
            revert StableSwap3Pool__InvalidToken(i);
        }

        uint256 Ann = _A() * N_COINS;
        uint256 c = D;
        uint256 S = 0;

        for (uint8 j = 0; j < N_COINS; j++) {
            if (j != i) {
                S += xp[j];
                c = c.mulDiv(D, xp[j] * N_COINS);
            }
        }

        c = c.mulDiv(D, Ann * N_COINS);
        uint256 b = S + D / Ann;
        uint256 prevY = 0;
        y = D;

        for (uint8 _i = 0; _i < 255; ++_i) {
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

    function _xp(uint256[N_COINS] memory _balances) internal view returns (uint256[N_COINS] memory results) {
        for (uint8 i = 0; i < N_COINS; ++i) {
            results[i] = _balances[i].mulDiv(RATES[i], PRECISION);
        }
        return results;
    }

    function _A() internal view returns (uint256) {
        uint256 t1 = futureATime;
        uint256 A1 = futureA;

        if (block.timestamp < t1) {
            uint256 t0 = initialATime;
            uint256 A0 = initialA;
            if (A1 > A0) {
                return A0 + (A1 - A0).mulDiv(block.timestamp - t0, t1 - t0);
            } else {
                return A0 - (A0 - A1).mulDiv(block.timestamp - t0, t1 - t0);
            }
        } else {
            return A1;
        }
    }
    // External & public view & pure functions

    function getDy(uint256 i, uint256 j, uint256 dx) external view returns (uint256 dy) {
        if (dx <= 0) {
            revert StableSwap3Pool__SwapAmountMustBeGreaterThanZero();
        }
        uint256[N_COINS] memory xp = _xp(balances);
        uint256 x = xp[i] + dx.mulDiv(RATES[i], PRECISION);
        uint256 y = _getY(uint8(i), uint8(j), x, balances);
        dy = (xp[j] - y - 1).mulDiv(PRECISION, RATES[j]);

        uint256 _fee = dy.mulDiv(uint256(fee), FEE_DENOMINATOR);
        dy = dy - _fee;
        return dy;
    }

    function getA() external view returns (uint256) {
        return _A();
    }

    function getFee() external view returns (uint256) {
        return fee;
    }

    function getAdminFee() external view returns (uint256) {
        return adminFee;
    }

    function adminBalances(uint8 i) external view returns (uint256) {
        return coins[i].balanceOf(address(this)) - balances[i];
    }

    function getBalances() external view returns (uint256, uint256, uint256) {
        return (balances[0], balances[1], balances[2]);
    }

    function getRampingInfo() external view returns (uint256, uint256, uint256, uint256) {
        return (initialA, futureA, initialATime, futureATime);
    }

    /**
     * @notice Calculate the current virtual price of the pool
     * @dev Virtual price always increases (except during depeg events)
     * @return Virtual price scaled by 1e18
     */
    function getVirtualPrice() external view returns (uint256) {
        uint256 D = _getD(balances);
        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) return PRECISION;
        return D.mulDiv(PRECISION, totalSupply);
    }

    /**
     * @notice Calculate LP tokens received/burned for given token amounts
     * @param amounts Token amounts to add/remove
     * @param isDeposit True for deposit, false for withdrawal
     * @return LP token amount (without fees)
     */
    function calcTokenAmount(uint256[N_COINS] memory amounts, bool isDeposit) external view returns (uint256) {
        uint256[N_COINS] memory _balances = balances;
        uint256 D0 = _getD(_balances);

        for (uint8 i = 0; i < N_COINS; ++i) {
            if (isDeposit) {
                _balances[i] += amounts[i];
            } else {
                _balances[i] -= amounts[i];
            }
        }

        uint256 D1 = _getD(_balances);
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            return D1; // First deposit
        }

        uint256 diff = isDeposit ? D1 - D0 : D0 - D1;
        return diff.mulDiv(totalSupply, D0);
    }

    /**
     * @notice Calculate tokens received when withdrawing one token type
     * @param burnAmount LP tokens to burn
     * @param i Index of token to receive
     * @return Token amount received (after fees)
     */
    function calcWithdrawOneCoin(uint256 burnAmount, uint8 i) external view returns (uint256) {
        if (i >= N_COINS) {
            revert StableSwap3Pool__InvalidToken(i);
        }

        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) return 0;

        uint256[N_COINS] memory xp = _xp(balances);
        uint256 D0 = _getD(balances);
        uint256 D1 = D0 - burnAmount.mulDiv(D0, totalSupply);

        uint256 newY = _getYD(i, D1, xp);
        uint256 dy0 = (xp[i] - newY).mulDiv(PRECISION, RATES[i]);

        uint256 _fee = uint256(fee).mulDiv(N_COINS, 4 * (N_COINS - 1));

        uint256 idealWithdrawal = balances[i].mulDiv(burnAmount, totalSupply);

        uint256 difference = dy0 > idealWithdrawal ? dy0 - idealWithdrawal : idealWithdrawal - dy0;
        uint256 feeAmount = _fee.mulDiv(difference, FEE_DENOMINATOR);

        return dy0 - feeAmount;
    }

    /**
     * @notice Get detailed information about current balances and state
     */
    function getPoolState()
        external
        view
        returns (
            uint256[N_COINS] memory poolBalances,
            uint256[N_COINS] memory adminFees,
            uint256 currentA,
            uint256 currentFee,
            uint256 currentAdminFee,
            uint256 virtualPrice,
            uint256 totalPoolTokenSupply
        )
    {
        poolBalances = balances;

        for (uint8 i = 0; i < N_COINS; ++i) {
            adminFees[i] = this.adminBalances(i);
        }

        currentA = _A();
        currentFee = fee;
        currentAdminFee = adminFee;
        virtualPrice = this.getVirtualPrice();
        totalPoolTokenSupply = totalSupply();
    }

    /**
     * @notice Calculate the invariant D for external use
     * @param _balances Token balances to calculate D for
     * @return Invariant D
     */
    function calculateInvariant(uint256[N_COINS] memory _balances) external view returns (uint256) {
        return _getD(_balances);
    }
}
