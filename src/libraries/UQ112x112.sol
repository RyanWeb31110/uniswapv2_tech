// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title UQ112x112 定点数运算库
 * @notice 提供高精度的定点数运算功能
 * @dev UQ112x112 表示一个 224 位的定点数，其中 112 位用于整数部分，112 位用于小数部分
 */
library UQ112x112 {
    /// @notice 2^112 用于编码和解码操作
    uint224 constant Q112 = 2**112;

    /**
     * @notice 将 uint112 编码为 UQ112x112 格式
     * @param y 待编码的 uint112 数值
     * @return z 编码后的 UQ112x112 数值
     */
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // 乘以 2^112，左移小数点
    }

    /**
     * @notice UQ112x112 除法运算
     * @param x 被除数（UQ112x112 格式）
     * @param y 除数（uint112 格式）
     * @return z 商（UQ112x112 格式）
     */
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }

    /**
     * @notice 将 UQ112x112 解码为 uint112
     * @param x UQ112x112 格式的数值
     * @return y 解码后的整数部分
     */
    function decode(uint224 x) internal pure returns (uint112 y) {
        y = uint112(x / Q112);
    }

    /**
     * @notice 获取 UQ112x112 数值的小数部分
     * @param x UQ112x112 格式的数值
     * @return 小数部分（作为 uint112 返回）
     */
    function fraction(uint224 x) internal pure returns (uint112) {
        return uint112(x % Q112);
    }

    /**
     * @notice UQ112x112 乘法运算
     * @param x 第一个 UQ112x112 数值
     * @param y 第二个 UQ112x112 数值
     * @return z 乘积（UQ112x112 格式）
     * @dev 结果可能溢出，调用者需要确保安全性
     */
    function mul(uint224 x, uint224 y) internal pure returns (uint224 z) {
        z = (x * y) / Q112;
    }

    /**
     * @notice UQ112x112 加法运算
     * @param x 第一个 UQ112x112 数值
     * @param y 第二个 UQ112x112 数值
     * @return z 和（UQ112x112 格式）
     */
    function add(uint224 x, uint224 y) internal pure returns (uint224 z) {
        z = x + y;
    }

    /**
     * @notice UQ112x112 减法运算
     * @param x 被减数（UQ112x112 格式）
     * @param y 减数（UQ112x112 格式）
     * @return z 差（UQ112x112 格式）
     */
    function sub(uint224 x, uint224 y) internal pure returns (uint224 z) {
        z = x - y;
    }

    /**
     * @notice 将 UQ112x112 转换为普通的 uint256（保留小数精度）
     * @param x UQ112x112 格式的数值
     * @return 转换后的 uint256，精度为 10^18
     */
    function decode144(uint224 x) internal pure returns (uint256) {
        return uint256(x) * 1e18 / Q112;
    }
}