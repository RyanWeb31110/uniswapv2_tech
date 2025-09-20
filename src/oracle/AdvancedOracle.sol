// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./UniswapV2Oracle.sol";

/**
 * @title 增强型价格预言机
 * @notice 提供更多高级功能的价格预言机实现
 * @dev 支持多时间窗口观察、批量操作等功能
 */
contract AdvancedOracle is UniswapV2Oracle {
    // ============ 状态变量 ============

    /// @notice 多时间窗口观察数据映射
    mapping(address => mapping(uint32 => Observation)) public windowObservations;

    /// @notice 支持的时间窗口数组
    uint32[] public supportedPeriods = [600, 1800, 3600, 14400]; // 10分钟, 30分钟, 1小时, 4小时

    /// @notice 最小流动性阈值（防止低流动性池被操纵）
    uint256 public minimumLiquidity = 10000 ether;

    // ============ 事件定义 ============

    event WindowUpdate(address indexed pair, uint32 period, uint256 price0, uint256 price1);
    event MinimumLiquidityUpdated(uint256 oldValue, uint256 newValue);

    // ============ 自定义错误 ============

    error UnsupportedPeriod();
    error InsufficientTimeElapsed();
    error InsufficientLiquidity();
    error InvalidArrayLength();

    // ============ 管理函数 ============

    /**
     * @notice 设置最小流动性阈值
     * @param _minimumLiquidity 新的最小流动性值
     */
    function setMinimumLiquidity(uint256 _minimumLiquidity) external {
        uint256 oldValue = minimumLiquidity;
        minimumLiquidity = _minimumLiquidity;
        emit MinimumLiquidityUpdated(oldValue, _minimumLiquidity);
    }

    // ============ 多时间窗口功能 ============

    /**
     * @notice 更新指定时间窗口的观察数据
     * @param pair 交易对地址
     * @param period 时间窗口（秒）
     */
    function updateWindow(address pair, uint32 period) external {
        if (!isSupportedPeriod(period)) revert UnsupportedPeriod();
        if (pair == address(0)) revert ZeroAddress();

        Observation storage observation = windowObservations[pair][period];

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - observation.timestamp;

        if (observation.timestamp != 0 && timeElapsed < period) revert InsufficientTimeElapsed();

        // 检查流动性
        (uint112 reserve0, uint112 reserve1,) = UniswapV2Pair(pair).getReserves();
        uint256 liquidity = uint256(reserve0) * uint256(reserve1);
        if (liquidity < minimumLiquidity) revert InsufficientLiquidity();

        // 获取当前累积价格
        uint256 price0Cumulative = UniswapV2Pair(pair).price0CumulativeLast();
        uint256 price1Cumulative = UniswapV2Pair(pair).price1CumulativeLast();

        // 更新观察数据
        observation.timestamp = blockTimestamp;
        observation.price0CumulativeLast = price0Cumulative;
        observation.price1CumulativeLast = price1Cumulative;

        emit WindowUpdate(pair, period, price0Cumulative, price1Cumulative);
    }

    /**
     * @notice 获取指定时间窗口的 TWAP 价格
     * @param pair 交易对地址
     * @param period 时间窗口（秒）
     * @return price0 token0 的 TWAP 价格
     * @return price1 token1 的 TWAP 价格
     */
    function consultWithPeriod(address pair, uint32 period)
        external
        view
        returns (uint256 price0, uint256 price1)
    {
        if (!isSupportedPeriod(period)) revert UnsupportedPeriod();
        if (pair == address(0)) revert ZeroAddress();

        Observation memory observation = windowObservations[pair][period];

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - observation.timestamp;

        if (observation.timestamp == 0 || timeElapsed < period) revert InsufficientTimeElapsed();

        uint256 price0CumulativeCurrent = UniswapV2Pair(pair).price0CumulativeLast();
        uint256 price1CumulativeCurrent = UniswapV2Pair(pair).price1CumulativeLast();

        price0 = (price0CumulativeCurrent - observation.price0CumulativeLast) / timeElapsed;
        price1 = (price1CumulativeCurrent - observation.price1CumulativeLast) / timeElapsed;
    }

    /**
     * @notice 检查时间窗口是否受支持
     * @param period 时间窗口
     * @return 是否受支持
     */
    function isSupportedPeriod(uint32 period) public view returns (bool) {
        for (uint i = 0; i < supportedPeriods.length; i++) {
            if (supportedPeriods[i] == period) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice 获取所有支持的时间窗口
     * @return 时间窗口数组
     */
    function getSupportedPeriods() external view returns (uint32[] memory) {
        return supportedPeriods;
    }

    // ============ 批量操作功能 ============

    /**
     * @notice 批量更新多个交易对的价格
     * @param pairs 交易对地址数组
     */
    function batchUpdate(address[] calldata pairs) external {
        for (uint i = 0; i < pairs.length; i++) {
            this.update(pairs[i]);
        }
    }

    /**
     * @notice 批量更新多个交易对的指定时间窗口
     * @param pairs 交易对地址数组
     * @param period 时间窗口
     */
    function batchUpdateWindow(address[] calldata pairs, uint32 period) external {
        if (!isSupportedPeriod(period)) revert UnsupportedPeriod();

        for (uint i = 0; i < pairs.length; i++) {
            this.updateWindow(pairs[i], period);
        }
    }

    /**
     * @notice 批量查询多个交易对的价格
     * @param pairs 交易对地址数组
     * @return prices0 token0 价格数组
     * @return prices1 token1 价格数组
     */
    function batchConsult(address[] calldata pairs)
        external
        view
        returns (uint256[] memory prices0, uint256[] memory prices1)
    {
        prices0 = new uint256[](pairs.length);
        prices1 = new uint256[](pairs.length);

        for (uint i = 0; i < pairs.length; i++) {
            (prices0[i], prices1[i]) = this.consult(pairs[i]);
        }
    }

    // ============ 安全功能 ============

    /**
     * @notice 安全的价格获取函数（带流动性检查）
     * @param pair 交易对地址
     * @param minLiquidity 最小流动性要求
     * @return price0 token0 价格
     * @return price1 token1 价格
     * @return isValid 价格是否有效
     */
    function getSafePrice(address pair, uint256 minLiquidity)
        external
        view
        returns (uint256 price0, uint256 price1, bool isValid)
    {
        // 检查流动性
        (uint112 reserve0, uint112 reserve1,) = UniswapV2Pair(pair).getReserves();
        uint256 liquidity = uint256(reserve0) * uint256(reserve1);

        if (liquidity < minLiquidity) {
            return (0, 0, false);
        }

        try this.consult(pair) returns (uint256 p0, uint256 p1) {
            // 额外的价格合理性检查
            if (p0 > 0 && p1 > 0 && p0 < type(uint256).max / 1e18 && p1 < type(uint256).max / 1e18) {
                return (p0, p1, true);
            }
        } catch {
            return (0, 0, false);
        }

        return (0, 0, false);
    }

    /**
     * @notice 获取价格偏差信息
     * @param pair 交易对地址
     * @param shortPeriod 短时间窗口
     * @param longPeriod 长时间窗口
     * @return deviation 价格偏差（以 basis points 表示）
     * @return direction 偏差方向（true: 短期价格高于长期, false: 相反）
     */
    function getPriceDeviation(address pair, uint32 shortPeriod, uint32 longPeriod)
        external
        view
        returns (uint256 deviation, bool direction)
    {
        if (!isSupportedPeriod(shortPeriod) || !isSupportedPeriod(longPeriod)) {
            revert UnsupportedPeriod();
        }

        require(shortPeriod < longPeriod, "Short period must be less than long period");

        (uint256 shortPrice0,) = this.consultWithPeriod(pair, shortPeriod);
        (uint256 longPrice0,) = this.consultWithPeriod(pair, longPeriod);

        if (shortPrice0 > longPrice0) {
            deviation = ((shortPrice0 - longPrice0) * 10000) / longPrice0;
            direction = true;
        } else {
            deviation = ((longPrice0 - shortPrice0) * 10000) / longPrice0;
            direction = false;
        }
    }

    // ============ 查询函数 ============

    /**
     * @notice 获取交易对的流动性信息
     * @param pair 交易对地址
     * @return reserve0 token0 储备量
     * @return reserve1 token1 储备量
     * @return liquidity 流动性（reserve0 * reserve1）
     */
    function getLiquidityInfo(address pair)
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint256 liquidity)
    {
        (reserve0, reserve1,) = UniswapV2Pair(pair).getReserves();
        liquidity = uint256(reserve0) * uint256(reserve1);
    }

    /**
     * @notice 检查交易对是否有足够的流动性
     * @param pair 交易对地址
     * @return 是否有足够的流动性
     */
    function hasSufficientLiquidity(address pair) external view returns (bool) {
        (, , uint256 liquidity) = this.getLiquidityInfo(pair);
        return liquidity >= minimumLiquidity;
    }
}