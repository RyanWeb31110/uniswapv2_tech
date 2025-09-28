// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IUniswapV2Factory} from "../core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../core/interfaces/IUniswapV2Pair.sol";

/**
 * @title UniswapV2Library
 * @notice 为 Router 与周边模块提供公用的数学与数据查询工具
 * @dev 遵循 Uniswap V2 的经典实现，同时加入中文注释便于教学
 */
library UniswapV2Library {
    /// @notice 一般性错误：输入数量为零
    error InsufficientAmount();

    /// @notice 一般性错误：池子储备不足
    error InsufficientLiquidity();

    /// @notice 一般性错误：提供了两个相同的代币地址
    error IdenticalAddresses();

    /// @notice 一般性错误：存在零地址
    error ZeroAddress();

    /// @notice 工厂中尚未存在目标交易对
    error PairNotFound();

    /// @notice 兑换路径长度不符合要求
    error InvalidPath();

    /// @notice 对两个代币地址进行排序，确保后续处理顺序一致
    /// @dev 按照字典序排序，返回值 token0 永远小于 token1
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        // 1. 避免传入相同代币地址，确保交易对可区分
        if (tokenA == tokenB) revert IdenticalAddresses();
        // 2. 使用字典序排序以维持全局一致的 token0/token1 定义
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 3. 阻止零地址进入后续逻辑，避免与铸造流程冲突
        if (token0 == address(0)) revert ZeroAddress();
    }

    /// @notice 查询工厂中指定交易对的储备量，并按照传入顺序返回
    /// @param factory 工厂合约地址
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @return reserveA 与 tokenA 对应的储备量
    /// @return reserveB 与 tokenB 对应的储备量
    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint112 reserveA, uint112 reserveB) {
        // 1. 通过工厂查询现有 Pair 地址并确认其存在
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        // 2. 直接从 Pair 读取原始储备值（按 token0/token1 顺序返回）
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        // 3. 调用 sortTokens 复用排序规则，匹配调用者的 tokenA/tokenB 顺序
        (address token0,) = sortTokens(tokenA, tokenB);
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice 根据恒定乘积模型计算给定资产的理论兑换量
    /// @param amountA 输入资产数量
    /// @param reserveA 资产 A 的储备量
    /// @param reserveB 资产 B 的储备量
    /// @return amountB 需要的另一侧资产数量
    function quote(uint256 amountA, uint112 reserveA, uint112 reserveB) internal pure returns (uint256 amountB) {
        // 1. 检查输入数量合法，防止除零或无意义计算
        if (amountA == 0) revert InsufficientAmount();
        // 2. 校验储备是否为零，以免破坏恒定乘积推导
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        // 3. 按照恒定乘积公式推导对应的另一侧需求量
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice 根据恒定乘积模型计算交换可获得的输出金额
    /// @param amountIn 用户输入的源资产数量
    /// @param reserveIn 源资产在交易对中的当前储备量
    /// @param reserveOut 目标资产在交易对中的当前储备量
    /// @return amountOut 扣除手续费后实际可领取的目标资产数量
    function getAmountOut(
        uint256 amountIn,
        uint112 reserveIn,
        uint112 reserveOut
    ) internal pure returns (uint256 amountOut) {
        // 1. 参数校验：输入为零或储备不足时直接回退
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // 2. 计算扣除手续费后的有效输入金额
        uint256 amountInWithFee = amountIn * 997;

        // 3. 根据恒定乘积公式推导输出金额的显式解
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = uint256(reserveIn) * 1000 + amountInWithFee;

        // 4. 向下取整保证安全边界，返回最终可领取数量
        amountOut = numerator / denominator;
    }

    /// @notice 计算指定代币对的交易对地址
    /// @param factory 工厂合约地址
    /// @param tokenA 兑换路径中的源代币地址
    /// @param tokenB 兑换路径中的目标代币地址
    /// @return pair 对应的交易对合约地址
    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();
    }

    /// @notice 预估多跳兑换路径中每一步的输出金额
    /// @param factory 工厂合约地址
    /// @param amountIn 首个代币输入的数量
    /// @param path 兑换路径，长度至少为 2
    /// @return amounts 长度与路径一致的金额数组
    function getAmountsOut(
        address factory,
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i; i < path.length - 1; i++) {
            (uint112 reserveIn, uint112 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }
}
