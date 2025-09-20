// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title StorageOptimization 存储优化工具库
 * @notice 提供存储优化相关的工具函数，包括位运算打包和解包
 * @dev 展示如何使用位运算进行更高效的存储操作
 */
library StorageOptimization {
    // ============ 自定义错误 ============

    /// @notice 数值超出 uint112 范围
    error ReserveOverflow();
    
    /// @notice 时间戳超出 uint32 范围  
    error TimestampOverflow();

    // ============ 常量定义 ============

    /// @notice uint112 的最大值
    uint112 public constant MAX_UINT112 = type(uint112).max;
    
    /// @notice uint32 的最大值
    uint32 public constant MAX_UINT32 = type(uint32).max;

    /// @notice reserve0 的位掩码 (112 bits)
    uint256 private constant RESERVE0_MASK = 0xffffffffffffffffffffffffffff;
    
    /// @notice reserve1 的位掩码 (112 bits)
    uint256 private constant RESERVE1_MASK = 0xffffffffffffffffffffffffffff;

    // ============ 结构体定义 ============

    /**
     * @notice 优化的储备信息结构体
     * @dev 确保结构体成员按照大小排列以优化打包
     */
    struct ReserveInfo {
        uint112 reserve0;       // 14 bytes - 与下面的变量打包
        uint112 reserve1;       // 14 bytes
        uint32 timestamp;       // 4 bytes - 总计32 bytes，正好一个存储槽
        bool initialized;       // 1 bit - 被包含在上面的打包中
    }

    /**
     * @notice 未优化的储备信息结构体（用于对比）
     * @dev 展示错误的存储布局设计
     */
    struct UnoptimizedReserveInfo {
        uint256 reserve0;       // 32 bytes (1 slot)
        uint256 reserve1;       // 32 bytes (1 slot)
        uint256 timestamp;      // 32 bytes (1 slot)
        bool initialized;       // 1 byte but占用新的槽 (1 slot)
        // 总计：4 个存储槽
    }

    // ============ 位运算工具函数 ============

    /**
     * @notice 将三个值打包到一个 uint256 中
     * @dev 使用位运算进行高效打包
     * @param reserve0 储备量0 (uint112)
     * @param reserve1 储备量1 (uint112)
     * @param timestamp 时间戳 (uint32)
     * @return packed 打包后的值
     */
    function packValues(uint112 reserve0, uint112 reserve1, uint32 timestamp) 
        internal 
        pure 
        returns (uint256 packed) 
    {
        // 验证输入参数
        if (reserve0 > MAX_UINT112) revert ReserveOverflow();
        if (reserve1 > MAX_UINT112) revert ReserveOverflow();
        if (timestamp > MAX_UINT32) revert TimestampOverflow();

        // 位运算打包：
        // reserve0: 位 0-111 (112 bits)
        // reserve1: 位 112-223 (112 bits)  
        // timestamp: 位 224-255 (32 bits)
        packed = uint256(reserve0) | 
                (uint256(reserve1) << 112) | 
                (uint256(timestamp) << 224);
    }

    /**
     * @notice 从打包的值中解包
     * @dev 使用位运算和掩码进行高效解包
     * @param packed 打包的值
     * @return reserve0 储备量0
     * @return reserve1 储备量1
     * @return timestamp 时间戳
     */
    function unpackValues(uint256 packed) 
        internal 
        pure 
        returns (uint112 reserve0, uint112 reserve1, uint32 timestamp) 
    {
        // 位运算解包：
        // 使用位掩码提取各个字段
        reserve0 = uint112(packed & RESERVE0_MASK);
        reserve1 = uint112((packed >> 112) & RESERVE1_MASK);
        timestamp = uint32(packed >> 224);
    }

    /**
     * @notice 安全的类型转换检查
     * @dev 确保大数值可以安全转换为较小的类型
     * @param value 要转换的值
     * @return result 转换后的 uint112 值
     */
    function safeToUint112(uint256 value) internal pure returns (uint112 result) {
        if (value > MAX_UINT112) revert ReserveOverflow();
        result = uint112(value);
    }

    /**
     * @notice 安全的时间戳转换
     * @dev 将 block.timestamp 安全转换为 uint32
     * @param timestamp 要转换的时间戳
     * @return result 转换后的 uint32 时间戳
     */
    function safeToUint32(uint256 timestamp) internal pure returns (uint32 result) {
        // 使用模运算避免溢出，与 UniswapV2 保持一致
        result = uint32(timestamp % 2**32);
    }

    // ============ 存储分析工具 ============

    /**
     * @notice 计算存储槽使用情况
     * @dev 分析不同数据类型的存储槽占用
     * @return optimizedSlots 优化布局使用的存储槽数
     * @return unoptimizedSlots 未优化布局使用的存储槽数
     * @return savedSlots 节省的存储槽数
     */
    function analyzeStorageUsage() 
        internal 
        pure 
        returns (uint256 optimizedSlots, uint256 unoptimizedSlots, uint256 savedSlots) 
    {
        // 优化布局：
        // - ReserveInfo: 1 个存储槽 (uint112 + uint112 + uint32 + bool = 32 bytes)
        optimizedSlots = 1;

        // 未优化布局：
        // - UnoptimizedReserveInfo: 4 个存储槽
        unoptimizedSlots = 4;

        savedSlots = unoptimizedSlots - optimizedSlots;
    }

    /**
     * @notice 估算 Gas 节省情况
     * @dev 基于存储操作的成本计算 Gas 节省
     * @param operations 存储操作次数
     * @return savedGas 节省的 Gas 数量
     */
    function estimateGasSavings(uint256 operations) 
        internal 
        pure 
        returns (uint256 savedGas) 
    {
        // 存储操作成本：
        // - SSTORE (首次写入): ~20,000 Gas
        // - SSTORE (更新): ~5,000 Gas
        // - SLOAD: ~2,100 Gas

        // 假设平均每次操作节省 2 个存储槽的访问
        uint256 avgSstoreCost = 12500; // (20000 + 5000) / 2
        uint256 slotsPerOperation = 2;
        
        savedGas = operations * slotsPerOperation * avgSstoreCost;
    }

    // ============ 实用工具函数 ============

    /**
     * @notice 检查数值是否适合 uint112
     * @param value 要检查的数值
     * @return fits 是否适合 uint112
     */
    function fitsInUint112(uint256 value) internal pure returns (bool fits) {
        fits = value <= MAX_UINT112;
    }

    /**
     * @notice 检查时间戳是否适合 uint32
     * @param timestamp 要检查的时间戳
     * @return fits 是否适合 uint32
     */
    function fitsInUint32(uint256 timestamp) internal pure returns (bool fits) {
        fits = timestamp <= MAX_UINT32;
    }

    /**
     * @notice 获取类型的最大值信息
     * @return maxUint112 uint112 的最大值
     * @return maxUint32 uint32 的最大值
     * @return maxDateUint32 uint32 可表示的最大日期 (2106年)
     */
    function getTypeMaxValues() 
        internal 
        pure 
        returns (uint112 maxUint112, uint32 maxUint32, uint256 maxDateUint32) 
    {
        maxUint112 = MAX_UINT112;
        maxUint32 = MAX_UINT32;
        // uint32 最大值对应的时间戳 (2106年2月7日)
        maxDateUint32 = 4294967295; // 2^32 - 1
    }

    // ============ 调试和分析工具 ============

    /**
     * @notice 分析打包效率
     * @dev 计算存储空间的利用率
     * @param usedBits 实际使用的位数
     * @param totalBits 总位数 (通常是 256)
     * @return efficiency 效率百分比 (0-100)
     */
    function calculatePackingEfficiency(uint256 usedBits, uint256 totalBits) 
        internal 
        pure 
        returns (uint256 efficiency) 
    {
        require(usedBits <= totalBits, "Used bits cannot exceed total bits");
        efficiency = (usedBits * 100) / totalBits;
    }

    /**
     * @notice 获取 UniswapV2Pair 的打包效率
     * @dev 分析 reserve0 + reserve1 + timestamp 的打包效率
     * @return efficiency 打包效率百分比
     * @return usedBits 使用的位数
     * @return wastedBits 浪费的位数
     */
    function getUniswapV2PackingEfficiency() 
        internal 
        pure 
        returns (uint256 efficiency, uint256 usedBits, uint256 wastedBits) 
    {
        usedBits = 112 + 112 + 32; // reserve0 + reserve1 + timestamp
        uint256 totalBits = 256;
        wastedBits = totalBits - usedBits;
        efficiency = calculatePackingEfficiency(usedBits, totalBits);
    }
}