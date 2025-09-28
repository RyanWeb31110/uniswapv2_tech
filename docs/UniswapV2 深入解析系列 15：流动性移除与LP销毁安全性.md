# UniswapV2 深入解析系列 15：流动性移除与 LP 销毁安全性

在上一章中我们完成了 Router 的流动性添加流程。本篇继续沿着“端到端流动性管理”这一主线，聚焦于 **LP 代币销毁的安全性** 与 **流动性移除（removeLiquidity）** 的设计方案。我们将先回顾历史上的漏洞案例，再分析当前仓库中 `UniswapV2Pair` 的实现细节，并给出 Router 端的设计草案与测试策略，帮助读者在实战中规避隐患。



## 1. 问题背景：LP 代币销毁漏洞复盘

### 1.1 漏洞症状
之前实现的 `UniswapV2Pair.burn` 直接对 `msg.sender` 的 LP 代币执行销毁：
```solidity
// 旧实现（已弃用）
uint256 liquidity = balanceOf(msg.sender);
_burn(msg.sender, liquidity);
```
调用者甚至无需提前把 LP 代币转入交易对，**合约即可擅自减少其余额**。这违反了 ERC20 授权语义，同时为恶意合约留下可乘之机（例如在闪电贷中强制销毁第三方 LP）。

### 1.2 修复方式
当前版本已改为 **仅销毁 Pair 合约自身持有的 LP 代币**，并要求调用方在调用 `burn` 前将 LP 代币显式转入：
```solidity
uint256 balance0 = IERC20(_token0).balanceOf(address(this));
uint256 balance1 = IERC20(_token1).balanceOf(address(this));
uint256 liquidity = balanceOf(address(this));
...
_burn(address(this), liquidity);
```
这样可以确保：
1. 用户必须用 `transferFrom` 或 `transfer` 将 LP 代币托管到 Pair。  
2. Pair 根据自身真实持仓计算应退还的 `amount0/amount1`。  
3. 只有托管中的 LP 会被销毁，不会误伤外部地址。

### 1.3 实战启示
- 任何扣减余额的操作都必须基于显式授权或转账，避免“暗箱操作”。
- 建议在前端及链上监控中订阅 `Burn`、`Transfer` 事件，监控异常销毁记录。



## 2. `UniswapV2Pair.burn` 最新实现拆解

### 2.1 核心流程
1. **读取余额与总供应量**：以 Pair 自身的代币余额与 LP 余额为基准。  
2. **按比例计算应退金额**：`amount0 = liquidity * balance0 / totalSupply`。  
3. **销毁 LP 代币**：执行 `_burn(address(this), liquidity)`。  
4. **转账两种资产给用户**，随后调用 `_update` 刷新储备并触发 `Burn` 事件。

### 2.2 关键代码片段
```solidity
// 读取 Pair 自身持仓，计算应退比例并销毁托管的 LP 代币
uint256 balance0 = IERC20(_token0).balanceOf(address(this));
uint256 balance1 = IERC20(_token1).balanceOf(address(this));
uint256 liquidity = balanceOf(address(this));

uint256 _totalSupply = totalSupply();
amount0 = (liquidity * balance0) / _totalSupply;
amount1 = (liquidity * balance1) / _totalSupply;

if (amount0 <= 0 || amount1 <= 0) revert InsufficientLiquidityBurned();
_burn(address(this), liquidity);

_safeTransfer(_token0, to, amount0);
_safeTransfer(_token1, to, amount1);
_update(
    IERC20(_token0).balanceOf(address(this)),
    IERC20(_token1).balanceOf(address(this))
);
```
这段代码中的 `liquidity = balanceOf(address(this))` 读取的是交易对合约当前托管的 LP 代币份额，也就是用户在调用 Router 或 Pair 的 `burn` 前已经通过 `transfer`/`transferFrom` 转入的数量。

而 `totalSupply()` 则来自 LP 代币合约（Pair 继承自 ERC20），表示 LP 代币的全部发行量，其中包含用户持有的份额以及永久锁定在死地址的 `MINIMUM_LIQUIDITY`。

整体流程可拆分为三个阶段：
1. **读取状态并计算比例**：通过 `liquidity` 与 `totalSupply` 按比例计算调用方应收回的 `amount0/amount1`，若其中任意值为零则立即回退，防止流动性不足的异常情况。
2. **销毁 LP 份额**：`_burn(address(this), liquidity)` 只会销毁 Pair 自身托管的份额，避免误删用户未托管的 LP；这样既遵循 ERC20 授权语义，也能抵御恶意调用。
3. **返还资产并同步储备**：按比例把两种资产转给用户后，再次读取合约余额并调用 `_update` 刷新储备值，保持后续报价与库函数计算都是基于最新状态。

通过这一套流程，Pair 在移除流动性时能够做到“只针对托管的 LP 销毁、精确返还资产、并保持储备数据同步”，为 Router 的 remove 流程提供安全且可预测的底层基础。



## 3. Router `removeLiquidity` 设计蓝图

1. **参数校验**：拒绝相同 Token、零地址接收人、零 `liquidity` 等非法输入。  
2. **定位交易对**：通过 Factory 查询 Pair；若不存在提示用户先创建&注入流动性。  
3. **拉取储备并评估比例**：使用 `UniswapV2Library.getReserves` 与 `quote` 计算理想返还值。  
4. **转移 LP 代币**：Router 使用 `transferFrom` 将调用者的 LP 份额发送给 Pair。  
5. **调用 `burn` 领取资产**：Pair 返回 `(amount0, amount1)` 并更新储备。  
6. **滑点保护**：将返回值与 `amountAMin/amountBMin` 比较，不满足则回退整个交易。  
7. **结果返回**：按 Token 顺序封装 `(amountA, amountB)` 并返还给上层调用。

对应的代码示例如下：
```solidity
function removeLiquidity(
    address tokenA,
    address tokenB,
    uint256 liquidity,
    uint256 amountAMin,
    uint256 amountBMin,
    address to
) external returns (uint256 amountA, uint256 amountB) {
    // 1. 参数校验与交易对定位
    if (tokenA == tokenB) revert IdenticalAddresses();
    if (to == address(0)) revert InvalidRecipient();
    address pair = factory.getPair(tokenA, tokenB);
    if (pair == address(0)) revert PairNotFound();

    // 2. 将 LP 代币托管到 Pair 并执行 burn
    IERC20(pair).transferFrom(msg.sender, pair, liquidity);
    (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(to);

    // 3. 标准化返回值并进行滑点保护
    (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
    (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
    if (amountA < amountAMin) revert InsufficientAAmount();
    if (amountB < amountBMin) revert InsufficientBAmount();
}
```

#### **为何需要滑点保护**

自定义错误（例如 `InvalidRecipient()`、`InsufficientBAmount()`）已经取代字符串回退，便于前端通过错误选择器快速定位失败原因并给出有针对性的提示。

移除流动性得到的 `amount0/amount1` 取决于池子实时储备比例，而这个比例可能在交易被打包前因其他交易而发生变化。

如果缺少 `amountAMin/amountBMin`，用户可能拿回远低于预期的某一侧资产（极端情况下甚至接近 0），从而产生真实损失。

通过滑点参数设定“最低可接受收益”，只要返还金额低于阈值，交易就会自动回滚，从根源上抵御抢跑、价格剧烈波动等风险。

这与 swap 操作中设定 `amountOutMin` 的目的完全一致。



## 4. 测试策略与命令

### 4.1 覆盖场景
- **LP 销毁安全性**：验证未转移 LP 时 `burn` 不会减少余额，以及转移后能正确按比例返还。
- **滑点保护**：构造多种储备情况，确保 `amountMin` 触发策略正常。
- **事件监听**：断言 `Burn`、`Transfer`、`Sync` 等事件的参数，方便前端与分析工具消费。

### 4.2 建议命令
```bash
# Pair 流动性销毁相关测试
forge test --match-contract UniswapV2PairTest --match-test testBurn -vvv

# Router 流动性流程（含 add/remove 组合）
forge test --match-contract UniswapV2RouterAddLiquidityTest -vvv

# 聚焦比例换算逻辑
forge test --match-test testAddLiquidityWithExistingReserves -vvv
```



## 5. 最佳实践与常见陷阱
- **统一使用 `UniswapV2Library`**：排序、储备、报价均应复用库函数，避免手写逻辑导致顺序不一致。  
- **留意 `MINIMUM_LIQUIDITY`**：销毁时切勿误退对已永久锁定的最小流动性份额。  
- **前端滑点提示**：为 remove 流程提供默认滑点范围与失败原因，减少用户误解。  
- **事件审计**：生产环境建议订阅 `Burn`、`Transfer`、`Sync`，辅助链上监控。

## 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech

欢迎克隆仓库，按照本文思路补全 Router 的流动性移除实现，并结合测试脚本验证安全性。
