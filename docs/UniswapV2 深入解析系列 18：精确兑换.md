# UniswapV2 深入解析系列 18：精确兑换

本篇第 18 篇延续上一章对 Router 的讨论，聚焦最常见的兑换入口 `swapExactTokensForTokens`。前端几乎所有“用固定数量兑换尽可能多目标代币”的需求都会落到这条路径上，因此理解其执行流程是把握 Uniswap 交互体验的关键。

在阅读本文前，建议先熟悉 `UniswapV2Library` 中 `getAmountOut` / `getAmountsOut` 的实现，以及 Pair 合约中 `swap` 函数的调用约定。这样能够更快串联 Router、Library、Pair 之间的协作关系。

## `swapExactTokensForTokens`函数签名与职责
```solidity
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
    // 1. 预估多跳兑换的每一步输出
    amounts = UniswapV2Library.getAmountsOut(address(factory), amountIn, path);

    // 2. 滑点保护：确保最终输出满足用户期望
    if (amounts[amounts.length - 1] < amountOutMin) {
        revert InsufficientOutputAmount();
    }

    // 3. 将输入代币转给首个交易对触发后续链式兑换
    _safeTransferFrom(
        path[0],
        msg.sender,
        UniswapV2Library.pairFor(address(factory), path[0], path[1]),
        amounts[0]
    );

    // 4. 沿路径逐跳完成兑换，并把最终代币发送到目标地址
    _swap(amounts, path, to);
}
```

函数职责可以概括为三点：预估所有兑换结果、在链上执行链式兑换、保障用户的最小可接受输出不被破坏。

核心逻辑都托管给 Library 与 Pair，Router 只负责协调调用顺序。

## 执行流程拆解

### 1. 预计算多跳输出
`UniswapV2Library.getAmountsOut` 会读取路径中相邻两两代币的储备数据，迭代调用 `getAmountOut` 来生成长度为 `path.length` 的数组。数组首位是 `amountIn`，其余元素分别对应每一跳兑换后的输出数量。通过一次性预计算可以避免在循环中重复读取储备，明显节省 gas。

### 2. 滑点保护与错误处理
自定义错误 `InsufficientOutputAmount`（需要在 Router 中新增定义）用于在最终输出低于 `amountOutMin` 时回滚交易。相比字符串错误，自定义错误的编码更短，也能被前端清晰识别。设置合理的 `amountOutMin` 可以抵御交易过程中由于手续费或价格波动带来的不确定性。

### 3. 输入代币转移策略
Router 使用内部工具 `_safeTransferFrom` 将 `amounts[0]` 直接发送给首个交易对。这样做的优势是：

- 减少中间账户，避免多余的 approve / transfer；
- 确保后续 `_swap` 逻辑只需要关注 Pair 之间的资金流向；
- 兼容返回值不规范的 ERC20 实现，降低集成风险。

### 4. 链式兑换的衔接逻辑
完成资金准备后，Router 通过 `_swap` 将预定的输出依次传递给路径上的每个 Pair。对于非终点 Pair，输出会直接发送到下一跳 Pair 的地址，从而省去多余的 `transfer` 调用；最后一跳才会把代币发给用户指定的地址 `to`。这一设计既能减少 gas 消耗，也能确保路径中的储备实时更新。

## `_swap` 内部协作机制
`_swap` 隐藏了多跳兑换的所有细节，代码结构如下：

```solidity
/// @notice 沿给定路径执行链式兑换
/// @param amounts 每一步兑换得到的代币数量数组
/// @param path 兑换路径，需保证长度大于等于 2
/// @param to 最终接收者地址
function _swap(
    uint256[] memory amounts,
    address[] memory path,
    address to
) internal {
    for (uint256 i; i < path.length - 1; i++) {
        (address input, address output) = (path[i], path[i + 1]);
        (address token0,) = UniswapV2Library.sortTokens(input, output);

        uint256 amountOut = amounts[i + 1];
        (uint256 amount0Out, uint256 amount1Out) = input == token0
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));

        address target = i < path.length - 2
            ? UniswapV2Library.pairFor(address(factory), output, path[i + 2])
            : to;

        IUniswapV2Pair(
            UniswapV2Library.pairFor(address(factory), input, output)
        ).swap(amount0Out, amount1Out, target, new bytes(0));
    }
}
```

这里的关键点包括：

- `sortTokens` 确保与 Pair 内部的 `token0/token1` 排序一致，避免输出顺序错误；
- `amounts[i + 1]` 被视为当前跳的输出数量，长度与路径保持同步；
- `target` 对于中间跳指向下一对交易对，只有最后一次调用才指向最终接收者；
- `swap` 的第四个参数使用空字节占位，预留给未来支持的闪电贷钩子。

## 架构设计亮点
- **职责单一**：Router 专注于调度流程，定价逻辑完全交由 Library 维护，避免重复实现造成的冗余。
- **模块解耦**：通过 `pairFor` 在链下计算 Pair 地址，既减少外部调用又维持 Factory 的中心化记录，避免循环依赖。
- **一致的错误体系**：配合自定义错误（如 `InsufficientOutputAmount`、`InvalidPath`），让所有失败原因都能被上层准确捕获。
- **扩展空间**：`path` 的抽象使多跳兑换成为默认能力，未来添加对手续费折扣或路由优化的扩展也十分自然。

## Foundry 测试指南
下面给出一份覆盖单跳、多跳与滑点回滚的 Foundry 测试示例，可保存为 `test/periphery/UniswapV2RouterSwap.t.sol`：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Factory.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/periphery/UniswapV2Router.sol";
import "../../src/libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title UniswapV2RouterSwapTest
/// @notice 使用 Foundry 验证 swapExactTokensForTokens 的关键路径
contract UniswapV2RouterSwapTest is Test {
    UniswapV2Factory private factory;
    UniswapV2Router private router;
    ERC20Mock private tokenA;
    ERC20Mock private tokenB;
    ERC20Mock private tokenC;

    /// @notice 初始化核心合约并注入基础流动性
    function setUp() public {
        factory = new UniswapV2Factory(address(this));
        router = new UniswapV2Router(address(factory));

        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        tokenC = new ERC20Mock();

        tokenA.mint(address(this), 2_000 ether);
        tokenB.mint(address(this), 2_000 ether);
        tokenC.mint(address(this), 2_000 ether);

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        _provideLiquidity(address(tokenA), address(tokenB), 500 ether, 500 ether);
        _provideLiquidity(address(tokenB), address(tokenC), 500 ether, 500 ether);
    }

    /// @notice 单跳兑换应返回与库函数一致的数量
    function testSwapExactTokensSingleHop() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory expected = UniswapV2Library.getAmountsOut(address(factory), 10 ether, path);
        uint256 balanceBefore = tokenB.balanceOf(address(this));

        uint256[] memory amounts = router.swapExactTokensForTokens(10 ether, expected[1], path, address(this));

        assertEq(amounts.length, 2, "length mismatch");
        assertEq(amounts[1], expected[1], "final output mismatch");
        assertEq(tokenB.balanceOf(address(this)) - balanceBefore, expected[1], "balance mismatch");
    }

    /// @notice 多跳兑换应正确衔接中间交易对
    function testSwapExactTokensMultiHop() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256[] memory expected = UniswapV2Library.getAmountsOut(address(factory), 10 ether, path);

        uint256[] memory amounts = router.swapExactTokensForTokens(10 ether, expected[2], path, address(this));

        assertEq(amounts[0], 10 ether, "input amount mismatch");
        assertEq(amounts[2], expected[2], "final output mismatch");
    }

    /// @notice 用户设置的最小输出高于预期时应回滚
    function testSwapExactTokensRevertsWhenSlippageTooTight() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory expected = UniswapV2Library.getAmountsOut(address(factory), 10 ether, path);

        vm.expectRevert(UniswapV2Router.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(10 ether, expected[1] + 1 ether, path, address(this));
    }

    /// @notice 通过 Router 快速补充双边流动性的内部工具
    function _provideLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        router.addLiquidity(token0, token1, amount0, amount1, 0, 0, address(this));
    }
}
```

如果需要聚焦本测试，可利用项目统一脚本运行：

```bash
./scripts/test.sh --match-path test/periphery/UniswapV2RouterSwap.t.sol
```

脚本会自动把完整日志写入 `logs/` 目录，便于后续排障与回溯。

## 测试步骤拆解
1. `setUp` 中部署 Factory、Router，并为三种代币分别铸造初始余额。
2. 使用 Router 的 `addLiquidity` 为 `AB`、`BC` 交易对注入对称储备，确保兑换路径畅通。
3. `testSwapExactTokensSingleHop` 通过库函数预估输出，并断言链上执行结果完全一致。
4. `testSwapExactTokensMultiHop` 验证多跳链路能够正确串联，最终输出与预估保持一致。
5. `testSwapExactTokensRevertsWhenSlippageTooTight` 模拟用户设置过高的 `amountOutMin`，确保合约抛出自定义错误。
6. 根据日志可进一步分析 gas 消耗或在测试中加入 `emit log_named_uint` 等调试手段。

## 注意事项与最佳实践
- **提前校验路径长度**：`path.length` 必须大于等于 2，建议在函数开头引入 `InvalidPath` 自定义错误以提升健壮性。
- **统一使用 Library**：即便在测试或脚本中，也应始终依赖 `UniswapV2Library` 计算兑换结果，避免手写公式导致的冗余与错误。
- **授权与余额检查**：调用前需保证输入代币已批准给 Router，且余额充足；这一步在前端与测试环境都应有明确提示。
- **善用日志**：结合 `scripts/test.sh` 的日志输出，可以快速定位异常交易并复盘所有跳数。

## 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech
