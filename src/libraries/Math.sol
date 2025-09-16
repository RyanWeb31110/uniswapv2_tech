// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title Math 数学计算库
 * @notice 提供 UniswapV2 所需的数学计算函数
 * @dev 包含平方根计算和取最小值函数
 */
library Math {
    /**
     * @notice 计算平方根（巴比伦方法）
     * @dev 使用牛顿迭代法计算平方根，用于计算初始流动性
     * @param y 输入值
     * @return z 平方根结果
     */
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // 如果 y == 0，z 保持默认值 0
    }

    /**
     * @notice 返回两个数的最小值
     * @param x 第一个数
     * @param y 第二个数
     * @return 较小的数
     */
    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}