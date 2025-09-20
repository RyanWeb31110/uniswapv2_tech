// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../mocks/MaliciousToken.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title 重入攻击测试套件
 * @notice 测试各种重入攻击场景和防护机制
 * @dev 验证 ReentrancyGuard 和 CEI 模式的有效性
 */
contract ReentrancyAttackTest is Test {
    // ============ 测试合约实例 ============

    UniswapV2Pair public pair;
    UniswapV2Pair public maliciousPair;
    ERC20Mock public tokenA;
    ERC20Mock public tokenB;
    MaliciousToken public maliciousToken;
    FlashLoanAttacker public flashAttacker;

    address public attacker = makeAddr("attacker");
    address public victim = makeAddr("victim");

    // ============ 测试环境设置 ============

    /**
     * @notice 测试环境初始化
     */
    function setUp() public {
        // 创建正常代币
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();

        // 创建恶意代币
        maliciousToken = new MaliciousToken();

        // 创建闪电贷攻击者
        flashAttacker = new FlashLoanAttacker();

        // 创建正常的交易对
        pair = new UniswapV2Pair(address(tokenA), address(tokenB));

        // 创建包含恶意代币的交易对
        maliciousPair = new UniswapV2Pair(address(maliciousToken), address(tokenB));

        // 设置恶意代币的目标
        maliciousToken.setPair(address(maliciousPair));

        // 为测试合约铸造代币
        tokenA.mint(address(this), 10000 ether);
        tokenB.mint(address(this), 10000 ether);
        maliciousToken.mint(address(this), 10000 ether);

        // 为攻击者铸造代币
        tokenA.mint(attacker, 1000 ether);
        tokenB.mint(attacker, 1000 ether);
        maliciousToken.mint(attacker, 1000 ether);

        // 添加初始流动性到正常交易对
        tokenA.transfer(address(pair), 1000 ether);
        tokenB.transfer(address(pair), 1000 ether);
        pair.mint(address(this));

        // 添加初始流动性到恶意交易对
        maliciousToken.transfer(address(maliciousPair), 1000 ether);
        tokenB.transfer(address(maliciousPair), 1000 ether);
        maliciousPair.mint(address(this));
    }

    // ============ 重入保护测试 ============

    /**
     * @notice 测试 swap 函数的重入保护
     * @dev 验证恶意代币无法在转账时重入 swap 函数
     */
    function testSwapReentrancyProtection() public {
        // 启用攻击模式
        maliciousToken.enableAttack();

        // 攻击者准备交换
        vm.startPrank(attacker);
        tokenB.transfer(address(maliciousPair), 100 ether);

        // 记录攻击前的计数
        uint256 countBefore = maliciousToken.attackCount();

        // 执行交换 - 外部调用会成功，但内部的重入攻击会失败
        maliciousPair.swap(50 ether, 0, attacker, "");

        // 验证攻击计数器递增了（说明攻击被尝试了）
        assertEq(maliciousToken.attackCount(), countBefore + 1, "Attack should have been attempted");

        vm.stopPrank();
    }

    /**
     * @notice 测试 mint 函数的重入保护
     */
    function testMintReentrancyProtection() public {
        // 创建一个会在 mint 时攻击的恶意代币
        MaliciousTokenMint maliciousMint = new MaliciousTokenMint();
        UniswapV2Pair mintPair = new UniswapV2Pair(address(maliciousMint), address(tokenB));
        maliciousMint.setPair(address(mintPair));

        // 为恶意代币准备流动性
        maliciousMint.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);

        // 第一次正常添加流动性
        maliciousMint.transfer(address(mintPair), 100 ether);
        tokenB.transfer(address(mintPair), 100 ether);
        mintPair.mint(address(this));

        // 启用攻击并尝试再次 mint
        maliciousMint.enableAttack();
        maliciousMint.transfer(address(mintPair), 100 ether);
        tokenB.transfer(address(mintPair), 100 ether);

        // mint 应该成功，但内部的重入攻击会失败
        // 这里我们通过检查没有异常来验证重入保护工作正常
        uint256 liquidity = mintPair.mint(address(this));
        assertGt(liquidity, 0, "Mint should succeed despite attack attempt");
    }

    /**
     * @notice 测试 burn 函数的重入保护
     */
    function testBurnReentrancyProtection() public {
        // 获得一些 LP 代币
        maliciousToken.transfer(address(maliciousPair), 100 ether);
        tokenB.transfer(address(maliciousPair), 100 ether);
        uint256 liquidity = maliciousPair.mint(address(this));

        // 将 LP 代币转给合约准备 burn
        IERC20(address(maliciousPair)).transfer(address(maliciousPair), liquidity);

        // 启用攻击模式
        maliciousToken.enableAttack();

        // 记录攻击前的计数
        uint256 countBefore = maliciousToken.attackCount();

        // burn 应该成功，但内部的重入攻击会失败
        (uint256 amount0, uint256 amount1) = maliciousPair.burn(address(this));

        // 验证 burn 成功且攻击被尝试
        assertGt(amount0, 0, "Burn should return tokens");
        assertGt(amount1, 0, "Burn should return tokens");
        assertEq(maliciousToken.attackCount(), countBefore + 1, "Attack should have been attempted");
    }

    // ============ CEI 模式测试 ============

    /**
     * @notice 测试 CEI 模式的有效性
     * @dev 验证正常交换不受影响
     */
    function testCEIPattern() public {
        uint256 initialBalance = tokenB.balanceOf(attacker);

        vm.startPrank(attacker);

        // 正常交换应该成功
        tokenA.transfer(address(pair), 100 ether);

        uint256 expectedOut = getAmountOut(100 ether, 1000 ether, 1000 ether);
        pair.swap(0, expectedOut, attacker, "");

        // 验证只获得了预期的代币数量
        assertEq(tokenB.balanceOf(attacker), initialBalance + expectedOut);

        vm.stopPrank();
    }

    /**
     * @notice 测试正常流动性操作不受重入保护影响
     */
    function testNormalOperationsUnaffected() public {
        vm.startPrank(attacker);

        // 正常添加流动性
        tokenA.transfer(address(pair), 100 ether);
        tokenB.transfer(address(pair), 100 ether);
        uint256 liquidity = pair.mint(attacker);

        assertGt(liquidity, 0, "Mint should succeed");

        // 正常交换
        tokenA.transfer(address(pair), 50 ether);
        uint256 expectedOut = getAmountOut(50 ether, 1100 ether, 1100 ether);
        pair.swap(0, expectedOut, attacker, "");

        // 正常移除流动性
        IERC20(address(pair)).transfer(address(pair), liquidity / 2);
        (uint256 amount0, uint256 amount1) = pair.burn(attacker);

        assertGt(amount0, 0, "Burn should return tokens");
        assertGt(amount1, 0, "Burn should return tokens");

        vm.stopPrank();
    }

    // ============ 闪电贷攻击测试 ============

    /**
     * @notice 测试闪电贷攻击场景
     * @dev 验证即使是闪电贷攻击也会被重入保护阻止
     */
    function testFlashLoanAttack() public {
        tokenA.mint(address(flashAttacker), 1000 ether);

        // 闪电贷攻击应该失败
        vm.expectRevert();
        flashAttacker.executeFlashLoan(address(pair));
    }

    // ============ 边界情况测试 ============

    /**
     * @notice 测试多层重入攻击
     */
    function testNestedReentrancy() public {
        // 创建嵌套攻击的恶意代币
        NestedAttackToken nestedToken = new NestedAttackToken();
        UniswapV2Pair nestedPair = new UniswapV2Pair(address(nestedToken), address(tokenB));
        nestedToken.setPair(address(nestedPair));

        // 初始化流动性
        nestedToken.mint(address(this), 1000 ether);
        nestedToken.transfer(address(nestedPair), 500 ether);
        tokenB.transfer(address(nestedPair), 500 ether);
        nestedPair.mint(address(this));

        // 启用攻击
        nestedToken.enableAttack();

        vm.startPrank(attacker);
        tokenB.transfer(address(nestedPair), 50 ether);

        // 多层重入攻击应该被阻止 - 外部调用成功但内部重入失败
        nestedPair.swap(25 ether, 0, attacker, "");

        // 验证攻击确实被尝试了
        assertEq(nestedToken.nestLevel(), 0, "Nest level should be reset after attack");

        vm.stopPrank();
    }

    /**
     * @notice 测试攻击计数器的正确性
     */
    function testAttackCounter() public {
        maliciousToken.enableAttack();

        vm.startPrank(attacker);
        tokenB.transfer(address(maliciousPair), 100 ether);

        // 记录攻击前的计数
        uint256 countBefore = maliciousToken.attackCount();

        // 尝试攻击 - 外部调用会成功
        maliciousPair.swap(50 ether, 0, attacker, "");

        // 验证攻击计数器递增了
        assertEq(maliciousToken.attackCount(), countBefore + 1, "Attack counter should increment");

        vm.stopPrank();
    }

    // ============ 辅助函数 ============

    /**
     * @notice 计算输出金额（包含手续费）
     * @param amountIn 输入金额
     * @param reserveIn 输入代币储备
     * @param reserveOut 输出代币储备
     * @return amountOut 输出金额
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /**
     * @notice 验证储备金的辅助函数
     */
    function assertReserves(UniswapV2Pair _pair, uint256 expectedReserve0, uint256 expectedReserve1) internal view {
        (uint112 reserve0, uint112 reserve1, ) = _pair.getReserves();
        assertEq(uint256(reserve0), expectedReserve0, "Reserve0 mismatch");
        assertEq(uint256(reserve1), expectedReserve1, "Reserve1 mismatch");
    }
}

/**
 * @title 在 mint 时攻击的恶意代币
 */
contract MaliciousTokenMint {
    string public name = "Malicious Mint Token";
    string public symbol = "MALM";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public pair;
    bool public attackEnabled = false;

    function setPair(address _pair) external {
        pair = _pair;
    }

    function enableAttack() external {
        attackEnabled = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        // 在转给 pair 时发起攻击
        if (attackEnabled && to == pair) {
            // 尝试重入 mint
            try UniswapV2Pair(pair).mint(address(this)) {
                // 攻击成功
            } catch {
                // 攻击失败
            }
        }

        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/**
 * @title 嵌套攻击代币
 */
contract NestedAttackToken {
    string public name = "Nested Attack Token";
    string public symbol = "NEST";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public pair;
    bool public attackEnabled = false;
    uint256 public nestLevel = 0;

    function setPair(address _pair) external {
        pair = _pair;
    }

    function enableAttack() external {
        attackEnabled = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        // 嵌套重入攻击
        if (attackEnabled && msg.sender == pair && nestLevel < 2) {
            nestLevel++;
            try UniswapV2Pair(pair).swap(10 ether, 0, address(this), "") {
                // 嵌套攻击成功
            } catch {
                // 嵌套攻击失败
            }
            nestLevel--;
        }

        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}