// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title UniswapV2 闪电贷回调接口
/// @notice 当交易对合约执行乐观转账且 `data` 非空时触发
interface IUniswapV2Callee {
    /// @notice 闪电贷回调函数
    /// @param sender 触发 `swap` 的地址（通常为 Router 或其他调用方）
    /// @param amount0 借出的 token0 数量
    /// @param amount1 借出的 token1 数量
    /// @param data 借款方自定义的业务参数
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}
