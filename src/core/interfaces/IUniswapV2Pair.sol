// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title UniswapV2 交易对合约接口
 * @notice 定义交易对合约的核心接口
 */
interface IUniswapV2Pair {
    // ============ 状态查询函数 ============

    /**
     * @notice 获取第一个代币地址
     * @return 第一个代币地址
     */
    function token0() external view returns (address);

    /**
     * @notice 获取第二个代币地址
     * @return 第二个代币地址
     */
    function token1() external view returns (address);

    /**
     * @notice 获取当前储备量
     * @return reserve0 第一个代币的储备量
     * @return reserve1 第二个代币的储备量
     * @return blockTimestampLast 最后更新时间戳
     */
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    // ============ 状态修改函数 ============

    /**
     * @notice 初始化交易对
     * @param _token0 第一个代币地址
     * @param _token1 第二个代币地址
     */
    function initialize(address _token0, address _token1) external;

    /**
     * @notice 添加流动性（铸造LP代币）
     * @param to LP代币接收地址
     * @return liquidity 铸造的LP代币数量
     */
    function mint(address to) external returns (uint256 liquidity);

    /**
     * @notice 移除流动性（销毁LP代币）
     * @param to 代币接收地址
     * @return amount0 返还的第一个代币数量
     * @return amount1 返还的第二个代币数量
     */
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice 执行代币交换
     * @param amount0Out 输出的第一个代币数量
     * @param amount1Out 输出的第二个代币数量
     * @param to 代币接收地址
     * @param data 回调数据
     */
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /**
     * @notice 强制储备量与余额同步
     * @param to 多余代币的接收地址
     */
    function skim(address to) external;

    /**
     * @notice 强制余额与储备量同步
     */
    function sync() external;
}