// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title 重入保护模块
 * @notice 提供重入攻击防护功能
 * @dev 通过状态锁机制防止合约函数被重入调用
 */
abstract contract ReentrancyGuard {
    // 使用 uint256 而不是 bool 以节省 gas
    // 1 = 未锁定, 2 = 锁定
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @notice 重入锁状态
    uint256 private _status;

    /**
     * @dev 构造函数初始化状态为未锁定
     */
    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev 防止重入调用的修饰器
     * 直接或间接调用自身的函数将被阻止
     */
    modifier nonReentrant() {
        // 检查当前状态
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // 设置锁定状态
        _status = _ENTERED;

        // 执行函数体
        _;

        // 恢复未锁定状态
        _status = _NOT_ENTERED;
    }

    /**
     * @notice 检查当前是否处于锁定状态
     * @return 如果当前已锁定返回 true，否则返回 false
     */
    function _isLocked() internal view returns (bool) {
        return _status == _ENTERED;
    }
}