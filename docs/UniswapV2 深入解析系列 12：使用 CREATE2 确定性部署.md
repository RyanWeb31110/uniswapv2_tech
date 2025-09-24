# UniswapV2 深入解析系列 12：使用 CREATE2 确定性部署

延续第 11 篇中对工厂合约架构的拆解，本篇聚焦 `createPair` 的内部工作流程，说明为何 UniswapV2 选择使用 CREATE2 来生成确定性的交易对地址，并给出可复现的测试方案，帮助你在本地快速验证实现细节。

## 1. 背景回顾：合约自部署的演化
### 1.1 CREATE 操作码的传统做法
早期以太坊仅提供 CREATE 操作码。部署者的合约在链上广播交易，其 nonce 与部署顺序耦合，导致新合约地址不可控：一旦部署者在此期间执行了其他交易或部署，nonce 就会变化，从而改变目标合约地址。

### 1.2 CREATE2 的确定性优势
**EIP-1014** 引入的 CREATE2 允许开发者通过「部署者地址 + salt + 合约字节码」三要素确定性地计算合约地址。这意味着：

- 在部署前即可离线推导目标地址；
- 合约可复用相同的字节码并以不同的 salt 生成不同的实例；
- 即便外部状态发生变化（例如部署者的 nonce 递增），目标地址依旧保持稳定。

这种可预测性非常适合流动性池这类需要在链下提前计算地址、并与外围合约互通的场景。

## 2. 工厂合约 `createPair` 流程拆解
### 2.1 核心代码片段
```solidity
bytes memory bytecode = type(UniswapV2Pair).creationCode;
bytes32 salt = keccak256(abi.encodePacked(token0, token1));
assembly {
    pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
}
```
- 读取 `UniswapV2Pair` 的创建字节码（包含构造逻辑与运行时主体）。
- 使用排序后的代币地址作为输入计算 salt，确保每个代币组合映射到唯一 salt。
- 通过内联汇编调用 CREATE2，传入部署所需的内存指针、长度和盐值，得到确定性地址。

### 2.2 完整步骤概览
1. **参数验证**：检查两种代币不同且未重复创建。
2. **字节码准备**：获取 `UniswapV2Pair` 创建字节码，确保部署新实例而非复用旧合约。
3. **生成盐值**：哈希标准排序后的代币地址，维持一对一映射关系。
4. **部署合约**：调用 CREATE2 返回新交易对地址，若部署失败会直接 revert。
5. **初始化状态**：调用新 pair 的 `initialize`，写入 `token0` 和 `token1`。
6. **记录与事件**：更新映射、数组，并触发 `PairCreated` 事件，供前端或监听服务追踪。

## 3. CREATE2 地址推导与参数说明
CREATE2 的地址计算公式为：
```
address = keccak256(0xff ++ deployer ++ salt ++ keccak256(bytecode))[12:]
```
其中：
- `0xff` 是常量前缀，用于区分其他哈希拼接；
- `deployer` 是工厂合约地址；
- `salt` 等于 `keccak256(token0, token1)`；
- `bytecode` 是 `type(UniswapV2Pair).creationCode`。

在内联汇编的 `create2(value, offset, size, salt)` 调用中：
- `value` 固定为 0，表示部署时不转入原生 ETH；
- `offset` 是字节码存放的内存起始地址，这里通过 `add(bytecode, 32)` 跳过数组长度字段；
- `size` 通过 `mload(bytecode)` 读取字节码长度；
- `salt` 为前述哈希结果。
四个参数共同保证每一对 token 映射到唯一且可验证的交易对地址。

## 4. 交易对初始化与状态同步
部署完成后立即调用 `initialize`：
```solidity
function initialize(address token0_, address token1_) public {
    if (token0 != address(0) || token1 != address(0)) {
        revert AlreadyInitialized();
    }
    token0 = token0_;
    token1 = token1_;
}
```
- 首次调用以外的任何触发都会因自定义错误 `AlreadyInitialized` 立即中断；

  工厂在 CREATE2 部署交易对后会第一时间调用 `initialize` 将 `token0` 与 `token1` 写入到唯一实例，若缺少这一保护，重复调用可能覆盖代币映射或被恶意利用导致状态污染，使得原本可预测的 CREATE2 地址与资金流向全部错位，因此**必须保证初始化只发生一次；**

- 初始化只负责写入代币地址，其余存储（储备量、k 值等）延后由交换或流动性操作驱动。

## 5. 架构设计考量与最佳实践
- **离线推导地址**：外围路由、前端和预言机可提前复用 CREATE2 公式推导交易对地址，避免链上查表。
- **状态唯一性**：通过 salt 设计确保 `(token0, token1)` 与 `(token1, token0)` 指向相同实例，避免流动性分散。
- **权限最小化**：工厂只负责创建，不保留额外管理开关，符合无管理员原则。
- **失败回滚**：`create2` 调用若因字节码或 gas 不足失败，会返回零地址并触发 revert，确保不会出现半初始化合约。
- **重放安全**：salt 只依赖代币地址，不涉及外部可变状态，避免重放攻击。

## 6. 测试验证：Foundry 实战示例
以下 Foundry 测试用例演示如何验证 CREATE2 地址与事件：
```solidity
// test/core/UniswapV2FactoryCreate2.t.sol
// forge test --match-test testCreatePairWithCreate2 -vv
import "forge-std/Test.sol";
import {UniswapV2Factory} from "src/core/UniswapV2Factory.sol";

contract UniswapV2FactoryCreate2Test is Test {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 index);

    UniswapV2Factory factory;
    address tokenA = address(0x1001);
    address tokenB = address(0x2002);

    function setUp() public {
        factory = new UniswapV2Factory(address(this));
    }

    function testCreatePairWithCreate2() public {
        address token0 = tokenA < tokenB ? tokenA : tokenB;
        address token1 = tokenA < tokenB ? tokenB : tokenA;
        address expected = factory.computePairAddress(token0, token1);

        vm.expectEmit(true, true, false, true, address(factory));
        emit PairCreated(token0, token1, expected, 1);

        address actual = factory.createPair(tokenA, tokenB);

        assertEq(actual, expected, "CREATE2 地址计算不一致");
        assertEq(factory.getPair(tokenA, tokenB), expected, "映射未登记交易对");
        assertEq(factory.getPair(tokenB, tokenA), expected, "反向查询失败");
    }
}
```
执行步骤：
1. 运行 `forge test --match-test testCreatePairWithCreate2 -vv` 验证地址推导正确；
2. 若新增交易对合约逻辑，补充更多断言覆盖构造失败、重复部署等分支；
3. 修改 gas 行为后同步更新 `forge snapshot`，保持基准一致。

## 7. 注意事项与常见陷阱
- **创建字节码必须与工厂一致，一旦升级合约需同步更新并重新计算地址。**
- 避免通过外部输入直接构造盐值，以防用户伪造导致地址冲突。
- 在脚本部署或前端查询时，务必统一排序规则（通常按代币地址字典序从小到大）以匹配工厂逻辑。
- 监听 `PairCreated` 事件时，同时校验 `getPair` 映射，确保索引与事件保持一致。

## 项目仓库
https://github.com/RyanWeb31110/uniswapv2_tech
