// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/oracle/UniswapV2Oracle.sol";
import "../../src/oracle/AdvancedOracle.sol";
import "../../src/libraries/UQ112x112.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title 价格预言机测试套件
 * @notice 测试 TWAP 预言机的各种功能
 * @dev 包含基础功能、价格操纵攻击测试、边界条件测试等
 */
contract UniswapV2OracleTest is Test {
    using UQ112x112 for uint224;

    // ============ 测试合约实例 ============

    UniswapV2Pair pair;
    UniswapV2Oracle oracle;
    AdvancedOracle advancedOracle;
    ERC20Mock tokenA;
    ERC20Mock tokenB;

    address user = makeAddr("user");
    address trader = makeAddr("trader");
    address attacker = makeAddr("attacker");

    // ============ 测试常量 ============

    uint256 constant INITIAL_SUPPLY = 10000 ether;
    uint256 constant INITIAL_LIQUIDITY = 1000 ether;
    uint32 constant ORACLE_PERIOD = 1800; // 30 分钟

    // ============ 测试环境设置 ============

    function setUp() public {
        // 部署代币合约
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();

        // 部署交易对合约
        pair = new UniswapV2Pair(address(tokenA), address(tokenB));

        // 部署预言机合约
        oracle = new UniswapV2Oracle();
        advancedOracle = new AdvancedOracle();

        // 准备初始流动性
        tokenA.mint(address(this), INITIAL_SUPPLY);
        tokenB.mint(address(this), INITIAL_SUPPLY);

        // 添加初始流动性（1:1 比例）
        tokenA.transfer(address(pair), INITIAL_LIQUIDITY);
        tokenB.transfer(address(pair), INITIAL_LIQUIDITY);
        pair.mint(address(this));
    }

    // ============ 基础功能测试 ============

    /**
     * @notice 测试累积价格更新机制
     */
    function testCumulativePriceUpdate() public {
        // 获取初始累积价格
        uint256 initialPrice0 = pair.price0CumulativeLast();
        uint256 initialPrice1 = pair.price1CumulativeLast();

        // 验证初始价格为0
        assertEq(initialPrice0, 0, "Initial price0 should be 0");
        assertEq(initialPrice1, 0, "Initial price1 should be 0");

        // 等待一段时间
        vm.warp(block.timestamp + 3600); // 前进 1 小时

        // 执行交易触发价格更新
        tokenA.mint(user, 100 ether);
        vm.startPrank(user);
        tokenA.transfer(address(pair), 100 ether);

        uint256 expectedOut = getAmountOut(100 ether, INITIAL_LIQUIDITY, INITIAL_LIQUIDITY);
        pair.swap(0, expectedOut, user, "");
        vm.stopPrank();

        // 验证累积价格已更新
        uint256 newPrice0 = pair.price0CumulativeLast();
        uint256 newPrice1 = pair.price1CumulativeLast();

        assertGt(newPrice0, initialPrice0, "Price0 cumulative should increase");
        assertGt(newPrice1, initialPrice1, "Price1 cumulative should increase");
    }

    /**
     * @notice 测试预言机初始化和更新
     */
    function testOracleInitialization() public {
        // 检查预言机未初始化状态
        assertFalse(oracle.isInitialized(address(pair)), "Oracle should not be initialized");

        // 初始化预言机
        oracle.update(address(pair));

        // 检查预言机已初始化
        assertTrue(oracle.isInitialized(address(pair)), "Oracle should be initialized");

        // 检查时间戳
        uint32 timestamp = oracle.getObservationTimestamp(address(pair));
        assertEq(timestamp, uint32(block.timestamp % 2**32), "Timestamp should match");
    }

    /**
     * @notice 测试 TWAP 计算准确性
     */
    function testTWAPAccuracy() public {
        // 第一次观察
        oracle.update(address(pair));

        // 等待时间间隔并执行一些交易改变价格
        vm.warp(block.timestamp + ORACLE_PERIOD);
        performSwap(100 ether, true); // A -> B

        // 第二次观察
        oracle.update(address(pair));

        vm.warp(block.timestamp + ORACLE_PERIOD);
        performSwap(50 ether, false); // B -> A

        vm.warp(block.timestamp + ORACLE_PERIOD);

        // 更新预言机并获取 TWAP
        oracle.update(address(pair));
        (uint256 price0, uint256 price1) = oracle.consult(address(pair));

        // 验证价格合理性
        assertGt(price0, 0, "Price0 should be positive");
        assertGt(price1, 0, "Price1 should be positive");

        // 验证价格互为倒数关系（考虑精度损失）
        uint256 product = price0 * price1 / (2**112);
        uint256 expected = 2**112;
        uint256 tolerance = expected / 100; // 1% 容差
        // 允许一定的精度误差
        assertTrue(
            product >= expected - tolerance && product <= expected + tolerance,
            "Prices should be approximately reciprocal"
        );
    }

    /**
     * @notice 测试预言机时间窗口限制
     */
    function testOraclePeriodEnforcement() public {
        // 初始化预言机
        oracle.update(address(pair));

        // 尝试立即再次更新（应该失败）
        vm.expectRevert(UniswapV2Oracle.PeriodNotElapsed.selector);
        oracle.update(address(pair));

        // 等待不足的时间（应该失败）
        vm.warp(block.timestamp + ORACLE_PERIOD - 1);
        vm.expectRevert(UniswapV2Oracle.PeriodNotElapsed.selector);
        oracle.update(address(pair));

        // 等待足够的时间（应该成功）
        vm.warp(block.timestamp + 1);
        oracle.update(address(pair));
    }

    // ============ 价格操纵攻击测试 ============

    /**
     * @notice 测试价格操纵攻击防护
     */
    function testPriceManipulationResistance() public {
        // 初始化预言机观察
        oracle.update(address(pair));

        // 等待足够的时间
        vm.warp(block.timestamp + ORACLE_PERIOD);

        // 获取操纵前的 TWAP
        oracle.update(address(pair));
        (uint256 price0Before,) = oracle.consult(address(pair));

        // 记录操纵前的即时价格
        (uint112 reserve0Before, uint112 reserve1Before,) = pair.getReserves();
        uint256 instantPriceBefore = uint256(reserve1Before) * (2**112) / reserve0Before;

        // 执行大额交易尝试操纵价格
        uint256 attackAmount = 5000 ether; // 大额攻击

        vm.startPrank(attacker);
        tokenA.mint(attacker, attackAmount);
        tokenA.transfer(address(pair), attackAmount);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 expectedOut = getAmountOut(attackAmount, reserve0, reserve1);
        pair.swap(0, expectedOut, attacker, "");
        vm.stopPrank();

        // 记录操纵后的即时价格
        (uint112 reserve0After, uint112 reserve1After,) = pair.getReserves();
        uint256 instantPriceAfter = uint256(reserve1After) * (2**112) / reserve0After;

        // 等待预言机更新周期
        vm.warp(block.timestamp + ORACLE_PERIOD);

        // 获取操纵后的 TWAP
        oracle.update(address(pair));
        (uint256 price0After,) = oracle.consult(address(pair));

        // 计算即时价格变化
        uint256 instantPriceChange = instantPriceBefore > instantPriceAfter ?
            instantPriceBefore - instantPriceAfter : instantPriceAfter - instantPriceBefore;
        uint256 instantChangeRatio = instantPriceChange * 100 / instantPriceBefore;

        // 计算 TWAP 价格变化
        uint256 twapPriceChange = price0Before > price0After ?
            price0Before - price0After : price0After - price0Before;
        uint256 twapChangeRatio = twapPriceChange * 100 / price0Before;

        // TWAP 价格变化应该远小于即时价格变化
        assertLt(twapChangeRatio, instantChangeRatio / 2, "TWAP should resist price manipulation");
        assertLt(twapChangeRatio, 20, "TWAP should resist price manipulation");
    }

    // ============ UQ112x112 精度测试 ============

    /**
     * @notice 测试 UQ112x112 精度
     */
    function testUQ112x112Precision() public {
        // 测试不同精度的价格计算
        uint112 reserve0 = 3;
        uint112 reserve1 = 2;

        // 使用 UQ112x112 格式计算价格
        uint224 encoded = UQ112x112.encode(reserve1);
        uint224 price = encoded.uqdiv(reserve0);

        // 验证精度
        // 期望价格 = 2/3 * 2^112
        uint256 expected = (uint256(reserve1) * (2**112)) / reserve0;
        assertEq(uint256(price), expected, "UQ112x112 precision test failed");

        // 测试解码
        uint112 decoded = UQ112x112.decode(uint224(reserve1) * (2**112));
        assertEq(decoded, reserve1, "Decode test failed");
    }

    // ============ 增强型预言机测试 ============

    /**
     * @notice 测试多时间窗口功能
     */
    function testMultiWindowOracle() public {
        uint32[] memory periods = advancedOracle.getSupportedPeriods();
        assertTrue(periods.length > 0, "Should have supported periods");

        // 测试支持的时间窗口
        assertTrue(advancedOracle.isSupportedPeriod(600), "Should support 10m window");
        assertTrue(advancedOracle.isSupportedPeriod(1800), "Should support 30m window");
        assertFalse(advancedOracle.isSupportedPeriod(123), "Should not support arbitrary period");

        // 初始化窗口
        advancedOracle.updateWindow(address(pair), 600);

        // 等待时间并测试查询
        vm.warp(block.timestamp + 600);
        advancedOracle.updateWindow(address(pair), 600);

        (uint256 price0, uint256 price1) = advancedOracle.consultWithPeriod(address(pair), 600);
        assertGt(price0, 0, "Window price0 should be positive");
        assertGt(price1, 0, "Window price1 should be positive");
    }

    /**
     * @notice 测试批量操作功能
     */
    function testBatchOperations() public {
        // 创建多个交易对用于测试
        UniswapV2Pair pair2 = new UniswapV2Pair(address(tokenA), address(tokenB));
        tokenA.transfer(address(pair2), INITIAL_LIQUIDITY);
        tokenB.transfer(address(pair2), INITIAL_LIQUIDITY);
        pair2.mint(address(this));

        address[] memory pairs = new address[](2);
        pairs[0] = address(pair);
        pairs[1] = address(pair2);

        // 测试批量更新
        advancedOracle.batchUpdate(pairs);

        // 等待时间
        vm.warp(block.timestamp + ORACLE_PERIOD);

        // 测试批量查询
        (uint256[] memory prices0, uint256[] memory prices1) = advancedOracle.batchConsult(pairs);

        assertEq(prices0.length, 2, "Should return prices for all pairs");
        assertEq(prices1.length, 2, "Should return prices for all pairs");
    }

    /**
     * @notice 测试流动性检查功能
     */
    function testLiquiditySafety() public {
        uint256 minLiquidity = 100 ether;

        // 初始化预言机
        advancedOracle.update(address(pair));
        vm.warp(block.timestamp + ORACLE_PERIOD);
        advancedOracle.update(address(pair));

        // 测试安全价格获取
        (uint256 price0, uint256 price1, bool isValid) = advancedOracle.getSafePrice(
            address(pair),
            minLiquidity
        );

        // 当前流动性应该足够
        assertTrue(isValid, "Price should be valid with sufficient liquidity");
        assertGt(price0, 0, "Price0 should be positive");
        assertGt(price1, 0, "Price1 should be positive");

        // 测试流动性不足情况
        uint256 highMinLiquidity = 10000000 ether;
        (, , bool isValidHigh) = advancedOracle.getSafePrice(address(pair), highMinLiquidity);
        assertFalse(isValidHigh, "Price should be invalid with insufficient liquidity");
    }

    // ============ 边界条件测试 ============

    /**
     * @notice 测试溢出处理
     */
    function testOverflowHandling() public {
        // 模拟长时间运行导致的溢出情况
        vm.warp(2**32 - 100); // 接近 uint32 最大值

        oracle.update(address(pair));

        // 跨越 uint32 溢出边界
        vm.warp(100); // 溢出后的时间戳

        // 执行交易
        performSwap(100 ether, true);

        // 验证预言机仍然正常工作
        vm.warp(100 + ORACLE_PERIOD);
        oracle.update(address(pair));
        (uint256 price0, uint256 price1) = oracle.consult(address(pair));

        assertGt(price0, 0, "Oracle should work after timestamp overflow");
        assertGt(price1, 0, "Oracle should work after timestamp overflow");
    }

    /**
     * @notice 测试极端价格比例
     */
    function testExtremePriceRatios() public {
        // 创建极端价格比例的流动性池
        UniswapV2Pair extremePair = new UniswapV2Pair(address(tokenA), address(tokenB));

        // 添加极端比例的流动性 (1000:1)
        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1 ether);
        tokenA.transfer(address(extremePair), 1000 ether);
        tokenB.transfer(address(extremePair), 1 ether);
        extremePair.mint(address(this));

        // 测试预言机在极端比例下的工作情况
        oracle.update(address(extremePair));

        vm.warp(block.timestamp + ORACLE_PERIOD);

        oracle.update(address(extremePair));
        (uint256 price0, uint256 price1) = oracle.consult(address(extremePair));

        // 验证极端价格计算的正确性
        assertGt(price0, 0, "Extreme price0 should be positive");
        assertGt(price1, 0, "Extreme price1 should be positive");

        // 验证价格关系的合理性
        assertTrue(price0 > price1 * 1000, "price0 should be much larger than price1");
    }

    /**
     * @notice 测试零地址保护
     */
    function testZeroAddressProtection() public {
        vm.expectRevert(UniswapV2Oracle.ZeroAddress.selector);
        oracle.update(address(0));

        vm.expectRevert(UniswapV2Oracle.ZeroAddress.selector);
        oracle.consult(address(0));
    }

    // ============ 辅助函数 ============

    /**
     * @notice 执行代币交换
     * @param amount 交换数量
     * @param aToB 交换方向：true = A->B, false = B->A
     */
    function performSwap(uint256 amount, bool aToB) internal {
        address swapper = makeAddr("swapper");

        vm.startPrank(swapper);

        if (aToB) {
            tokenA.mint(swapper, amount);
            tokenA.transfer(address(pair), amount);

            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            uint256 expectedOut = getAmountOut(amount, reserve0, reserve1);

            pair.swap(0, expectedOut, swapper, "");
        } else {
            tokenB.mint(swapper, amount);
            tokenB.transfer(address(pair), amount);

            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            uint256 expectedOut = getAmountOut(amount, reserve1, reserve0);

            pair.swap(expectedOut, 0, swapper, "");
        }

        vm.stopPrank();
    }

    /**
     * @notice 计算输出数量（使用 Uniswap 公式）
     * @param amountIn 输入数量
     * @param reserveIn 输入代币储备
     * @param reserveOut 输出代币储备
     * @return amountOut 输出数量
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
}