// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/core/UniswapV2Pair.sol";
import "../src/core/UniswapV2Factory.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title UniswapV2Pair 测试合约
 * @notice 使用 Foundry 框架测试交易对合约的流动性管理功能
 * @dev 包含初始流动性、平衡流动性、不平衡流动性的完整测试覆盖
 */
contract UniswapV2PairTest is Test {
    // ============ 测试合约实例 ============

    /// @notice 测试用的第一个代币
    ERC20Mock token0;

    /// @notice 测试用的第二个代币
    ERC20Mock token1;

    /// @notice 被测试的交易对合约
    UniswapV2Pair pair;

    /// @notice 工厂合约
    UniswapV2Factory factory;

    /// @notice 测试账户地址
    address testUser = address(0x1234);

    // ============ 测试环境设置 ============

    /**
     * @notice 测试环境初始化
     * @dev 每个测试函数执行前都会调用此函数
     */
    function setUp() public {
        // 创建两个测试代币
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();

        // 确保token0地址小于token1地址（符合Uniswap标准）
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // 创建工厂合约
        factory = new UniswapV2Factory(address(this));

        // 通过工厂创建交易对合约
        address pairAddress = factory.createPair(address(token0), address(token1));
        pair = UniswapV2Pair(pairAddress);

        // 为测试合约铸造代币
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);

        // 为测试用户铸造代币
        token0.mint(testUser, 10 ether);
        token1.mint(testUser, 10 ether);
    }

    // ============ 初始流动性测试 ============

    /**
     * @notice 测试初始流动性提供（引导池子）
     * @dev 验证几何平均数计算和最小流动性锁定机制
     */
    function testMintBootstrap() public {
        // 向交易对转入初始流动性
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);

        // 调用 mint 函数铸造 LP 代币
        uint256 liquidity = pair.mint(address(this));

        // 验证返回的流动性数量
        assertEq(liquidity, 1 ether - 1000, "Initial liquidity calculation incorrect");

        // 验证 LP 代币余额（扣除最小流动性）
        assertEq(pair.balanceOf(address(this)), 1 ether - 1000, "LP token balance incorrect");

        // 验证储备金更新
        assertReserves(1 ether, 1 ether);

        // 验证总供应量（包含锁定的最小流动性）
        assertEq(pair.totalSupply(), 1 ether, "Total supply incorrect");

        // 验证最小流动性被锁定到死地址
        assertEq(pair.balanceOf(address(0x000000000000000000000000000000000000dEaD)), 1000, "MINIMUM_LIQUIDITY not locked correctly");
    }

    /**
     * @notice 测试不同比例的初始流动性
     * @dev 验证几何平均数对不同输入比例的处理
     */
    function testMintBootstrapDifferentRatios() public {
        // 测试 1:2 比例的初始流动性
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 2 ether);

        uint256 liquidity = pair.mint(address(this));

        // sqrt(1 * 2) = sqrt(2) ≈ 1.414... ether
        // 期望的流动性 = sqrt(2) * 1 ether - 1000
        uint256 expectedLiquidity = 1414213562373094048; // sqrt(2) * 1e18 - 1000 (实际计算结果)

        assertEq(liquidity, expectedLiquidity, "Different ratio initial liquidity incorrect");
        assertReserves(1 ether, 2 ether);
    }

    // ============ 平衡流动性测试 ============

    /**
     * @notice 测试向已有流动性的池子添加平衡流动性
     * @dev 验证后续流动性添加的比例计算
     */
    function testMintWhenTheresLiquidity() public {
        // 第一次添加流动性（引导池子）
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        // 验证初始状态
        assertEq(pair.balanceOf(address(this)), 1 ether - 1000, "Initial LP balance incorrect");
        assertReserves(1 ether, 1 ether);

        // 第二次添加流动性（平衡添加）
        token0.transfer(address(pair), 2 ether);
        token1.transfer(address(pair), 2 ether);
        uint256 liquidity = pair.mint(address(this));

        // 期望获得的流动性 = (2 ether * 1 ether) / 1 ether = 2 ether
        assertEq(liquidity, 2 ether, "Second mint liquidity incorrect");

        // 验证最终状态
        assertEq(pair.balanceOf(address(this)), 3 ether - 1000, "Final LP balance incorrect");
        assertEq(pair.totalSupply(), 3 ether, "Final total supply incorrect");
        assertReserves(3 ether, 3 ether);
    }

    /**
     * @notice 测试多次平衡流动性添加
     */
    function testMultipleMints() public {
        // 第一次：初始流动性
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        // 第二次：添加相等流动性
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        // 第三次：添加更多流动性
        token0.transfer(address(pair), 3 ether);
        token1.transfer(address(pair), 3 ether);
        pair.mint(address(this));

        // 验证最终状态：总共添加了 5 ether + 5 ether
        assertEq(pair.balanceOf(address(this)), 5 ether - 1000, "Multiple mints final balance incorrect");
        assertReserves(5 ether, 5 ether);
    }

    // ============ 不平衡流动性测试 ============

    /**
     * @notice 测试不平衡流动性提供的惩罚机制
     * @dev 验证取最小值策略对不平衡流动性的处理
     */
    function testMintUnbalanced() public {
        // 初始流动性（1:1 比例）
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        assertEq(pair.balanceOf(address(this)), 1 ether - 1000, "Initial balance incorrect");
        assertReserves(1 ether, 1 ether);

        // 不平衡流动性提供（token0 更多，2:1 vs 储备的 1:1）
        token0.transfer(address(pair), 2 ether);
        token1.transfer(address(pair), 1 ether);
        uint256 liquidity = pair.mint(address(this));

        // 计算期望流动性：
        // liquidity0 = (2 ether * 1 ether) / 1 ether = 2 ether
        // liquidity1 = (1 ether * 1 ether) / 1 ether = 1 ether
        // 实际获得 = min(2 ether, 1 ether) = 1 ether
        assertEq(liquidity, 1 ether, "Unbalanced mint liquidity incorrect");

        // 验证惩罚效果：虽然提供了更多 token0，仍只获得 1 LP 代币
        assertEq(pair.balanceOf(address(this)), 2 ether - 1000, "Unbalanced final balance incorrect");

        // 多余的 token0 被保留在池子中，改变了池子比例
        assertReserves(3 ether, 2 ether);
    }

    /**
     * @notice 测试极端不平衡的情况
     */
    function testMintExtremeUnbalanced() public {
        // 初始流动性
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        // 极端不平衡：只提供 token0
        token0.transfer(address(pair), 5 ether);
        // token1.transfer(address(pair), 0); // 不提供 token1

        // 由于没有提供 token1，流动性计算会给出0，这会触发 InsufficientLiquidityMinted 错误
        vm.expectRevert(UniswapV2Pair.InsufficientLiquidityMinted.selector);
        pair.mint(address(this));
    }

    // ============ 边界条件测试 ============

    /**
     * @notice 测试最小流动性阈值
     */
    function testMinimumLiquidityThreshold() public {
        // 尝试提供非常少的流动性
        token0.transfer(address(pair), 2000);  // 2000 wei
        token1.transfer(address(pair), 2000);  // 2000 wei

        uint256 liquidity = pair.mint(address(this));

        // sqrt(2000 * 2000) = 2000, 减去最小流动性 1000
        assertEq(liquidity, 1000, "Minimum liquidity threshold incorrect");

        assertReserves(2000, 2000);
    }

    /**
     * @notice 测试零流动性情况（应该失败）
     */
    function testZeroLiquidityMint() public {
        // 首先建立初始流动性
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        // 尝试不提供任何新代币就铸造（应该失败）
        vm.expectRevert(UniswapV2Pair.InsufficientLiquidityMinted.selector);
        pair.mint(address(this));
    }

    // ============ 多用户测试 ============

    /**
     * @notice 测试多用户流动性提供
     */
    function testMultiUserMint() public {
        // 用户1（测试合约）提供初始流动性
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        // 用户2 提供流动性
        vm.startPrank(testUser);
        token0.transfer(address(pair), 2 ether);
        token1.transfer(address(pair), 2 ether);
        uint256 user2Liquidity = pair.mint(testUser);
        vm.stopPrank();

        // 验证用户2获得的流动性
        assertEq(user2Liquidity, 2 ether, "User2 liquidity incorrect");
        assertEq(pair.balanceOf(testUser), 2 ether, "User2 balance incorrect");

        // 验证总供应量和储备金
        assertEq(pair.totalSupply(), 3 ether, "Total supply with multiple users incorrect");
        assertReserves(3 ether, 3 ether);
    }

    // ============ 辅助函数 ============

    /**
     * @notice 验证储备金数量的辅助函数
     * @param expectedReserve0 期望的 token0 储备金
     * @param expectedReserve1 期望的 token1 储备金
     */
    function assertReserves(uint256 expectedReserve0, uint256 expectedReserve1) internal view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertEq(uint256(reserve0), expectedReserve0, "Reserve0 mismatch");
        assertEq(uint256(reserve1), expectedReserve1, "Reserve1 mismatch");
    }

    /**
     * @notice 验证代币余额的辅助函数
     * @param token 代币合约地址
     * @param account 账户地址
     * @param expectedBalance 期望余额
     */
    function assertTokenBalance(address token, address account, uint256 expectedBalance) internal view {
        assertEq(ERC20Mock(token).balanceOf(account), expectedBalance, "Token balance mismatch");
    }

    // ============ Gas 优化测试 ============

    /**
     * @notice 测试 Gas 消耗情况
     */
    function testGasConsumption() public {
        // 预热：第一次调用通常消耗更多 Gas，使用足够大的数值
        token0.transfer(address(pair), 10000);
        token1.transfer(address(pair), 10000);
        pair.mint(address(this));

        // 保存初始状态
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));

        // 测量后续流动性提供的 Gas 消耗
        uint256 gasStart = gasleft();

        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(address(this));

        uint256 gasUsed = gasStart - gasleft();

        // 记录 Gas 使用量（具体数值可能因优化而变化）
        console.log("Gas used for balanced mint:", gasUsed);

        // 验证代币余额变化符合预期
        assertEq(token0.balanceOf(address(this)), initialBalance0 - 1 ether, "Token0 balance change incorrect");
        assertEq(token1.balanceOf(address(this)), initialBalance1 - 1 ether, "Token1 balance change incorrect");

        // Gas 使用量应该在合理范围内（实际测试中这个范围可能需要调整）
        assertTrue(gasUsed > 10000, "Gas usage too low");
        assertTrue(gasUsed < 100000, "Gas usage too high");
    }
}