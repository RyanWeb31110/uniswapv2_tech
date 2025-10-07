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
        uint32 timestamp;               // 最近一次更新的区块时间戳（取模 2^32）
        uint32 lastElapsed;             // 上一次有效观察所覆盖的时间跨度
        uint256 price0CumulativeLast;   // token0 的累积价格
        uint256 price1CumulativeLast;   // token1 的累积价格
        uint224 price0Average;          // 已计算好的 token1 相对 token0 的 TWAP（UQ112x112 格式）
        uint224 price1Average;          // 已计算好的 token0 相对 token1 的 TWAP（UQ112x112 格式）
    }

    // ============ 状态变量 ============

    /// @notice 交易对地址到观察数据的映射
    mapping(address => Observation) public pairObservations;

    /// @notice 最小观察时间间隔（防止价格操纵）
    uint32 public constant PERIOD = 1800; // 30 分钟

    /// @notice 平滑系数，用于限制单次更新对 TWAP 的冲击
    uint8 public constant SMOOTHING_FACTOR = 5;

    // ============ 事件定义 ============

    /**
     * @notice 价格更新事件
     * @param pair 交易对地址
     * @param price0 token1 相对 token0 的 TWAP 价格
     * @param price1 token0 相对 token1 的 TWAP 价格
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
        UniswapV2Pair pairContract = UniswapV2Pair(pair);

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = pairContract.getReserves();
        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        ) = _currentCumulativePrices(pairContract, reserve0, reserve1, blockTimestampLast);

        // 首次初始化仅记录基准值
        if (observation.timestamp == 0) {
            observation.timestamp = blockTimestamp;
            observation.lastElapsed = 0;
            observation.price0CumulativeLast = price0Cumulative;
            observation.price1CumulativeLast = price1Cumulative;
            observation.price0Average = 0;
            observation.price1Average = 0;
            return;
        }

        uint32 timeElapsed = _timeElapsed(observation.timestamp, blockTimestamp);

        if (timeElapsed < PERIOD) revert PeriodNotElapsed();

        uint256 intervalPrice0 = _intervalAverage(price0Cumulative, observation.price0CumulativeLast, timeElapsed);
        uint256 intervalPrice1 = _intervalAverage(price1Cumulative, observation.price1CumulativeLast, timeElapsed);

        uint224 price0Average = _smoothAverage(uint256(observation.price0Average), intervalPrice0);
        uint224 price1Average = _smoothAverage(uint256(observation.price1Average), intervalPrice1);

        observation.timestamp = blockTimestamp;
        observation.lastElapsed = timeElapsed;
        observation.price0CumulativeLast = price0Cumulative;
        observation.price1CumulativeLast = price1Cumulative;
        observation.price0Average = price0Average;
        observation.price1Average = price1Average;

        emit PriceUpdate(pair, price0Average, price1Average);
    }

    /**
     * @notice 获取指定交易对的 TWAP 价格
     * @param pair 交易对合约地址
     * @return price0 token1 相对 token0 的 TWAP 价格
     * @return price1 token0 相对 token1 的 TWAP 价格
     */
    function consult(address pair) external view returns (uint256 price0, uint256 price1) {
        if (pair == address(0)) revert ZeroAddress();

        Observation memory observation = pairObservations[pair];

        if (
            observation.timestamp == 0 ||
            observation.price0Average == 0 ||
            observation.price1Average == 0
        ) {
            revert InvalidTimeElapsed();
        }

        price0 = uint256(observation.price0Average);
        price1 = uint256(observation.price1Average);
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
        Observation memory observation = pairObservations[pair];

        if (observation.timestamp == 0) {
            return 0;
        }

        uint32 currentTimestamp = _currentBlockTimestamp();
        uint32 elapsed = _timeElapsed(observation.timestamp, currentTimestamp);

        if (elapsed >= PERIOD) {
            return 0;
        }
        return PERIOD - elapsed;
    }

    /**
     * @notice 获取当前区块时间戳（截断至 32 位）
     */
    function _currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    /**
     * @notice 计算包含当下时间增量的最新累积价格
     * @param pairContract 交易对合约实例
     * @param reserve0 当前储备中的 token0 数量
     * @param reserve1 当前储备中的 token1 数量
     * @param blockTimestampLast 交易对上次更新的时间戳
     * @return price0Cumulative 最新的 token0 累积价格
     * @return price1Cumulative 最新的 token1 累积价格
     * @return blockTimestamp 当前时间戳（截断至 32 位）
     */
    function _currentCumulativePrices(
        UniswapV2Pair pairContract,
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast
    )
        internal
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        price0Cumulative = pairContract.price0CumulativeLast();
        price1Cumulative = pairContract.price1CumulativeLast();
        blockTimestamp = _currentBlockTimestamp();

        if (reserve0 == 0 || reserve1 == 0) {
            return (price0Cumulative, price1Cumulative, blockTimestamp);
        }

        uint32 timeElapsed = _timeElapsed(blockTimestampLast, blockTimestamp);

        if (timeElapsed == 0) {
            return (price0Cumulative, price1Cumulative, blockTimestamp);
        }

        uint224 price0 = UQ112x112.encode(reserve1).uqdiv(reserve0);
        uint224 price1 = UQ112x112.encode(reserve0).uqdiv(reserve1);

        price0Cumulative += uint256(price0) * timeElapsed;
        price1Cumulative += uint256(price1) * timeElapsed;
    }

    /**
     * @notice 计算时间差，自动处理 uint32 溢出
     * @param fromTimestamp 起始时间戳
     * @param toTimestamp 结束时间戳
     */
    function _timeElapsed(uint32 fromTimestamp, uint32 toTimestamp) internal pure returns (uint32) {
        if (fromTimestamp == 0) {
            return 0;
        }

        if (toTimestamp >= fromTimestamp) {
            return toTimestamp - fromTimestamp;
        }

        // 处理 uint32 溢出的情况
        return (type(uint32).max - fromTimestamp) + toTimestamp + 1;
    }

    /**
     * @notice 计算区间内的平均价格增量
     * @param currentCumulative 当前累积价格
     * @param previousCumulative 上一次记录的累积价格
     * @param timeElapsed 区间持续时间
     * @return 区间平均值
     */
    function _intervalAverage(uint256 currentCumulative, uint256 previousCumulative, uint32 timeElapsed)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            return (currentCumulative - previousCumulative) / timeElapsed;
        }
    }

    /**
     * @notice 对区间平均值应用平滑处理，限制单次更新对 TWAP 的冲击
     * @param previousValue 之前缓存的平均值
     * @param intervalValue 本次观察区间的即时平均值
     * @return 平滑后的平均值（UQ112x112 格式）
     */
    function _smoothAverage(uint256 previousValue, uint256 intervalValue) internal pure returns (uint224) {
        if (previousValue == 0) {
            return uint224(intervalValue);
        }

        uint256 weighted = previousValue * uint256(SMOOTHING_FACTOR) + intervalValue;
        return uint224(weighted / (uint256(SMOOTHING_FACTOR) + 1));
    }
}
