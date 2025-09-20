// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/Math.sol";
import "../libraries/UQ112x112.sol";
import "../security/ReentrancyGuard.sol";

/**
 * @title UniswapV2Pair 核心交易对合约
 * @notice 管理特定代币对的流动性和交易
 * @dev 每个合约实例只处理一个代币对，实现核心的流动性管理功能
 */
contract UniswapV2Pair is ERC20Permit, ReentrancyGuard {
    using Math for uint256;
    using UQ112x112 for uint224;

    // ============ 自定义错误 ============

    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error Overflow();

    // ============ 常量定义 ============

    /// @notice 最小流动性，永久锁定以防止攻击
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice 用于安全计算的选择器
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));

    // ============ 状态变量 ============
    // 存储优化设计：合理布局变量以节省 Gas
    // 存储槽分布详解：
    // 槽 0: token0 (20 bytes) + 未使用 (12 bytes)
    // 槽 1: token1 (20 bytes) + 未使用 (12 bytes)  
    // 槽 2: reserve0 (14 bytes) + reserve1 (14 bytes) + blockTimestampLast (4 bytes) = 32 bytes (完美打包！)
    // 槽 3: price0CumulativeLast (32 bytes)
    // 槽 4: price1CumulativeLast (32 bytes)

    /// @notice 交易对中的第一个代币地址 (存储槽 0)
    address public token0;

    /// @notice 交易对中的第二个代币地址 (存储槽 1)
    address public token1;

    /// @notice token0 的储备量 (存储槽 2 - 打包变量 1/3)
    /// @dev 使用 uint112 而不是 uint256，与下面两个变量共享一个存储槽
    /// @dev uint112 最大值 ≈ 5.19 × 10^33，足够表示任何现实中的代币储备量
    uint112 private reserve0;

    /// @notice token1 的储备量 (存储槽 2 - 打包变量 2/3)  
    /// @dev 与 reserve0 和 blockTimestampLast 共享存储槽以节省 Gas
    uint112 private reserve1;

    /// @notice 最后更新储备的区块时间戳 (存储槽 2 - 打包变量 3/3)
    /// @dev uint32 可表示到 2106 年，与 reserve0、reserve1 完美打包到一个存储槽
    uint32 private blockTimestampLast;

    /// @notice token0 相对 token1 的累积价格（用于 TWAP 计算）(存储槽 3)
    uint256 public price0CumulativeLast;

    /// @notice token1 相对 token0 的累积价格（用于 TWAP 计算）(存储槽 4)
    uint256 public price1CumulativeLast;

    // ============ 事件定义 ============

    /// @notice 铸造 LP 代币事件
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);

    /// @notice 销毁 LP 代币事件
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    /// @notice 代币交换事件
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice 储备金同步事件
    event Sync(uint112 reserve0, uint112 reserve1);

    // ============ 构造函数 ============

    /**
     * @notice 初始化交易对合约
     * @param _token0 第一个代币地址
     * @param _token1 第二个代币地址
     */
    constructor(address _token0, address _token1)
        ERC20("ZUniswap V2", "ZUNI-V2")
        ERC20Permit("ZUniswap V2")
    {
        token0 = _token0;
        token1 = _token1;
    }

    // ============ 查看函数 ============

    /**
     * @notice 获取储备金信息
     * @return _reserve0 token0 储备量
     * @return _reserve1 token1 储备量
     * @return _blockTimestampLast 最后更新时间戳
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // ============ 内部函数 ============

    /**
     * @notice 安全转账函数
     * @param token 代币地址
     * @param to 接收地址
     * @param value 转账数量
     */
    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ZUniswapV2: TRANSFER_FAILED");
    }

    /**
     * @notice 更新储备金和累积价格
     * @param balance0 token0 的新余额
     * @param balance1 token1 的新余额
     */
    /**
     * @notice 更新储备金和累积价格
     * @dev 关键优化：一次 SSTORE 操作更新三个打包在同一存储槽中的值
     * @param balance0 token0 的新余额
     * @param balance1 token1 的新余额
     */
    function _update(uint256 balance0, uint256 balance1) private {
        // 检查数值是否超出 uint112 范围
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();

        // 读取当前储备值（一次 SLOAD 操作读取打包的三个值）
        uint112 _reserve0 = reserve0;
        uint112 _reserve1 = reserve1;
        uint32 _blockTimestampLast = blockTimestampLast;
        
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - _blockTimestampLast;

        // 更新累积价格（仅在时间推移且储备量非零时）
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 使用 unchecked 避免溢出检查，因为累积价格允许溢出
            unchecked {
                // 计算并累积 token0 相对 token1 的价格
                price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;

                // 计算并累积 token1 相对 token0 的价格
                price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
        }

        // 关键优化：一次 SSTORE 操作更新三个值（从 3 次 SSTORE 优化为 1 次）
        // 这三个变量打包在同一个存储槽中，同时更新只需要一次存储操作
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(reserve0, reserve1);
    }

    // ============ 外部函数 ============

    /**
     * @notice 铸造 LP 代币，添加流动性到池子
     * @dev 调用前需要先将代币转账到合约地址
     * @return liquidity 铸造的 LP 代币数量
     */
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // 获取储备金，节省 gas

        // 获取当前合约在两种代币中的余额
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // 计算新增的代币数量（当前余额减去储备金）
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply(); // 节省 gas

        if (_totalSupply == 0) {
            // 初始流动性提供时的处理
            // 使用几何平均数计算初始 LP 代币数量
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;

            // 永久锁定最小流动性以防止攻击
            _mint(address(0x000000000000000000000000000000000000dEaD), MINIMUM_LIQUIDITY);
        } else {
            // 后续流动性添加时的处理
            // 取较小值以惩罚不平衡的流动性提供
            liquidity = Math.min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }

        // 检查是否有足够的流动性可以铸造
        if (liquidity <= 0) revert InsufficientLiquidityMinted();

        // 向指定地址铸造 LP 代币
        _mint(to, liquidity);

        // 更新储备金数量
        _update(balance0, balance1);

        // 发出添加流动性事件
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @notice 销毁 LP 代币，移除流动性
     * @dev 将对应比例的两种代币发送给指定地址
     * @param to 接收代币的地址
     * @return amount0 返还的 token0 数量
     * @return amount1 返还的 token1 数量
     */
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        address _token0 = token0; // 节省 gas
        address _token1 = token1; // 节省 gas

        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply(); // 节省 gas

        // 使用余额确保按比例分配，防止捐赠攻击
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;

        if (amount0 <= 0 || amount1 <= 0) revert InsufficientLiquidityBurned();

        // 销毁 LP 代币
        _burn(address(this), liquidity);

        // 转账代币给用户
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        // 更新余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        // 更新储备金
        _update(balance0, balance1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @notice 代币交换函数
     * @param amount0Out 期望获得的 token0 数量
     * @param amount1Out 期望获得的 token1 数量
     * @param to 接收代币的地址
     * @param data 用于闪电贷的回调数据（本实现暂不支持）
     * @dev 使用预转账模式，调用前需要先向合约转入要交换的代币
     */
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        // 至少需要指定一个输出数量
        if (amount0Out <= 0 && amount1Out <= 0) revert InsufficientOutputAmount();

        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // 获取储备金

        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();

        uint256 balance0;
        uint256 balance1;

        {
            // 作用域限制，避免栈太深错误
            address _token0 = token0;
            address _token1 = token1;
            if (to == _token0 || to == _token1) revert InvalidTo();

            // 发送代币
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);

            // 闪电贷回调（暂不实现）
            // if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        if (amount0In <= 0 && amount1In <= 0) revert InsufficientInputAmount();

        {
            // 作用域限制，避免栈太深错误
            // 验证 K 常数：扣除 0.3% 手续费后，K 值应该不减少
            uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
            uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);

            if (balance0Adjusted * balance1Adjusted < uint256(_reserve0) * _reserve1 * (1000**2))
                revert InsufficientInputAmount();
        }

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
     * @notice 强制同步储备金与实际余额
     * @dev 紧急情况下使用，确保储备金与合约余额一致
     */
    function sync() external {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this))
        );
    }
}

