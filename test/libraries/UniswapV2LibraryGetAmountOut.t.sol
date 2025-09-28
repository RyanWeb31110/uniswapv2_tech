// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/libraries/UniswapV2Library.sol";

/// @title UniswapV2LibraryGetAmountOutTest
/// @notice 验证 getAmountOut 的核心数学推导与异常分支
contract UniswapV2LibraryGetAmountOutTest is Test {
    function callGetAmountOut(
        uint256 amountIn,
        uint112 reserveIn,
        uint112 reserveOut
    ) public pure returns (uint256) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @notice 验证基础场景中 getAmountOut 的数学正确性
    function test_getAmountOut_basicCase() public pure {
        uint112 reserveIn = 5_000 ether;
        uint112 reserveOut = 10_000 ether;
        uint256 amountIn = 100 ether;

        uint256 result = UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);

        uint256 amountInWithFee = amountIn * 997;
        uint256 expected = (amountInWithFee * reserveOut) / (uint256(reserveIn) * 1000 + amountInWithFee);

        assertEq(result, expected, unicode"输出金额应与公式一致");
    }

    /// @notice 当输入为零时应直接回退，防止除以零
    function test_getAmountOut_revertWhenZeroAmount() public {
        vm.expectRevert(UniswapV2Library.InsufficientAmount.selector);
        this.callGetAmountOut(0, 1_000 ether, 1_000 ether);
    }

    /// @notice 当任一储备为零时应回退，提示流动性不足
    function test_getAmountOut_revertWhenZeroReserve() public {
        vm.expectRevert(UniswapV2Library.InsufficientLiquidity.selector);
        this.callGetAmountOut(1 ether, 0, 1_000 ether);
    }
}
