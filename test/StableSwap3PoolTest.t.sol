// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableSwap3Pool} from "../src/StableSwap3Pool.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract StableSwap3PoolTest is Test {
    StableSwap3Pool public pool;
    MockERC20 public dai;
    MockERC20 public usdc;
    MockERC20 public usdt;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public owner = makeAddr("owner");

    uint256 public A = 200;
    uint256 public fee = 4e6;
    uint256 public adminFee = 5e10;

    uint256 public daiAmount = 1000e18;
    uint256 public usdcAmount = 1000e6;
    uint256 public usdtAmount = 1000e6;

    function setUp() public {
        dai = new MockERC20("Dai", "DAI", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        usdt = new MockERC20("USDT", "USDT", 6);

        IERC20[3] memory tokens = [IERC20(dai), IERC20(usdc), IERC20(usdt)];

        vm.prank(owner);
        pool = new StableSwap3Pool(tokens, A, fee, adminFee);
        dai.mint(alice, daiAmount * 10);
        usdc.mint(alice, usdcAmount * 10);
        usdt.mint(alice, usdtAmount * 10);

        dai.mint(bob, daiAmount * 10);
        usdc.mint(bob, usdcAmount * 10);
        usdt.mint(bob, usdtAmount * 10);

        vm.startPrank(alice);
        dai.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        usdt.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        usdt.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function testConstructor() public {
        assertEq(pool.getA(), A);
        assertEq(pool.getFee(), fee);
        assertEq(pool.getAdminFee(), adminFee);
        assertEq(pool.owner(), owner);
        assertEq(pool.name(), "Curve.fi DAI/USDC/USDT");
        assertEq(pool.symbol(), "3CRV");
    }

    function testConstructorRevertIfInvalidAddress() public {
        IERC20[3] memory invalidTokens = [IERC20(address(0)), IERC20(usdc), IERC20(usdt)];

        vm.expectRevert();
        new StableSwap3Pool(invalidTokens, A, fee, adminFee);
    }

    function testAddLiquidityFirstDeposit() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];

        vm.prank(alice);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);

        assertGt(lpTokens, 2990e18);
        assertLt(lpTokens, 3010e18);

        (uint256 daiBalance, uint256 usdcBalance, uint256 usdtBalance) = pool.getBalances();
        assertEq(daiBalance, daiAmount);
        assertEq(usdcBalance, usdcAmount);
        assertEq(usdtBalance, usdtAmount);

        assertEq(pool.balanceOf(alice), lpTokens);
    }

    function testAddLiquidityBalancedDeposit() public {
        uint256[3] memory initialAmounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(initialAmounts, 0);

        uint256[3] memory amounts = [uint256(500e18), uint256(500e6), uint256(500e6)];
        uint256 aliceBalanceBefore = pool.balanceOf(alice);

        vm.prank(bob);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);

        assertGt(lpTokens, 1450e18);
        assertLt(lpTokens, 1550e18);

        assertEq(pool.balanceOf(bob), lpTokens);
        assertEq(pool.balanceOf(alice), aliceBalanceBefore);
    }

    function testAddLiquidityImbalancedDeposit() public {
        uint256[3] memory initialAmounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(initialAmounts, 0);

        uint256[3] memory amounts = [uint256(500e18), 0, 0];

        vm.prank(bob);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);

        assertLt(lpTokens, 500e18);
        assertGt(lpTokens, 480e18);
    }

    function testAddLiquidityRevertIfSlippageTooHigh() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];

        vm.prank(alice);
        vm.expectRevert();
        pool.addLiquidity(amounts, 10000e18);
    }

    function testSwapDAItoUSDC() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        uint256 dxAmount = 100e18;
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        uint256 dy = pool.swap(0, 1, dxAmount, 0);

        assertGt(dy, 99e6);
        assertLt(dy, 100e6);

        assertEq(usdc.balanceOf(bob), bobUsdcBefore + dy);
        assertEq(dai.balanceOf(bob), daiAmount * 10 - dxAmount);
    }

    function testSwapUSDCCtoUSDT() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);
        uint256 dxAmount = 50e6;

        vm.prank(bob);
        uint256 dy = pool.swap(1, 2, dxAmount, 0);
        assertGt(dy, 49.9e6);
        assertLt(dy, 50e6);
    }

    function testSwapRevertIfSameToken() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        vm.prank(bob);
        vm.expectRevert();
        pool.swap(0, 0, 100e18, 0);
    }

    function testSwapRevertIfInvalidToken() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        vm.prank(bob);
        vm.expectRevert();
        pool.swap(0, 3, 100e18, 0);
    }

    function testGetDy() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);
        uint256 expectedDy = pool.getDy(0, 1, 100e18);

        vm.prank(bob);
        uint256 actualDy = pool.swap(0, 1, 100e18, 0);
        assertApproxEqAbs(expectedDy, actualDy, 1);
    }

    function testRemoveLiquidity() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);

        uint256 burnAmount = lpTokens / 2;
        uint256[3] memory minAmounts = [uint256(0), uint256(0), uint256(0)];

        uint256 daiBalanceBefore = dai.balanceOf(alice);
        uint256 usdcBalanceBefore = usdc.balanceOf(alice);
        uint256 usdtBalanceBefore = usdt.balanceOf(alice);

        vm.prank(alice);
        pool.removeLiquidity(burnAmount, minAmounts);

        assertApproxEqRel(dai.balanceOf(alice) - daiBalanceBefore, daiAmount / 2, 0.01e18); // 1% tolerance
        assertApproxEqRel(usdc.balanceOf(alice) - usdcBalanceBefore, usdcAmount / 2, 0.01e18);
        assertApproxEqRel(usdt.balanceOf(alice) - usdtBalanceBefore, usdtAmount / 2, 0.01e18);
        assertEq(pool.balanceOf(alice), lpTokens - burnAmount);
    }

    function testRemoveLiquidityOneToken() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);

        uint256 burnAmount = lpTokens / 10;

        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 usdcReceived = pool.removeLiquidityOneToken(burnAmount, 1, 0);

        assertGt(usdcReceived, 95e6);
        assertLt(usdcReceived, 305e6);

        assertEq(usdc.balanceOf(alice), usdcBefore + usdcReceived);

        assertEq(pool.balanceOf(alice), lpTokens - burnAmount);
    }

    function testRemoveLiquidityOneTokenRevertIfInsufficientBalance() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);

        vm.prank(alice);
        vm.expectRevert();
        pool.removeLiquidityOneToken(lpTokens + 1, 1, 0);
    }

    function testRemoveLiquidityOneTokenSlippageProtection() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);

        vm.prank(alice);
        vm.expectRevert();
        pool.removeLiquidityOneToken(lpTokens / 10, 1, 300e6);
    }

    function testRemoveLiquidityImbalance() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        uint256 lpTokens = pool.addLiquidity(amounts, 0);
        console.log("lpTokens:", lpTokens, pool.balanceOf(alice), pool.totalSupply());

        uint256[3] memory withdrawAmounts = [uint256(200e18), uint256(50e6), uint256(0)];

        uint256 daiBefore = dai.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdtBefore = usdt.balanceOf(alice);

        vm.prank(alice);
        uint256 burnAmount = pool.removeLiquidityImbalance(withdrawAmounts, lpTokens);

        assertEq(dai.balanceOf(alice) - daiBefore, 200e18);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 50e6);
        assertEq(usdt.balanceOf(alice) - usdtBefore, 0);

        uint256 proportionalBurn = lpTokens * 250 / 3000;
        console.log("burnAmount:", burnAmount);
        console.log("proportionalBurn:", proportionalBurn);
        assertGt(burnAmount, proportionalBurn);
    }

    function testWithdrawAdminFee() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        vm.prank(bob);
        pool.swap(0, 1, 100e18, 0);

        uint256 adminUsdcBefore = pool.adminBalances(1);
        assertGt(adminUsdcBefore, 0);

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        pool.withdrawAdminFee(address(owner));

        assertGt(usdc.balanceOf(owner), ownerUsdcBefore);

        assertEq(pool.adminBalances(1), 0);
    }

    function testWithdrawAdminFeeRevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.withdrawAdminFee(address(owner));
    }

    function testSwapZeroAmount() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        vm.prank(bob);
        vm.expectRevert();
        pool.swap(0, 1, 0, 0);
    }

    function testGetDyRevertForZeroInput() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        vm.expectRevert();
        uint256 dy = pool.getDy(0, 1, 0);
    }

    function testGetBalances() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        (uint256 daiBalance, uint256 usdcBalance, uint256 usdtBalance) = pool.getBalances();
        assertEq(daiBalance, daiAmount);
        assertEq(usdcBalance, usdcAmount);
        assertEq(usdtBalance, usdtAmount);
    }

    function testAdminBalances() public {
        uint256[3] memory amounts = [daiAmount, usdcAmount, usdtAmount];
        vm.prank(alice);
        pool.addLiquidity(amounts, 0);

        vm.prank(bob);
        pool.swap(0, 1, 100e18, 0);

        uint256 adminDai = pool.adminBalances(0);
        uint256 adminUsdc = pool.adminBalances(1);
        uint256 adminUsdt = pool.adminBalances(2);

        assertGt(adminUsdc, 0);
    }
}
