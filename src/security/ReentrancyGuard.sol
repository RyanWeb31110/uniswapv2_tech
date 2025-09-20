// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title ReentrancyGuard 重入保护合约
 * @notice 防止重入攻击的安全机制
 * @dev 提供 nonReentrant 修饰符来保护函数免受重入攻击
 * @dev Gas 优化版本：使用位标志而不是布尔值，更高效的状态管理
 */
abstract contract ReentrancyGuard {
    // ============ 常量定义 ============

    /// @notice 未进入状态 - 使用 1 而不是 0 以节省 Gas
    /// @dev Gas 优化原理：初始化为非零值(1)，在后续操作中只需要在非零值间切换(1↔2↔1)
    ///      而不是从 0 到非零值，这样可以避免昂贵的 SSTORE 操作
    uint256 private constant _NOT_ENTERED = 1;

    /// @notice 已进入状态 - 使用 2 确保状态明确区分
    uint256 private constant _ENTERED = 2;

    // ============ 状态变量 ============

    /// @notice 重入状态标记
    /// @dev 使用 uint256 而不是 bool 以实现更高效的状态管理
    /// @dev 存储优化：单个存储槽，避免多次 SSTORE 操作
    uint256 private _status;

    // ============ 自定义错误 ============

    /// @notice 检测到重入调用
    /// @dev 使用自定义错误而不是字符串以节省 Gas
    error ReentrantCall();

    // ============ 构造函数 ============

    /**
     * @notice 初始化重入保护状态
     * @dev Gas 优化：设置为 _NOT_ENTERED (1) 而不是 0
     */
    constructor() {
        _status = _NOT_ENTERED;
    }

    // ============ 修饰符 ============

    /**
     * @notice 防止重入调用的修饰符
     * @dev 在函数执行前检查重入状态，执行后恢复状态
     * @dev Gas 优化策略：
     *      1. 使用非零常量避免昂贵的零值写入
     *      2. 单次状态检查和更新
     *      3. 自定义错误减少 Gas 消耗
     */
    modifier nonReentrant() {
        // 检查是否已经在执行中 - 单次比較操作
        if (_status == _ENTERED) {
            revert ReentrantCall();
        }

        // 设置为已进入状态 - 单次 SSTORE 操作
        _status = _ENTERED;

        // 执行原函数逻辑
        _;

        // 恢复为未进入状态 - 单次 SSTORE 操作
        _status = _NOT_ENTERED;
    }

    // ============ 查看函数 ============

    /**
     * @notice 检查当前是否在执行中
     * @return entered 如果在执行中返回 true，否则返回 false
     * @dev Gas 优化：使用 view 函数，不消耗状态变更 Gas
     */
    function _reentrancyGuardEntered() internal view returns (bool entered) {
        entered = _status == _ENTERED;
    }

    /**
     * @notice 获取当前重入保护状态（用于调试）
     * @return status 当前状态值
     * @dev 仅在测试和调试时使用
     */
    function _getReentrancyStatus() internal view returns (uint256 status) {
        status = _status;
    }
}