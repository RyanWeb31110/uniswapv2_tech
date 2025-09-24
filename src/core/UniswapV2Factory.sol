// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2Pair.sol";
import "../libraries/UniswapV2Library.sol";

/**
 * @title UniswapV2Factory 工厂合约
 * @notice 创建和管理所有UniswapV2交易对的核心合约
 * @dev 作为所有已部署交易对合约的注册中心，确保交易对的唯一性
 *
 * 架构设计要点：
 * - 统一的交易对管理体系：防止重复交易对，统一部署流程
 * - 高效的地址计算和查询：使用CREATE2确定性部署和双重映射
 * - 完善的治理功能：支持手续费管理和权限控制
 * - 良好的可扩展性：标准化接口，丰富的事件支持
 */
contract UniswapV2Factory is IUniswapV2Factory {
    // ============ 自定义错误 ============
    // 使用自定义错误替代require字符串，显著节省Gas成本

    /// @notice 代币地址相同错误
    error IdenticalAddresses();

    /// @notice 交易对已存在错误
    error PairExists();

    /// @notice 零地址错误
    error ZeroAddress();

    /// @notice 权限不足错误
    error Forbidden();

    // ============ 状态变量 ============

    /// @notice 手续费接收地址，零地址表示未开启手续费
    address public override feeTo;

    /// @notice 手续费设置权限地址，只有此地址可以修改feeTo
    address public override feeToSetter;

    /// @notice 双重映射存储交易对地址，支持任意顺序查询
    /// @dev pairs[token0][token1] 和 pairs[token1][token0] 指向同一个交易对
    mapping(address => mapping(address => address)) public pairs;

    /// @notice 所有交易对的线性存储，便于遍历和分页查询
    address[] public override allPairs;

    // ============ 构造函数 ============

    /**
     * @notice 部署工厂合约
     * @param _feeToSetter 初始的手续费设置权限地址
     */
    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    // ============ 查询函数 ============

    /**
     * @inheritdoc IUniswapV2Factory
     */
    function getPair(address tokenA, address tokenB) external view override returns (address) {
        return pairs[tokenA][tokenB];
    }

    /**
     * @inheritdoc IUniswapV2Factory
     */
    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    // ============ 核心功能实现 ============

    /**
     * @inheritdoc IUniswapV2Factory
     * @dev 创建交易对的完整流程：
     * 1. 验证输入参数的有效性
     * 2. 标准化代币地址顺序（字典序排序）
     * 3. 检查交易对是否已存在
     * 4. 使用CREATE2确定性部署交易对合约
     * 5. 初始化交易对合约
     * 6. 更新注册表（双向映射）
     * 7. 发出创建事件
     */
    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        // 1. 验证输入参数
        if (tokenA == tokenB) revert IdenticalAddresses();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();

        // 2. 标准化代币地址顺序（字典序排序）
        // 确保交易对唯一性：ETH/USDC 和 USDC/ETH 是同一个交易对
        (address token0, address token1) = UniswapV2Library.sortTokens(tokenA, tokenB);

        // 3. 检查交易对是否已存在
        if (pairs[token0][token1] != address(0)) revert PairExists();

        // 4. 使用CREATE2确定性部署
        // CREATE2的优势：
        // - 可预测地址：部署前就能计算出交易对地址
        // - Gas优化：避免地址查询的额外开销
        // - 安全性：防止地址碰撞攻击
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // 6. 初始化交易对合约
        IUniswapV2Pair(pair).initialize(token0, token1);

        // 7. 更新注册表
        // 双向映射设计：用户可以任意顺序查询代币对
        // 小幅增加存储成本，但显著提升用户体验
        pairs[token0][token1] = pair;
        pairs[token1][token0] = pair;

        // 添加到线性数组，支持遍历查询
        allPairs.push(pair);

        // 8. 发出创建事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // ============ 治理功能 ============

    /**
     * @inheritdoc IUniswapV2Factory
     * @dev 只有feeToSetter可以调用此函数
     * 设置为零地址表示关闭手续费功能
     */
    function setFeeTo(address _feeTo) external override {
        if (msg.sender != feeToSetter) revert Forbidden();
        feeTo = _feeTo;
    }

    /**
     * @inheritdoc IUniswapV2Factory
     * @dev 只有当前feeToSetter可以转移权限
     * 这是一个重要的治理功能，应谨慎使用
     */
    function setFeeToSetter(address _feeToSetter) external override {
        if (msg.sender != feeToSetter) revert Forbidden();
        feeToSetter = _feeToSetter;
    }

    // ============ 地址计算工具函数 ============

    /**
     * @notice 预计算交易对地址
     * @dev 利用CREATE2的确定性特性，无需部署即可计算地址
     * @param tokenA 第一个代币地址（函数内部会自动排序）
     * @param tokenB 第二个代币地址（函数内部会自动排序）
     * @return pair 预计算的交易对地址
     */
    function computePairAddress(address tokenA, address tokenB) external view returns (address pair) {
        (address token0, address token1) = UniswapV2Library.sortTokens(tokenA, tokenB);

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(type(UniswapV2Pair).creationCode)
            )
        );

        pair = address(uint160(uint256(hash)));
    }
}