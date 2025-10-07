# UniswapV2 深入解析系列 20：swap手续费修复与 K 值守护

本系列延续前几篇的深度拆解，聚焦于 UniswapV2 核心合约的关键分支与微调逻辑，为读者提供可直接落地的实践指南。

上一章我们验证了精确输出场景的价格计算，本篇回到 `Pair` 合约，针对长期被忽视的手续费缺口进行全面修复，确保自动做市恒定乘积模型不被破坏。

原始的 `swap` 函数虽通过恒定乘积检查限制输出，却没有对输入资金征收 0.3% swap 手续费，导致流动池实际增值低于预期，进而影响价格稳定性与协议收入。为了避免后续功能建立在错误的基石之上，本篇优先完成手续费修复。

## 原始实现的缺陷拆解
- **校验角度偏差**：旧代码直接取当前余额减去输出金额再参与乘积比较，忽略了应当先扣除手续费的事实。
- **激励模型失衡**：缺少手续费意味着套利者可以在恒定乘积曲线上“免费”穿越，协议、LP 与普通交易者之间的收益分配被打破。
- **脆弱性放大**：一旦引入闪电贷或复合策略，该缺口会迅速被利用，属于典型的系统性脆弱性。

## 修复策略概览
1. **先转后算**：参考官方实现，先向用户转出申领的代币，再读取余额推导真实的输入金额。
2. **推断输入金额**：通过“当前余额 - 旧储备 + 输出金额”推算新增资金，拒绝零输入场景。
3. **手续费落地**：对推断出的输入金额按 0.3% 计算手续费，并在整数域内处理放大系数，避免精度损失。
4. **重新校验恒定乘积**：以“扣除手续费后的余额”与旧储备比较，确保 `k` 值不下降。

## 关键代码解析
### 读取余额与转账顺序
```solidity
if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

uint256 balance0 = IERC20(token0).balanceOf(address(this));
uint256 balance1 = IERC20(token1).balanceOf(address(this));
```
在 `_safeTransfer` 执行后立即读取余额，可获得“转出后、入账前”的即时状态，有助于推断用户实际的输入金额。

### 推导输入金额与基础防御
```solidity
uint256 amount0In = balance0 > reserve0 - amount0Out
    ? balance0 - (reserve0 - amount0Out)
    : 0;
uint256 amount1In = balance1 > reserve1 - amount1Out
    ? balance1 - (reserve1 - amount1Out)
    : 0;

if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
```
把 `reserve` 视为“旧余额”，即可通过简单比较得到新增资金；当两个方向都为零时直接回滚，避免免费套利。

### 扣除手续费并重新校验
```solidity
uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);

if (
    balance0Adjusted * balance1Adjusted <
    uint256(reserve0_) * uint256(reserve1_) * (1000**2)
) revert InvalidK();
```
通过将余额放大 1000 倍，再减去 `amountIn * 3`，用整数模拟 0.3% 手续费；比较时同步放大旧储备，确保乘积守恒。在 Solidity 0.8 环境下，溢出自动被捕获，自定义错误 `InvalidK` 则提供清晰的失败原因。

## 机制推演：调整后乘积为何单调不减
- **恒定乘积模型**：理想情况下 `(x + Δx) * (y - Δy) ≥ x * y`。
- **手续费对 Δx 的影响**：真实入池资金为 `Δx * (1 - 0.003)`，直接比较未扣费的余额会低估乘积。
- **放大系数的意义**：把余额和储备同步放大 1000 倍，能在整数域内表达 0.3% 系数，避免精度损失与意外回滚。
- **架构收益**：机制封装在 `Pair` 层级，调用方无需关心手续费细节，符合“单一职责 + 不重复自己”的设计准则。

## 架构视角：核心模块协同
- **Pair 负责状态演进**：余额读取、手续费扣除与恒定乘积检验全部集中在 `Pair`，外围模块无需重复处理，降低冗余。
- **Library 统一公式**：`UniswapV2Library` 提供 `getAmountOut` 等方法，测试与业务逻辑都应复用，避免数据泥团。
- **Router 保持接口稳定**：外围合约继续复用既有接口，无需调整参数命名，减少僵化与兼容性风险。

## Foundry 测试重写
### 前置准备
- 使用 `scripts/test.sh` 统一触发测试，日志会自动写入 `logs/` 目录。
- 确保 `.env` 与 `foundry.toml` 与项目模板一致，避免环境变量引起的精度差异。

### 示例测试合约
```solidity
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {UniswapV2Pair} from "../../src/core/UniswapV2Pair.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract PairFeeTest is Test {
    ERC20Mock token0;
    ERC20Mock token1;
    UniswapV2Pair pair;

    function setUp() public {
        token0 = new ERC20Mock("TOKEN0", "TK0", address(this), 0);
        token1 = new ERC20Mock("TOKEN1", "TK1", address(this), 0);
        pair = new UniswapV2Pair();
        pair.initialize(address(token0), address(token1));

        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 20 ether);

        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 2 ether);
        pair.mint(address(this));
    }

    function testSwapRevertsWhenFeeUnpaid() public {
        token0.transfer(address(pair), 0.1 ether);

        vm.expectRevert(InvalidK.selector);
        pair.swap(0, 0.181322178776029827 ether, address(this), "");
    }

    function testSwapSucceedsAfterFeeDeduction() public {
        token0.transfer(address(pair), 0.1 ether);

        pair.swap(0, 0.181322178776029826 ether, address(this), "");

        (uint112 reserve0After, uint112 reserve1After,) = pair.getReserves();
        assertGt(uint256(reserve0After) * uint256(reserve1After), 2 ether);
    }
}
```

### 执行步骤
1. 运行 `./scripts/test.sh`，触发 Foundry 测试用例。
2. 检查最新日志，确认 `InvalidK` 回滚与成功交易均按预期发生。
3. 如遇沙箱限制，可在本地或 CI 环境复现上述流程。

## 最佳实践与常见陷阱
- **防止重复实现**：所有数学公式统一使用 `UniswapV2Library`，避免出现冗余函数或数据泥团。
- **谨慎处理整数运算**：先放大再扣费，避免极端情况下出现下溢导致的脆弱性。
- **关注执行顺序**：提前转账需配合严格的余额校验，以免被可重入合约利用。
- **保持接口稳定**：无充分理由不得改动对外接口或事件，防止引入新的僵化点。

## 小结
手续费缺口看似不起眼，却会破坏 UniswapV2 最核心的价格发现机制。本篇逐行拆解 `swap` 函数，展示如何在不改变接口的前提下修复 bug、稳固架构，并利用 Foundry 测试验证修复。掌握这套思路后，你可以在更复杂的衍生需求中保持代码的透明、稳定与可维护。

## 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech
