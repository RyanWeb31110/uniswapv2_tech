// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Factory.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/periphery/UniswapV2Router.sol";
import "../../src/libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title UniswapV2RouterExactOutputTest
/// @notice 验证 Router 反向兑换路径的关键行为
contract UniswapV2RouterExactOutputTest is Test {
    UniswapV2Factory private factory;
    UniswapV2Router private router;
    ERC20Mock private tokenA;
    ERC20Mock private tokenB;
    ERC20Mock private tokenC;

    /// @notice 初始化合约并准备两条多跳路径的基础流动性
    function setUp() public {
        factory = new UniswapV2Factory(address(this));
        router = new UniswapV2Router(address(factory));

        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        tokenC = new ERC20Mock();

        tokenA.mint(address(this), 2_000 ether);
        tokenB.mint(address(this), 2_000 ether);
        tokenC.mint(address(this), 2_000 ether);

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        _provideLiquidity(address(tokenA), address(tokenB), 500 ether, 500 ether);
        _provideLiquidity(address(tokenB), address(tokenC), 500 ether, 500 ether);
    }

    /// @notice 单跳反向兑换应与库函数结果完全一致
    function testSwapTokensForExactTokensSingleHop() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountOut = 10 ether;
        uint256[] memory expected = UniswapV2Library.getAmountsIn(address(factory), amountOut, path);

        uint256 balanceBefore = tokenA.balanceOf(address(this));
        uint256[] memory amounts = router.swapTokensForExactTokens(amountOut, expected[0], path, address(this));

        assertEq(amounts[0], expected[0], "input amount mismatch");
        assertEq(amounts[1], amountOut, "output amount mismatch");
        assertEq(balanceBefore - tokenA.balanceOf(address(this)), expected[0], "balance delta mismatch");
    }

    /// @notice 多跳反向兑换应正确衔接中间交易对
    function testSwapTokensForExactTokensMultiHop() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountOut = 5 ether;
        uint256[] memory expected = UniswapV2Library.getAmountsIn(address(factory), amountOut, path);

        uint256[] memory amounts = router.swapTokensForExactTokens(amountOut, expected[0], path, address(this));

        assertEq(amounts[0], expected[0], "input amount mismatch");
        assertEq(amounts[2], amountOut, "final output mismatch");
    }

    /// @notice 用户设置的输入上限过小应当回滚
    function testSwapTokensForExactTokensRevertsWhenInputTooLow() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountOut = 10 ether;
        uint256[] memory expected = UniswapV2Library.getAmountsIn(address(factory), amountOut, path);

        vm.expectRevert(UniswapV2Router.ExcessiveInputAmount.selector);
        router.swapTokensForExactTokens(amountOut, expected[0] - 1, path, address(this));
    }

    /// @notice 将代币快速注入 Pair 的工具函数
    function _provideLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        router.addLiquidity(token0, token1, amount0, amount1, 0, 0, address(this));
    }
}
