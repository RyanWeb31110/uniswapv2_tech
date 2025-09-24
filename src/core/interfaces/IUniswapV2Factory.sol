// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title UniswapV2 工厂合约接口
 * @notice 定义创建和管理交易对的标准接口
 */
interface IUniswapV2Factory {
    // ============ 事件 ============

    /**
     * @notice 交易对创建事件
     * @param token0 第一个代币地址（按字典序排序）
     * @param token1 第二个代币地址（按字典序排序）
     * @param pair 新创建的交易对地址
     * @param index 当前交易对总数
     */
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256 index
    );

    // ============ 状态查询函数 ============

    /**
     * @notice 获取手续费接收地址
     * @return 手续费接收地址，如果为零地址则表示未开启手续费
     */
    function feeTo() external view returns (address);

    /**
     * @notice 获取手续费设置权限地址
     * @return 有权设置手续费的地址
     */
    function feeToSetter() external view returns (address);

    /**
     * @notice 通过代币地址获取交易对地址
     * @param tokenA 第一个代币地址
     * @param tokenB 第二个代币地址
     * @return pair 交易对合约地址，如果不存在则返回零地址
     */
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /**
     * @notice 获取指定索引的交易对地址
     * @param index 交易对索引
     * @return pair 交易对合约地址
     */
    function allPairs(uint256 index) external view returns (address pair);

    /**
     * @notice 获取交易对总数
     * @return 当前已创建的交易对数量
     */
    function allPairsLength() external view returns (uint256);

    // ============ 状态修改函数 ============

    /**
     * @notice 创建新的交易对合约
     * @param tokenA 第一个代币地址
     * @param tokenB 第二个代币地址
     * @return pair 新创建的交易对合约地址
     */
    function createPair(address tokenA, address tokenB) external returns (address pair);

    /**
     * @notice 设置手续费接收地址
     * @param _feeTo 新的手续费接收地址
     */
    function setFeeTo(address _feeTo) external;

    /**
     * @notice 转移手续费设置权限
     * @param _feeToSetter 新的权限持有者
     */
    function setFeeToSetter(address _feeToSetter) external;
}