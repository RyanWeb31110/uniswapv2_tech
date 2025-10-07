本篇为《UniswapV2 深入解析》系列第 22 篇，延续上一章对闪电贷流程与手续费模型的讨论，聚焦于 **闪电贷引入的重入风险** 及其治理方案。阅读本文前，建议先回顾第 20 与 21 篇对手续费修复与闪电贷机制的梳理，以便理解本文中合约架构的演进脉络。

## 问题背景：闪电贷带来的新攻击面
1. 在优化 `swap` 与闪电贷逻辑时，Pair 合约会在更新储备前提前转账，以支持“乐观转移”。
2. 外部转账意味着我们在 Effects 阶段之前就触达外部合约或恶意地址，经典的 Checks-Effects-Interactions（CEI）模式难以直接应用。
3. 一旦攻击者通过回调再次触发 `swap`，即可重复提取代币，造成严重资金损失。

## 原始方案的局限：CEI 为何失效
- **执行顺序冲突**：CEI 要求“先校验、再更新状态、最后外部调用”，但闪电贷依赖“先转账、后结算”。
- **回调必须保留**：闪电贷通过 `data` 参数触发借方回调，完全禁止外部调用会破坏核心功能。
- **储备同步延后**：在更新储备前缺乏状态锁，容易被重入多次读取旧储备。

## Guard Check 模式：状态锁的设计
我们采用 Guard Check（进入/退出标志）来提供最小侵入的防护：

```solidity
/// @notice UniswapV2 交易对核心合约
contract UniswapV2Pair is IUniswapV2Pair {
    /// @dev 标记当前是否处于 swap 执行过程中
    bool private entered;

    /// @notice 发起兑换或闪电贷
    /// @param amount0Out 以 token0 计的输出数量
    /// @param amount1Out 以 token1 计的输出数量
    /// @param to 接收资产的目标地址
    /// @param data 额外的回调参数，非空则触发 `IUniswapV2Callee`
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external nonReentrant {
        _swap(amount0Out, amount1Out, to, data);
    }

    /// @dev 防止在同一事务内重复进入 swap
    modifier nonReentrant() {
        if (entered) revert ReentrancyGuard();
        entered = true;
        _;
        entered = false;
    }
}
```

### 关键要点
1. **状态存储**：`entered` 放在合约存储中，虽略增 Gas，但换来可读性与安全性。
2. **自定义错误**：复用合约现有风格，采用 `ReentrancyGuard()` 自定义错误代替字符串信息。
3. **模块化实现**：`swap` 内部委托 `_swap`，将安全防护与业务逻辑解耦，便于后续扩展手续费或奖励机制。

## 架构设计思考
- **安全层独立**：Guard Check 作为独立的横切关注点，可以在 Router、Oracle 等模块中复用统一的修饰符，实现一致的调用规范。
- **状态机清晰**：通过布尔型状态机显式表示“是否在执行”，避免晦涩的内联判断，提高阅读体验。
- **与库配合**：核心业务仍由 `UniswapV2Library` 完成，保持架构职责单一，避免重新实现比例计算等逻辑。

## Foundry 测试：验证重入防护
使用项目提供的 `./scripts/test.sh` 执行测试，日志会写入 `logs/` 目录。以下为示例测试合约片段：

```solidity
/// @title 测试重入攻击是否被阻止
contract UniswapV2PairReentrancyTest is Test {
    UniswapV2Pair pair;
    MaliciousCallee attacker;

    function setUp() public {
        // 1. 部署 Pair 与测试代币
        // 2. 初始化储备，确保存在可借出的流动性
        // 3. 部署伪造回调合约 `MaliciousCallee`
    }

    function testCannotReenterSwap() public {
        vm.expectRevert(ReentrancyGuard.selector);
        attacker.executeFlashLoan(address(pair));
    }
}
```

测试步骤建议：
1. **准备流动性**：调用 Router 添加初始储备，确保闪电贷可借出。
2. **构造恶意回调**：在 `executeFlashLoan` 中触发 `pair.swap`，再尝试递归调用自身。
3. **断言回滚**：利用 `vm.expectRevert` 捕获 `ReentrancyGuard` 错误，确认防护生效。

## 注意事项与最佳实践
- **保持修饰符幂等**：任何在 `swap` 过程中可能触发的内部函数都不应再次修改 `entered`，以免状态错乱。
- **严控外部调用**：即使有 Guard Check，也应避免在回调中执行高权限操作，配合白名单或速率限制强化安全。
- **持续监控 Gas**：记录部署与调用 Gas，避免因防护开销影响关键路径的用户体验。

## 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech
