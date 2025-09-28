// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Factory.sol";
import "../../src/periphery/UniswapV2Router.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title UniswapV2RouterAddLiquidityTest
/// @notice 验证 Router 添加流动性的关键执行路径
contract UniswapV2RouterAddLiquidityTest is Test {
    UniswapV2Factory private factory;
    UniswapV2Router private router;
    ERC20Mock private tokenA;
    ERC20Mock private tokenB;

    /// @notice 部署基础合约并为默认账户准备足够的测试代币
    function setUp() public {
        factory = new UniswapV2Factory(address(this));
        router = new UniswapV2Router(address(factory));
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();

        tokenA.mint(address(this), 1_000 ether);
        tokenB.mint(address(this), 1_000 ether);

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
    }

    /// @notice 首次注入应沿用期望值并成功铸造 LP
    function testAddLiquidityBootstrap() public {
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            120 ether,
            100 ether,
            110 ether,
            90 ether,
            address(this)
        );

        assertEq(amountA, 120 ether, "amountA");
        assertEq(amountB, 100 ether, "amountB");
        assertGt(liquidity, 0, "liquidity");
    }

    /// @notice 再次注入时应按照储备比例回传实际金额
    function testAddLiquidityWithExistingReserves() public {
        router.addLiquidity(
            address(tokenA),
            address(tokenB),
            120 ether,
            100 ether,
            110 ether,
            90 ether,
            address(this)
        );

        (uint112 reserveA, uint112 reserveB) = UniswapV2Library.getReserves(address(factory), address(tokenA), address(tokenB));

        uint256 amountBOptimal = UniswapV2Library.quote(120 ether, reserveA, reserveB);
        uint256 expectedAmountA;
        uint256 expectedAmountB;
        if (amountBOptimal <= 80 ether) {
            expectedAmountA = 120 ether;
            expectedAmountB = amountBOptimal;
        } else {
            expectedAmountA = UniswapV2Library.quote(80 ether, reserveB, reserveA);
            expectedAmountB = 80 ether;
        }
        // 当前参数组合下，expectedAmountA = 96 ether，expectedAmountB = 80 ether

        (uint256 amountA, uint256 amountB,) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            120 ether,
            80 ether,
            90 ether,
            70 ether,
            address(this)
        );

        assertApproxEqAbs(amountA, expectedAmountA, 1, "amountA optimal");
        assertApproxEqAbs(amountB, expectedAmountB, 1, "amountB optimal");
    }

    /// @notice 滑点阈值过紧时应触发回滚，便于前端提示用户调整参数
    function testAddLiquidityRevertWhenSlippageTooTight() public {
        // 预先注入一笔流动性，确保池内储备已有稳定比例
        router.addLiquidity(
            address(tokenA),
            address(tokenB),
            120 ether,
            100 ether,
            110 ether,
            90 ether,
            address(this)
        );

        // 再次注入时给出过紧的滑点阈值，应触发回滚
        vm.expectRevert(UniswapV2Router.InsufficientBAmount.selector);
        router.addLiquidity(
            address(tokenA),
            address(tokenB),
            100 ether,
            90 ether,
            99 ether,
            85 ether,
            address(this)
        );
    }

    /// @notice 移除流动性后应按比例返还资产并清空 LP 余额
    function testRemoveLiquidityBasic() public {
        (, , uint256 liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            120 ether,
            100 ether,
            110 ether,
            90 ether,
            address(this)
        );

        address pair = factory.getPair(address(tokenA), address(tokenB));
        UniswapV2Pair pairContract = UniswapV2Pair(pair);
        pairContract.approve(address(router), liquidity);

        uint256 totalSupplyBefore = pairContract.totalSupply();
        (uint112 reserveA, uint112 reserveB) = UniswapV2Library.getReserves(
            address(factory),
            address(tokenA),
            address(tokenB)
        );
        // MINIMUM_LIQUIDITY 永久锁定在池中，因此需按 LP 占比计算预期返还数量
        uint256 expectedAmountA = (liquidity * uint256(reserveA)) / totalSupplyBefore;
        uint256 expectedAmountB = (liquidity * uint256(reserveB)) / totalSupplyBefore;

        uint256 balanceABefore = tokenA.balanceOf(address(this));
        uint256 balanceBBefore = tokenB.balanceOf(address(this));

        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            address(tokenA),
            address(tokenB),
            liquidity,
            0,
            0,
            address(this)
        );

        assertApproxEqAbs(amountA, expectedAmountA, 1, "amountA returned");
        assertApproxEqAbs(amountB, expectedAmountB, 1, "amountB returned");
        assertEq(pairContract.balanceOf(address(this)), 0, "LP balance should be zero");
        assertApproxEqAbs(tokenA.balanceOf(address(this)), balanceABefore + amountA, 1, "tokenA balance mismatch");
        assertApproxEqAbs(tokenB.balanceOf(address(this)), balanceBBefore + amountB, 1, "tokenB balance mismatch");
    }

    /// @notice 滑点阈值过紧时应回滚
    function testRemoveLiquidityRevertWhenSlippageTooTight() public {
        (, , uint256 liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            120 ether,
            100 ether,
            110 ether,
            90 ether,
            address(this)
        );

        address pair = factory.getPair(address(tokenA), address(tokenB));
        UniswapV2Pair pairContract = UniswapV2Pair(pair);
        pairContract.approve(address(router), liquidity);

        (uint112 reserveA, uint112 reserveB) = UniswapV2Library.getReserves(address(factory), address(tokenA), address(tokenB));
        (address token0,) = UniswapV2Library.sortTokens(address(tokenA), address(tokenB));
        uint256 totalSupplyBefore = pairContract.totalSupply();
        uint256 expectedAmountB = token0 == address(tokenA)
            ? (liquidity * uint256(reserveB)) / totalSupplyBefore
            : (liquidity * uint256(reserveA)) / totalSupplyBefore;

        vm.expectRevert(UniswapV2Router.InsufficientBAmount.selector);
        router.removeLiquidity(
            address(tokenA),
            address(tokenB),
            liquidity,
            0,
            expectedAmountB + 1,
            address(this)
        );
    }

}
