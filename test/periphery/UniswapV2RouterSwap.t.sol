// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Factory.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/periphery/UniswapV2Router.sol";
import "../../src/libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title UniswapV2RouterSwapTest
/// @notice 验证 Router 精确输入兑换的关键执行路径
contract UniswapV2RouterSwapTest is Test {
    UniswapV2Factory private factory;
    UniswapV2Router private router;
    ERC20Mock private tokenA;
    ERC20Mock private tokenB;
    ERC20Mock private tokenC;

    /// @notice 初始化核心合约并注入基础流动性
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

    /// @notice 单跳兑换应返回与库函数一致的数量
    function testSwapExactTokensSingleHop() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory expected = UniswapV2Library.getAmountsOut(address(factory), 10 ether, path);
        uint256 balanceBefore = tokenB.balanceOf(address(this));

        uint256[] memory amounts = router.swapExactTokensForTokens(10 ether, expected[1], path, address(this));

        assertEq(amounts.length, 2, "length mismatch");
        assertEq(amounts[1], expected[1], "final output mismatch");
        assertEq(tokenB.balanceOf(address(this)) - balanceBefore, expected[1], "balance mismatch");
    }

    /// @notice 多跳兑换应正确衔接中间交易对
    function testSwapExactTokensMultiHop() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256[] memory expected = UniswapV2Library.getAmountsOut(address(factory), 10 ether, path);

        uint256[] memory amounts = router.swapExactTokensForTokens(10 ether, expected[2], path, address(this));

        assertEq(amounts[0], 10 ether, "input amount mismatch");
        assertEq(amounts[2], expected[2], "final output mismatch");
    }

    /// @notice 用户设置的最小输出高于预期时应回滚
    function testSwapExactTokensRevertsWhenSlippageTooTight() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory expected = UniswapV2Library.getAmountsOut(address(factory), 10 ether, path);

        vm.expectRevert(UniswapV2Router.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(10 ether, expected[1] + 1 ether, path, address(this));
    }

    /// @notice 通过 Router 快速补充双边流动性的内部工具
    function _provideLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        router.addLiquidity(token0, token1, amount0, amount1, 0, 0, address(this));
    }
}
