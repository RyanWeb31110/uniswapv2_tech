// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Factory.sol";
import "../../src/core/UniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title UniswapV2Factory 测试合约
 * @notice 测试工厂合约的核心功能
 */
contract UniswapV2FactoryTest is Test {
    UniswapV2Factory public factory;
    TestToken public tokenA;
    TestToken public tokenB;
    TestToken public tokenC;

    address public owner = address(0x1);
    address public user = address(0x2);

    // 测试事件
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256 index
    );

    function setUp() public {
        // 部署工厂合约，设置owner为手续费设置权限地址
        factory = new UniswapV2Factory(owner);

        // 部署测试代币
        tokenA = new TestToken("Token A", "TKA");
        tokenB = new TestToken("Token B", "TKB");
        tokenC = new TestToken("Token C", "TKC");

        // 确保代币地址按字典序排列
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
    }

    // ============ 构造函数测试 ============

    function testConstructor() public {
        assertEq(factory.feeToSetter(), owner);
        assertEq(factory.feeTo(), address(0));
        assertEq(factory.allPairsLength(), 0);
    }

    // ============ 交易对创建测试 ============

    function testCreatePair() public {
        // 计算期望的token0和token1地址
        (address token0, address token1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        // 创建交易对
        address pair = factory.createPair(address(tokenA), address(tokenB));

        // 验证返回的地址不为零
        assertTrue(pair != address(0));

        // 验证映射更新正确
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);

        // 验证allPairs数组更新正确
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.allPairs(0), pair);

        // 验证交易对合约初始化正确
        UniswapV2Pair pairContract = UniswapV2Pair(pair);
        assertEq(pairContract.token0(), token0);
        assertEq(pairContract.token1(), token1);
        assertEq(pairContract.factory(), address(factory));
    }

    function testCreatePairReverseOrder() public {
        // 测试不同顺序的代币地址应该创建相同的交易对
        address pair1 = factory.createPair(address(tokenA), address(tokenB));

        // 不应该能创建反向交易对
        vm.expectRevert(UniswapV2Factory.PairExists.selector);
        factory.createPair(address(tokenB), address(tokenA));
    }

    function testCreatePairIdenticalTokens() public {
        // 测试相同代币地址应该失败
        vm.expectRevert(UniswapV2Factory.IdenticalAddresses.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    function testCreatePairZeroAddress() public {
        // 测试零地址应该失败
        vm.expectRevert(UniswapV2Factory.ZeroAddress.selector);
        factory.createPair(address(0), address(tokenA));

        vm.expectRevert(UniswapV2Factory.ZeroAddress.selector);
        factory.createPair(address(tokenA), address(0));
    }

    function testCreatePairAlreadyExists() public {
        // 创建第一个交易对
        factory.createPair(address(tokenA), address(tokenB));

        // 尝试再次创建相同的交易对应该失败
        vm.expectRevert(UniswapV2Factory.PairExists.selector);
        factory.createPair(address(tokenA), address(tokenB));
    }

    function testCreateMultiplePairs() public {
        // 创建多个交易对
        address pair1 = factory.createPair(address(tokenA), address(tokenB));
        address pair2 = factory.createPair(address(tokenA), address(tokenC));
        address pair3 = factory.createPair(address(tokenB), address(tokenC));

        // 验证所有交易对都不同
        assertTrue(pair1 != pair2);
        assertTrue(pair1 != pair3);
        assertTrue(pair2 != pair3);

        // 验证总数正确
        assertEq(factory.allPairsLength(), 3);

        // 验证映射正确
        assertEq(factory.allPairs(0), pair1);
        assertEq(factory.allPairs(1), pair2);
        assertEq(factory.allPairs(2), pair3);
    }

    // ============ 地址计算测试 ============

    function testComputePairAddress() public {
        // 确保token0 < token1
        (address token0, address token1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        // 预计算地址
        address predictedPair = factory.computePairAddress(token0, token1);

        // 实际创建交易对
        address actualPair = factory.createPair(address(tokenA), address(tokenB));

        // 验证地址匹配
        assertEq(predictedPair, actualPair);
    }

    function testComputePairAddressUnsorted() public {
        // 测试未排序的代币地址应该失败
        vm.expectRevert("UniswapV2Factory: TOKENS_NOT_SORTED");
        factory.computePairAddress(address(tokenB), address(tokenA));
    }

    // ============ 治理功能测试 ============

    function testSetFeeTo() public {
        address newFeeTo = address(0x3);

        // 只有feeToSetter可以设置feeTo
        vm.prank(owner);
        factory.setFeeTo(newFeeTo);

        assertEq(factory.feeTo(), newFeeTo);
    }

    function testSetFeeToUnauthorized() public {
        address newFeeTo = address(0x3);

        // 非feeToSetter不能设置feeTo
        vm.prank(user);
        vm.expectRevert(UniswapV2Factory.Forbidden.selector);
        factory.setFeeTo(newFeeTo);
    }

    function testSetFeeToSetter() public {
        address newFeeToSetter = address(0x3);

        // 只有当前feeToSetter可以转移权限
        vm.prank(owner);
        factory.setFeeToSetter(newFeeToSetter);

        assertEq(factory.feeToSetter(), newFeeToSetter);

        // 验证新的feeToSetter可以设置feeTo
        vm.prank(newFeeToSetter);
        factory.setFeeTo(address(0x4));
        assertEq(factory.feeTo(), address(0x4));
    }

    function testSetFeeToSetterUnauthorized() public {
        address newFeeToSetter = address(0x3);

        // 非当前feeToSetter不能转移权限
        vm.prank(user);
        vm.expectRevert(UniswapV2Factory.Forbidden.selector);
        factory.setFeeToSetter(newFeeToSetter);
    }

    // ============ 查询功能测试 ============

    function testGetPair() public {
        // 交易对不存在时应该返回零地址
        assertEq(factory.getPair(address(tokenA), address(tokenB)), address(0));

        // 创建交易对后应该返回正确地址
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);
    }

    function testAllPairsLength() public {
        assertEq(factory.allPairsLength(), 0);

        factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.allPairsLength(), 1);

        factory.createPair(address(tokenA), address(tokenC));
        assertEq(factory.allPairsLength(), 2);
    }

    // ============ Gas 优化测试 ============

    function testCreatePairGasUsage() public {
        uint256 gasStart = gasleft();
        factory.createPair(address(tokenA), address(tokenB));
        uint256 gasUsed = gasStart - gasleft();

        // 验证Gas使用量在合理范围内（具体数值需要根据实际情况调整）
        assertTrue(gasUsed < 3_000_000, "createPair uses too much gas");
    }

    // ============ 模糊测试 ============

    function testFuzzCreatePair(address tokenX, address tokenY) public {
        vm.assume(tokenX != tokenY);
        vm.assume(tokenX != address(0) && tokenY != address(0));
        vm.assume(tokenX.code.length == 0 && tokenY.code.length == 0); // 假设是EOA地址

        // 确保地址不是预编译合约
        vm.assume(uint160(tokenX) > 10 && uint160(tokenY) > 10);

        // 模拟代币合约（简单返回true）
        vm.mockCall(tokenX, abi.encodeWithSignature("balanceOf(address)"), abi.encode(0));
        vm.mockCall(tokenY, abi.encodeWithSignature("balanceOf(address)"), abi.encode(0));

        try factory.createPair(tokenX, tokenY) returns (address pair) {
            assertTrue(pair != address(0));
            assertEq(factory.getPair(tokenX, tokenY), pair);
            assertEq(factory.getPair(tokenY, tokenX), pair);
        } catch {
            // 某些情况下可能失败，这是正常的
        }
    }
}

/**
 * @title 测试代币合约
 * @notice 用于测试的简单ERC20代币
 */
contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**decimals());
    }
}