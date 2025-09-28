# UniswapV2 深入解析系列 17：输出金额计算与路径滑点管理

继第 16 篇聚焦 LP 授权后，本篇将深入交换流程的数学基础，阐述输出金额的推导、实现与验证方法，并给出多跳路径下的滑点治理策略。

## 1. 常数乘积模型回顾

### 1.1 恒定乘积与价格关系
Uniswap V2 的定价遵循恒定乘积公式：

```
x × y = k
```

其中 x、y 分别是交易对的两种储备（`reserve0` 与 `reserve1`），k 为常数。价格可以视为储备之间的比值，但在执行 Swap 时，真正影响用户体验的是输入资产与输出资产的数量关系。

### 1.2 交换前后的状态方程
一次 Swap 会让储备发生变化，但手续费会被计入池子，使得 k 以极小幅度增长。将输入金额记为 Δx，输出金额记为 Δy，手续费系数记为 r = 1 − fee，则恒定乘积可写成：

```
(x + r·Δx) × (y − Δy) = x × y
```

公式表明：扣除手续费后注入池子的有效流动性与产出的资产之间满足同一个乘积约束。由此我们可以求解 Δy 的显式表达式，为 `getAmountOut` 提供理论基础。

推导过程如下，保持与合约实现一致的变量命名：
1. 展开左侧乘积：x·y − x·Δy + r·Δx·y − r·Δx·Δy = x·y。
2. 把同类项移到右侧：−x·Δy + r·Δx·y − r·Δx·Δy = 0。
3. 将 Δy 提取为公因子：r·Δx·y = Δy·(x + r·Δx)。
4. 两边同时除以 (x + r·Δx)，得到最终结果：Δy = r·Δx·y / (x + r·Δx)。

这个公式正是 `getAmountOut` 在整数运算下的数学来源。

## 2. 手续费与有效输入金额
- **手续费折算**：主网默认手续费为 0.3%，因此 r = 1 - 0.003 = 0.997。为了在整数运算中表达小数，需要统一乘以 1000，并在输入金额乘以 997 后再与 1000 基准合并。
- **整数向下取整**：Solidity 的除法向下取整，对应用户实际收到的数量。此行为与 Uniswap V2 期望一致，同时保证池子不会被多拿资产。
- **费用的收益归属**：被乘以 997 的那部分有效输入最终增加了 k，代表 LP 随着每次交易被动获益，为后续章节讨论的滑点积累提供了收益缓冲。

## 3. UniswapV2Library.getAmountOut 实现
```solidity
/// @notice 根据恒定乘积模型计算交换可获得的输出金额
/// @dev 统一在 Library 中复用，避免 Router、测试等模块重复实现
/// @param amountIn 用户输入的资产数量（源资产）
/// @param reserveIn 对应源资产在 Pair 中的当前储备量
/// @param reserveOut 另一种资产在 Pair 中的当前储备量
/// @return amountOut 实际可领取的目标资产数量（扣除手续费后）
function getAmountOut(
    uint256 amountIn,
    uint112 reserveIn,
    uint112 reserveOut
) internal pure returns (uint256 amountOut) {
    // 1. 参数校验：输入为零或储备为零都视为无效请求
    if (amountIn == 0) revert InsufficientAmount();
    if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

    // 2. 计算扣除手续费后的有效输入金额
    uint256 amountInWithFee = amountIn * 997;

    // 3. 套用恒定乘积公式推导出的显式解
    uint256 numerator = amountInWithFee * reserveOut;
    uint256 denominator = uint256(reserveIn) * 1000 + amountInWithFee;

    // 4. 整数除法向下取整，自动保留最保守的可领取数量
    amountOut = numerator / denominator;
}
```

> 提示：若后续需要支持不同费率，可将 997/1000 抽象为常量或由 Pair 存储的 `swapFee` 推导，某一侧修改时必须同步在文档与测试中说明。

## 4. 链式兑换中的滑点累积

### 4.1 多跳路径的数学延伸
链式兑换（例如 A→B→C）会重复调用 `getAmountOut`，每一跳的输出成为下一跳的输入。滑点会随着路径延长而乘积累积，路径规划需要在“价格最优”与“滑点可控”之间取舍。

### 4.2 Router 与 Library 的分工
- Router 只负责组织交易路径与进行可用性校验，具体的数学计算全部下沉到 Library，以保持核心逻辑的可复用性与可测试性。
- `getAmountsOut` 等函数在内部循环调用 `getAmountOut`，由此避免出现“不同函数重复实现同一公式”的冗余与潜在的不一致。
- 借助 Library，可以在测试中单独验证每一跳的输出是否正确，而无需部署完整的 Router 环境。

### 4.3 滑点控制策略
- **事前估算**：前端或脚本应在提交交易前根据最新储备调用 `getAmountsOut`，并设置合理的 `amountOutMin`。
- **监控储备**：若路径途径的任意 Pair 流动性过低，滑点会被放大。建议在前端增加储备阈值提示，防止用户在浅池子中进行大额兑换。
- **批量兑换**：大额交易拆分成多笔可以减轻瞬时滑点，但需要权衡额外的 gas 成本。

## 5. Foundry 测试落地方案

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {UniswapV2Library} from "src/libraries/UniswapV2Library.sol";

contract UniswapV2LibraryGetAmountOutTest is Test {
    /// @notice 验证基础场景中 getAmountOut 的数学正确性
    function test_getAmountOut_basicCase() public {
        uint112 reserveIn = 5_000 ether;
        uint112 reserveOut = 10_000 ether;
        uint256 amountIn = 100 ether;

        uint256 result = UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);

        uint256 amountInWithFee = amountIn * 997;
        uint256 expected = (amountInWithFee * reserveOut) / (uint256(reserveIn) * 1000 + amountInWithFee);

        assertEq(result, expected, "输出金额应与公式一致");
    }

    /// @notice 当输入为零时应直接回退，防止除以零
    function test_getAmountOut_revertWhenZeroAmount() public {
        vm.expectRevert(UniswapV2Library.InsufficientAmount.selector);
        UniswapV2Library.getAmountOut(0, 1_000 ether, 1_000 ether);
    }

    /// @notice 当任一储备为零时应回退，提示流动性不足
    function test_getAmountOut_revertWhenZeroReserve() public {
        vm.expectRevert(UniswapV2Library.InsufficientLiquidity.selector);
        UniswapV2Library.getAmountOut(1 ether, 0, 1_000 ether);
    }
}
```

### 5.1 测试流程拆解
1. **独立验证公式**：直接调用 Library，避免依赖 Router 部署，提高测试速度与可读性。
2. **覆盖异常路径**：通过 `vm.expectRevert` 验证自定义错误是否按预期触发，确保参数校验可靠。
3. **链式场景组合**：可在后续补充“多跳路径”的测试，将多次 `getAmountOut` 的输出串联，观察滑点累积情况。
4. **执行命令**：使用脚本 `./scripts/test.sh` 运行全部 Foundry 测试，日志会自动输出到 `logs/` 目录便于追踪。

## 6. 实践建议与常见问题
- **保持 Library 统一出口**：严禁在 Router、测试或外部脚本中重复实现输出金额公式，防止冗余与潜在的不一致。
- **动态手续费扩展**：若计划支持不同费率的池子，应将 997/1000 升级为可配置参数，同时更新文档与测试，避免脆弱性。
- **滑点阈值设置**：建议在前端提供“推荐滑点”区间，并在极端情况下阻止用户提交不合理的交易。
- **日志与监控**：结合 `Sync` 事件监控储备变化，辅助分析滑点、价格与手续费收益之间的关系。

## 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech

欢迎克隆仓库，结合本文实现 `getAmountOut` 及多跳路径管理的完整逻辑，并通过 Foundry 测试验证数学推导的正确性。
