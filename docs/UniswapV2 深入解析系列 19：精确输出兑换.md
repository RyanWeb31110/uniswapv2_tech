# UniswapV2 深入解析系列 19：精确输出兑换

延续第 18 篇对“精确输入兑换”的分析，本章聚焦另一条常被忽略的路径：用户提前锁定想要获得的输出数量，再推导出所需投入的最小代币金额。这类“反向兑换”在做市调仓、偿还借贷仓位或撮合做空头寸时尤其重要，也完整展示了 Router 与 Library 协同的另一面。

## 反向兑换的业务动机
- **达成既定交付目标**：提前约定好要偿付的债务或供货数量，需要保证最终收到的代币不少于约定值。
- **控制滑点风险**：多跳兑换中每一步都会吞噬一部分输出，推导输入上限可以防止意外超付。
- **套利与搬砖**：在多市场套利时，常见策略是锁定目标市场的下单量，再反向计算原市场所需的投入。

## 恒定乘积推导回顾
与正向兑换一样，Uniswap V2 的核心仍然是恒定乘积方程：

$$
(x + r\Delta x)(y - \Delta y) = xy
$$

其中 \(x\) 与 \(y\) 是当前池子的两侧储备，\(Δ y\) 是用户希望拿到的输出数量，\(Δ x\) 则是我们需要反向求解的输入金额，\(r\) 代表手续费倍率（标准实现等于 \(997/1000\)）。

通过基础代数运算，可以把 \(Δ x\) 表达为：

$$
\Delta x = \frac{x\,\Delta y}{(y - \Delta y)r}
$$

该表达式同时考虑了手续费与现有储备，揭示了随着输出越接近池子上限，分母越小，所需投入会呈指数级增长的事实。

## `getAmountIn` 函数实现
为了让 Router 与其它外围模块复用这段推导，我们在 `UniswapV2Library` 中补充如下函数：

```solidity
    /// @notice 根据精确输出金额计算所需的最小输入金额
    /// @param amountOut 用户期望获得的目标代币数量
    /// @param reserveIn 交易对中输入代币的当前储备
    /// @param reserveOut 交易对中输出代币的当前储备
    /// @return amountIn 满足兑换所需的最小输入数量
    function getAmountIn(
        uint256 amountOut,
        uint112 reserveIn,
        uint112 reserveOut
    ) internal pure returns (uint256 amountIn) {
        // 1. 基础参数校验，确保输出目标与池子储备有效
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) {
            revert InsufficientLiquidity();
        }

        // 2. 直接套用恒定乘积推导，记得保留手续费倍率
        uint256 numerator = uint256(reserveIn) * amountOut * 1000;
        uint256 denominator = (uint256(reserveOut) - amountOut) * 997;

        // 3. 加 1 以抵消 Solidity 向下取整造成的截断误差
        amountIn = numerator / denominator + 1;
    }
```

与正向兑换的 `getAmountOut` 类似，这里仍然通过自定义错误统一处理无效参数，并延续“先乘后除”的写法来避免精度丢失。需要特别注意分母部分 `(reserveOut - amountOut)`：一旦目标输出超过池子储备，即提前触发 `InsufficientLiquidity`，避免除以零。

## 多跳路径：`getAmountsIn`
反向兑换的多跳路径同样交由 Library 处理。实现思路与 `getAmountsOut` 完全对称，只是遍历顺序由前向后改为由后往前：

```solidity
    /// @notice 估算多跳路径下所需的最小输入金额序列
    /// @param factory 工厂合约地址
    /// @param amountOut 用户期望获得的最终输出数量
    /// @param path 兑换路径，长度至少为 2，结尾元素为目标代币
    /// @return amounts 与路径等长的金额数组，`amounts[0]` 即所需输入上限
    function getAmountsIn(
        address factory,
        uint256 amountOut,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();

        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;

        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint112 reserveIn, uint112 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
```

这样一来，Router 及测试代码都可以共享统一的数学推导结果，避免重复实现带来的维护成本。

## `swapTokensForExactTokens` 流程解析
当 Library 提供了必要的数学能力后，Router 中的高阶接口就可以顺理成章地落地：

```solidity
    /// @notice 将输入代币兑换为精确数量的目标代币
    /// @param amountOut 期望收到的目标代币数量
    /// @param amountInMax 用户可接受的最大输入金额，用于滑点保护
    /// @param path 兑换路径，首元素为输入代币，末元素为输出代币
    /// @param to 最终接收目标代币的地址
    /// @return amounts 每一跳实际使用的金额序列
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external returns (uint256[] memory amounts) {
        if (to == address(0)) revert InvalidRecipient();
        if (path.length < 2) revert InvalidPath();

        amounts = UniswapV2Library.getAmountsIn(address(factory), amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInputAmount();

        _safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(address(factory), path[0], path[1]),
            amounts[0]
        );

        _swap(amounts, path, to);
    }
```

核心逻辑可以拆解为三步：
1. **路径校验**：确保调用者传入有效路径与接收地址，避免无效交易导致的 Gas 浪费。
2. **输入上限计算**：通过 `getAmountsIn` 得到每一跳的所需金额，并立即与 `amountInMax` 做对比，提前终止超付场景。
3. **链式兑换复用**：复用已有的 `_swap` 内部函数完成链式兑换，保持 Router 内部结构的一致性与可维护性。

## 架构设计分析
- **职责单一**：数学推导全部收敛到 `UniswapV2Library`，Router 仅负责参数校验与资金流转，降低耦合度。
- **错误语义统一**：继续沿用自定义错误（如 `ExcessiveInputAmount`、`InsufficientLiquidity`），方便前端捕获具体失败原因。
- **接口复用**：`_swap`、`pairFor` 等内部工具函数无需重复实现，保证 Router 下不同兑换模式的实现保持一致。

## Foundry 测试
为了验证反向兑换的正确性，本章推荐使用 Foundry 编写以下测试用例。

### 测试合约
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Factory.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/periphery/UniswapV2Router.sol";
import "../../src/libraries/UniswapV2Library.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title UniswapV2RouterExactOutputTest
/// @notice 验证 Router 反向兑换路径的关键行为
contract UniswapV2RouterExactOutputTest is Test {
    UniswapV2Factory private factory;
    UniswapV2Router private router;
    ERC20Mock private tokenA;
    ERC20Mock private tokenB;
    ERC20Mock private tokenC;

    /// @notice 初始化合约并准备两条多跳路径的基础流动性
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

    /// @notice 单跳反向兑换应与库函数结果完全一致
    function testSwapTokensForExactTokensSingleHop() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountOut = 10 ether;
        uint256[] memory expected = UniswapV2Library.getAmountsIn(address(factory), amountOut, path);

        uint256 balanceBefore = tokenA.balanceOf(address(this));
        uint256[] memory amounts = router.swapTokensForExactTokens(amountOut, expected[0], path, address(this));

        assertEq(amounts[0], expected[0], "input amount mismatch");
        assertEq(amounts[1], amountOut, "output amount mismatch");
        assertEq(balanceBefore - tokenA.balanceOf(address(this)), expected[0], "balance delta mismatch");
    }

    /// @notice 多跳反向兑换应正确衔接中间交易对
    function testSwapTokensForExactTokensMultiHop() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountOut = 5 ether;
        uint256[] memory expected = UniswapV2Library.getAmountsIn(address(factory), amountOut, path);

        uint256[] memory amounts = router.swapTokensForExactTokens(amountOut, expected[0], path, address(this));

        assertEq(amounts[0], expected[0], "input amount mismatch");
        assertEq(amounts[2], amountOut, "final output mismatch");
    }

    /// @notice 用户设置的输入上限过小应当回滚
    function testSwapTokensForExactTokensRevertsWhenInputTooLow() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountOut = 10 ether;
        uint256[] memory expected = UniswapV2Library.getAmountsIn(address(factory), amountOut, path);

        vm.expectRevert(UniswapV2Router.ExcessiveInputAmount.selector);
        router.swapTokensForExactTokens(amountOut, expected[0] - 1, path, address(this));
    }

    /// @notice 将代币快速注入 Pair 的工具函数
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

### 测试执行流程
1. 根据上方示例在 `test/periphery` 目录中创建对应的 Foundry 测试文件。
2. 通过 `./scripts/test.sh` 触发测试运行，脚本会自动将日志写入 `logs/` 目录，便于排查。
3. 若环境提示 `Attempted to create a NULL object`，请在本地或 CI 环境升级 Foundry 后重试，这是已知的 macOS 兼容性问题。

## 注意事项与最佳实践
- **路径顺序**：`path[0]` 必须是输入代币，`path[path.length - 1]` 必须是目标代币，否则 `getReserves` 会读取错误储备。
- **输出上限**：`amountOut` 不能等于或超过池子当前储备，否则触发 `InsufficientLiquidity`。
- **输入加 1**：`getAmountIn` 最终结果加 1 是为了抵消向下取整，如果省略会导致实际输出略少于目标值。
- **链式安全**：对于多跳场景，请确保每一跳的交易对都已提前部署且流动性充足，避免在 `_swap` 时失败。

## 总结
精确输出兑换完善了 Router 的兑换矩阵，让协议既能满足“我有多少就全拿去换”的需求，也能支持“我必须拿到这么多”的反向场景。通过把数学推导沉淀到 Library、在 Router 中保持轻量流程处理，我们既提升了代码的可读性，也为后续功能（如限价单、闪兑聚合）奠定了坚实基础。

## 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech

