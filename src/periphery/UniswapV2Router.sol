// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "../core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../core/interfaces/IUniswapV2Pair.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";

/// @title UniswapV2Router
/// @notice 统一封装流动性管理与兑换逻辑的路由器合约
contract UniswapV2Router {
    /// @dev 自定义错误：输入代币地址相同
    error IdenticalAddresses();
    /// @dev 自定义错误：接收者地址无效
    error InvalidRecipient();
    /// @dev 自定义错误：目标交易对不存在
    error PairNotFound();
    /// @dev 自定义错误：tokenA 数量低于最低阈值
    error InsufficientAAmount();
    /// @dev 自定义错误：tokenB 数量低于最低阈值
    error InsufficientBAmount();
    /// @dev 自定义错误：工厂地址未传入
    error FactoryAddressRequired();
    /// @dev 自定义错误：transferFrom 调用失败
    error TransferFromFailed();
    /// @dev 自定义错误：兑换路径长度无效
    error InvalidPath();
    /// @dev 自定义错误：最终输出金额低于阈值
    error InsufficientOutputAmount();

    /// @dev 工厂引用用于访问 `createPair` 与 `pairs` 映射
    IUniswapV2Factory public immutable factory;

    /// @notice 初始化路由器并绑定工厂地址
    /// @param factoryAddress 已部署的工厂合约地址
    constructor(address factoryAddress) {
        if (factoryAddress == address(0)) revert FactoryAddressRequired();
        factory = IUniswapV2Factory(factoryAddress);
    }

    /// @notice 向指定交易对注入双边流动性
    /// @param tokenA tokenA 地址，参与配对的第一种资产
    /// @param tokenB tokenB 地址，参与配对的第二种资产
    /// @param amountADesired 希望投入的 tokenA 数量（上限）
    /// @param amountBDesired 希望投入的 tokenB 数量（上限）
    /// @param amountAMin 可接受的最低 tokenA 数量，用于滑点保护
    /// @param amountBMin 可接受的最低 tokenB 数量，用于滑点保护
    /// @param to LP 代币接收地址
    /// @return amountA 实际投入的 tokenA 数量
    /// @return amountB 实际投入的 tokenB 数量
    /// @return liquidity 铸造出的 LP 代币数量
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // 1. 基础输入校验，提前阻断异常调用场景
        if (tokenA == tokenB) revert IdenticalAddresses();
        if (to == address(0)) revert InvalidRecipient();

        // 2. 查询已存在的交易对，没有则即时通过工厂创建
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = factory.createPair(tokenA, tokenB);
        }

        // 3. 根据池内储备与用户期望，得到实际的投入金额组合
        (amountA, amountB) = _calculateLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );

        // 4. 将两种代币从调用者账户转入 Pair，等待后续铸造流程
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);

        // 5. 调用 Pair.mint 完成储备更新，并取得新增 LP 份额
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    /// @notice 根据储备比例计算最终应投入的双边资金
    /// @dev 该函数封装比例校正与滑点验证，保持 addLiquidity 主流程简洁
    function _calculateLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        // 1. 读取目标交易对的最新储备数据，并按调用顺序返回
        (uint112 reserveA, uint112 reserveB) = UniswapV2Library.getReserves(
            address(factory),
            tokenA,
            tokenB
        );

        // 2. 首次注入时储备为零，直接沿用用户给定的期望值
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        // 3. 以 amountA 为基准计算另一侧的最优补足金额
        uint256 amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            // 校验最优金额是否仍满足用户自定义的最小滑点阈值
            if (amountBOptimal < amountBMin) revert InsufficientBAmount();
            return (amountADesired, amountBOptimal);
        }

        // 4. 若 tokenB 超出上限，则换以 amountB 为基准重新匹配
        uint256 amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
        if (amountAOptimal < amountAMin) revert InsufficientAAmount();
        return (amountAOptimal, amountBDesired);
    }


    /// @notice 从指定交易对中移除流动性
    /// @dev 调用前需确保调用者已对 Router 授权足够的 LP 代币
    /// @param tokenA 交易对中的第一个代币地址
    /// @param tokenB 交易对中的第二个代币地址
    /// @param liquidity 欲销毁的 LP 代币数量
    /// @param amountAMin 可接受的最小 tokenA 数量
    /// @param amountBMin 可接受的最小 tokenB 数量
    /// @param to 接收返还资产的地址
    /// @return amountA 实际返还的 tokenA 数量
    /// @return amountB 实际返还的 tokenB 数量
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB) {
        // 1. 校验基础参数并定位目标交易对
        if (tokenA == tokenB) revert IdenticalAddresses();
        if (to == address(0)) revert InvalidRecipient();
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        // 2. 将用户持有的 LP 代币转入交易对后执行 burn
        _safeTransferFrom(pair, msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(to);

        // 3. 标准化返回顺序并做滑点保护
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    /// @notice 将精确的输入代币数量沿路径兑换为目标代币
    /// @param amountIn 输入端付出的代币数量
    /// @param amountOutMin 用户可接受的最小输出数量（滑点保护）
    /// @param path 兑换路径，按逻辑顺序排列的代币地址数组
    /// @param to 最终接收兑换结果的地址
    /// @return amounts 每一步兑换返回的代币数量序列
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256[] memory amounts) {
        // 1. 基础参数校验，确保路径长度与接收者有效
        if (to == address(0)) revert InvalidRecipient();
        address[] memory pathMemory = path;
        if (pathMemory.length < 2) revert InvalidPath();

        // 2. 预估多跳兑换的每一步输出，并校验滑点
        amounts = UniswapV2Library.getAmountsOut(address(factory), amountIn, pathMemory);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

        // 3. 将输入代币直接转入首个交易对，为链式兑换做准备
        _safeTransferFrom(
            pathMemory[0],
            msg.sender,
            UniswapV2Library.pairFor(address(factory), pathMemory[0], pathMemory[1]),
            amounts[0]
        );

        // 4. 沿路径逐跳完成兑换，并把最终代币发送到目标地址
        _swap(amounts, pathMemory, to);
    }

    /// @notice 沿给定路径执行链式兑换
    /// @param amounts 每一步兑换得到的代币数量数组
    /// @param path 兑换路径，长度需大于等于 2
    /// @param to 最终接收者地址
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address to
    ) internal {
        // 1. 预先计算路径末尾索引，避免循环中重复求值
        uint256 lastIndex = path.length - 1;
        for (uint256 i; i < lastIndex; i++) {
            // 2. 逐跳解析输入与输出代币，并按字典序排序匹配 Pair 存储结构
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);

            // 3. 读取当前跳的目标输出，并转换为符合 token0/token1 顺序的参数
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));

            // 4. 查询本跳交易对地址，便于后续复用与调用 swap
            address currentPair = UniswapV2Library.pairFor(address(factory), input, output);

            // 5. 判断是否为终点跳，非终点则将输出直接发送给下一对以节省 gas
            address recipient = i < lastIndex - 1
                ? UniswapV2Library.pairFor(address(factory), output, path[i + 2])
                : to;

            // 6. 调用 Pair.swap 执行实际兑换，第四个参数留空以兼容未来钩子扩展
            IUniswapV2Pair(currentPair).swap(amount0Out, amount1Out, recipient, new bytes(0));
        }
    }

    /// @notice 安全地从用户处转移代币至目标地址
    /// @dev 兼容返回值不规范的 ERC20 实现
    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        // 1. 使用底层 call 触发 ERC20 的 transferFrom，兼容不同的返回模式
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        // 2. 联合校验执行状态与返回值，确保转账真实生效
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFromFailed();
    }
}
