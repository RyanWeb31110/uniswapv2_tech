// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../core/UniswapV2Pair.sol";
import "../libraries/UQ112x112.sol";

/**
 * @title UniswapV2 价格预言机
 * @notice 基于 TWAP 的去中心化价格预言机实现
 * @dev 提供时间加权平均价格查询功能，抗价格操纵攻击
 */
contract UniswapV2Oracle {
    using UQ112x112 for uint224;

    // ============ 结构体定义 ============

    /// @notice 价格观察数据结构
    struct Observation {
        uint32 timestamp;               // 观察时间戳
        uint256 price0CumulativeLast;   // token0 的累积价格
        uint256 price1CumulativeLast;   // token1 的累积价格
    }

    // ============ 状态变量 ============

    /// @notice 交易对地址到观察数据的映射
    mapping(address => Observation) public pairObservations;

    /// @notice 最小观察时间间隔（防止价格操纵）
    uint32 public constant PERIOD = 1800; // 30 分钟

    // ============ 事件定义 ============

    /**
     * @notice 价格更新事件
     * @param pair 交易对地址
     * @param price0 token0 的 TWAP 价格
     * @param price1 token1 的 TWAP 价格
     */
    event PriceUpdate(address indexed pair, uint256 price0, uint256 price1);

    // ============ 自定义错误 ============

    error PeriodNotElapsed();
    error InvalidTimeElapsed();
    error ZeroAddress();

    // ============ 外部函数 ============

    /**
     * @notice 更新指定交易对的价格观察数据
     * @param pair 交易对合约地址
     */
    function update(address pair) external {
        if (pair == address(0)) revert ZeroAddress();

        Observation storage observation = pairObservations[pair];

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - observation.timestamp;

        // 确保时间间隔足够，防止价格操纵（首次初始化除外）
        if (observation.timestamp != 0 && timeElapsed < PERIOD) revert PeriodNotElapsed();

        // 获取当前累积价格
        uint256 price0Cumulative = UniswapV2Pair(pair).price0CumulativeLast();
        uint256 price1Cumulative = UniswapV2Pair(pair).price1CumulativeLast();

        // 更新观察数据
        observation.timestamp = blockTimestamp;
        observation.price0CumulativeLast = price0Cumulative;
        observation.price1CumulativeLast = price1Cumulative;

        emit PriceUpdate(pair, price0Cumulative, price1Cumulative);
    }

    /**
     * @notice 获取指定交易对的 TWAP 价格
     * @param pair 交易对合约地址
     * @return price0 token0 相对 token1 的 TWAP 价格
     * @return price1 token1 相对 token0 的 TWAP 价格
     */
    function consult(address pair) external view returns (uint256 price0, uint256 price1) {
        if (pair == address(0)) revert ZeroAddress();

        Observation memory observation = pairObservations[pair];

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - observation.timestamp;

        if (timeElapsed == 0) revert InvalidTimeElapsed();

        // 获取当前累积价格
        uint256 price0CumulativeCurrent = UniswapV2Pair(pair).price0CumulativeLast();
        uint256 price1CumulativeCurrent = UniswapV2Pair(pair).price1CumulativeLast();

        // 计算 TWAP
        price0 = (price0CumulativeCurrent - observation.price0CumulativeLast) / timeElapsed;
        price1 = (price1CumulativeCurrent - observation.price1CumulativeLast) / timeElapsed;
    }

    /**
     * @notice 检查交易对是否已初始化观察数据
     * @param pair 交易对地址
     * @return 是否已初始化
     */
    function isInitialized(address pair) external view returns (bool) {
        return pairObservations[pair].timestamp != 0;
    }

    /**
     * @notice 获取观察数据的时间戳
     * @param pair 交易对地址
     * @return 最后观察的时间戳
     */
    function getObservationTimestamp(address pair) external view returns (uint32) {
        return pairObservations[pair].timestamp;
    }

    /**
     * @notice 计算到下次可更新的剩余时间
     * @param pair 交易对地址
     * @return 剩余秒数，0 表示可以立即更新
     */
    function timeToNextUpdate(address pair) external view returns (uint32) {
        uint32 lastTimestamp = pairObservations[pair].timestamp;
        uint32 currentTimestamp = uint32(block.timestamp % 2**32);
        uint32 elapsed = currentTimestamp - lastTimestamp;

        if (elapsed >= PERIOD) {
            return 0;
        }
        return PERIOD - elapsed;
    }
}