# UniswapV2 深入解析系列 14：函数库合约解析

本篇围绕 `UniswapV2Library` 展开，它是 Router 在执行流动性操作与代币兑换时的关键依赖。相比上一章对 Router 主流程的拆解，本文将聚焦于库函数的设计理念、源码实现细节以及与 Router 的联动方式，帮助读者彻底理解“无状态辅助合约”在 UniswapV2 架构中的作用。

## 1. 库合约定位与职责
- **共享工具集**：`UniswapV2Library` 被多个外围合约直接引用，统一提供排序、储备量查询与价格报价等纯函数，避免逻辑重复。
- **无状态执行**：所有函数均为 `internal` 或 `pure/view`，不依赖自身存储，通过 `DELEGATECALL` 在调用者上下文中运行，不会引入额外的状态管理负担。
- **Gas 友好**：常用计算在库中重用，减少 Router 内的重复运算；同一逻辑只需编译一次，整体部署成本更低。

## 2. 源码总览
下面是仓库当前的 `UniswapV2Library`（位于 `src/libraries/UniswapV2Library.sol`）的完整实现，并附带核心注释：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IUniswapV2Factory} from "../core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../core/interfaces/IUniswapV2Pair.sol";

library UniswapV2Library {
    /// @notice 输入数量为零时抛出的通用错误
    error InsufficientAmount();

    /// @notice 储备不足（至少一侧为零）时抛出的通用错误
    error InsufficientLiquidity();

    /// @notice 传入两个相同代币地址时抛出的错误
    error IdenticalAddresses();

    /// @notice 传入零地址时抛出的错误
    error ZeroAddress();

    /// @notice 工厂中找不到目标交易对时抛出的错误
    error PairNotFound();

    /// @notice 对两个代币地址进行字典序排序
    /// @dev 返回值 token0 永远小于 token1，用于规范化后续计算
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    /// @notice 查询工厂中指定交易对的储备量，并按照传入顺序返回
    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint112 reserveA, uint112 reserveB) {
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        (address token0,) = sortTokens(tokenA, tokenB);
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice 根据恒定乘积模型计算给定资产的理论兑换量
    function quote(uint256 amountA, uint112 reserveA, uint112 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }
}
```

### 2.1 自定义错误的价值
- **编码清晰**：比字符串错误节省 Gas，且便于调用方精确捕获异常类型。
- **与 Router 深度配合**：Router 流程中直接依赖这些错误，例如滑点校验失败会触发 `InsufficientLiquidity` 或自定义错误，前端可据此给出提示。

## 3. 核心函数逐一解析

### 3.1 `sortTokens`
- **业务需求**：Uniswap 的工厂以字典序存储交易对（`token0 < token1`），任何基于地址的查找都需要先排序。
- **实现要点**：
  - 当传入两个相同地址时立即 `revert IdenticalAddresses()`，防止错误配置。
  - `token0 == address(0)` 的额外校验保证任何下游逻辑都不会引用零地址。
- **最佳实践**：Router 在创建新对或查询储备前都应先调用该函数，以保持与 Factory 的顺序一致。

### 3.2 `getReserves`
- **执行流程**：
  1. 借助工厂的 `getPair` 获取配对地址；若不存在抛出 `PairNotFound`，上层可选择回退或创建新对。
  2. 调用 Pair 合约的 `getReserves` 获取原始储备值（返回顺序一定是 `token0/token1`）。
  3. 使用 `sortTokens` 判断 `tokenA` 是否对应 `token0`，再定位储备对应关系，保证返回顺序与调用者的参数一致。
- **为什么返回 `uint112`**：保持与 Pair 内部存储类型一致，避免额外的类型转换。

### 3.3 `quote`
- **核心作用**：在保持储备比例的前提下，计算当投入 `amountA` 时另一侧需要匹配的理论数量。
- **常见场景**：
  - Router 添加流动性时通过 `quote` 先估算最优投入，再与 `amountMin` 比较决定是否继续执行。
  - 通过在测试中调用 `quote`，可以验证 Router 返回值是否符合常数乘积模型。
- **约束与防御**：输入金额为零或任意一边储备为零会立即回退，阻止无意义的运算。

## 4. 与 Router 的联动案例
以 `test/periphery/UniswapV2RouterAddLiquidity.t.sol` 中的 `testAddLiquidityWithExistingReserves` 为例，说明库函数在 Router 流程中的关键角色：

```solidity
( uint112 reserveA, uint112 reserveB ) = UniswapV2Library.getReserves(
    address(factory),
    address(tokenA),
    address(tokenB)
);

uint256 amountBOptimal = UniswapV2Library.quote(120 ether, reserveA, reserveB);
uint256 expectedAmountA;
uint256 expectedAmountB;
if (amountBOptimal <= 80 ether) {
    expectedAmountA = 120 ether;
    expectedAmountB = amountBOptimal;
} else {
    expectedAmountA = UniswapV2Library.quote(80 ether, reserveB, reserveA);
    expectedAmountB = 80 ether;
}
// 在当前参数下 expectedAmountA = 96 ether，expectedAmountB = 80 ether

(uint256 amountA, uint256 amountB,) = router.addLiquidity(
    address(tokenA),
    address(tokenB),
    120 ether,
    80 ether,
    90 ether,
    70 ether,
    address(this)
);

assertApproxEqAbs(amountA, expectedAmountA, 1, "amountA optimal");
assertApproxEqAbs(amountB, expectedAmountB, 1, "amountB optimal");
```

该片段展示了库函数的实际用途：
- 先通过 `getReserves` 获取最新储备。
- 再用 `quote` 计算“理想状态下”的另一侧投入量，并结合用户设定的 `amountDesired` 与 `amountMin` 判定最终值。
- 测试中记录的注释直接给出了当前场景下的结果（96 与 80），避免“魔法数字”。

## 5. 测试与验证
测试代码参考文章：**UniswapV2 深入解析系列 13：Router 流动性管理流程与最佳实践**

### 5.1 场景规划

- **初始注入**：储备为零时应直接沿用用户输入。
- **再注入**：需走到 `quote` 逻辑验证比例校正。
- **滑点过紧**：通过设置较小的 `amountMin`，触发 Router 的自定义错误。

### 5.2 推荐命令
```bash
# 运行库与 Router 相关测试
forge test --match-contract UniswapV2RouterAddLiquidityTest -vvv

# 仅运行储备比例验证用例
forge test --match-test testAddLiquidityWithExistingReserves -vvv

# 生成 Gas 报告，关注库函数调用的成本
forge test --gas-report --match-contract UniswapV2RouterAddLiquidityTest
```


## 6. 常见陷阱与优化建议
- **地址排序缺失**：任何直接拼接 `tokenA/tokenB` 去查询储备或生成 CREATE2 地址的逻辑都必须先排序，否则会得到无效的配对地址。
- **储备为零**：`quote` 在储备为零时会直接回退，Router 在首次注入前应绕过比例校验，测试时也要构造好初始场景。
- **错误处理**：前端可根据库中抛出的错误精确提示，例如 `PairNotFound` 可引导用户先创建交易对。
- **Gas 管控**：库函数均为纯函数，注意在 Router 中不要重复调用，尽量缓存返回值。

## 7. 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech

欢迎克隆仓库，按照本文的步骤执行测试与调试，进一步熟悉无状态库在 UniswapV2 架构中的作用。
