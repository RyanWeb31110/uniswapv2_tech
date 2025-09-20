// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../oracle/UniswapV2Oracle.sol";
import "../core/UniswapV2Pair.sol";
import "../libraries/UQ112x112.sol";
import "../security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title 套利机器人
 * @notice 利用 TWAP 预言机识别套利机会并执行套利交易
 * @dev 展示如何在实际应用中使用价格预言机
 */
contract ArbitrageBot is Ownable, ReentrancyGuard {
    using UQ112x112 for uint224;

    // ============ 结构体定义 ============

    /// @notice 套利机会数据
    struct ArbitrageOpportunity {
        address pairA;        // 第一个交易对
        address pairB;        // 第二个交易对
        address token;        // 套利代币
        uint256 profitAmount; // 预期利润
        bool direction;       // 套利方向（true: A买B卖, false: B买A卖）
    }

    /// @notice 交易对信息
    struct PairInfo {
        address token0;
        address token1;
        uint112 reserve0;
        uint112 reserve1;
        uint256 price0;  // token0 相对 token1 的价格
        uint256 price1;  // token1 相对 token0 的价格
    }

    // ============ 状态变量 ============

    /// @notice 价格预言机实例
    UniswapV2Oracle public immutable oracle;

    /// @notice WETH 地址
    address public immutable WETH;

    /// @notice 套利阈值 (basis points，50 = 0.5%)
    uint256 public arbitrageThreshold = 50;

    /// @notice 最大滑点 (basis points，100 = 1%)
    uint256 public maxSlippage = 100;

    /// @notice 最小利润阈值（以 ETH 计价）
    uint256 public minProfitThreshold = 0.01 ether;

    /// @notice 注册的交易对列表
    address[] public registeredPairs;

    /// @notice 交易对注册状态
    mapping(address => bool) public isPairRegistered;

    /// @notice 支持的代币列表
    mapping(address => bool) public supportedTokens;

    /// @notice 机器人运行状态
    bool public isActive = true;

    // ============ 事件定义 ============

    event ArbitrageExecuted(
        address indexed token,
        address pairA,
        address pairB,
        uint256 amountIn,
        uint256 profit
    );

    event OpportunityDetected(
        address indexed token,
        address pairA,
        address pairB,
        uint256 expectedProfit
    );

    event PairRegistered(address indexed pair, address token0, address token1);
    event TokenSupported(address indexed token);
    event ParametersUpdated(uint256 threshold, uint256 slippage, uint256 minProfit);

    // ============ 自定义错误 ============

    error InsufficientProfit();
    error ArbitrageNotProfitable();
    error BotInactive();
    error PairAlreadyRegistered();
    error TokenNotSupported();
    error InvalidParameters();
    error ArbitrageExecutionFailed();

    // ============ 构造函数 ============

    constructor(address _oracle, address _weth) Ownable(msg.sender) {
        oracle = UniswapV2Oracle(_oracle);
        WETH = _weth;
    }

    // ============ 管理函数 ============

    /**
     * @notice 设置机器人运行状态
     * @param _active 是否激活
     */
    function setActive(bool _active) external onlyOwner {
        isActive = _active;
    }

    /**
     * @notice 注册交易对
     * @param pair 交易对地址
     */
    function registerPair(address pair) external onlyOwner {
        if (isPairRegistered[pair]) revert PairAlreadyRegistered();

        UniswapV2Pair pairContract = UniswapV2Pair(pair);
        address token0 = pairContract.token0();
        address token1 = pairContract.token1();

        registeredPairs.push(pair);
        isPairRegistered[pair] = true;

        emit PairRegistered(pair, token0, token1);
    }

    /**
     * @notice 添加支持的代币
     * @param token 代币地址
     */
    function addSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = true;
        emit TokenSupported(token);
    }

    /**
     * @notice 更新套利参数
     * @param _threshold 套利阈值
     * @param _slippage 最大滑点
     * @param _minProfit 最小利润阈值
     */
    function updateParameters(
        uint256 _threshold,
        uint256 _slippage,
        uint256 _minProfit
    ) external onlyOwner {
        if (_threshold > 1000 || _slippage > 500) revert InvalidParameters();

        arbitrageThreshold = _threshold;
        maxSlippage = _slippage;
        minProfitThreshold = _minProfit;

        emit ParametersUpdated(_threshold, _slippage, _minProfit);
    }

    // ============ 套利检测功能 ============

    /**
     * @notice 检查特定代币对之间的套利机会
     * @param pairA 第一个交易对
     * @param pairB 第二个交易对
     * @param token 套利代币
     * @return hasOpportunity 是否存在套利机会
     * @return opportunity 套利机会详情
     */
    function checkArbitrageOpportunity(address pairA, address pairB, address token)
        external
        view
        returns (bool hasOpportunity, ArbitrageOpportunity memory opportunity)
    {
        if (!supportedTokens[token]) return (false, opportunity);

        // 获取两个交易对的价格信息
        PairInfo memory infoA = getPairInfo(pairA);
        PairInfo memory infoB = getPairInfo(pairB);

        // 确定代币在每个交易对中的价格
        uint256 priceA = getTokenPriceInPair(pairA, token);
        uint256 priceB = getTokenPriceInPair(pairB, token);

        if (priceA == 0 || priceB == 0) return (false, opportunity);

        // 计算价格差异
        uint256 priceDiff = priceA > priceB ? priceA - priceB : priceB - priceA;
        uint256 priceAvg = (priceA + priceB) / 2;
        uint256 diffRatio = (priceDiff * 10000) / priceAvg;

        // 检查是否超过阈值
        if (diffRatio <= arbitrageThreshold) return (false, opportunity);

        // 计算预期利润
        uint256 profitAmount = estimateProfit(pairA, pairB, token, priceA > priceB);

        if (profitAmount < minProfitThreshold) return (false, opportunity);

        opportunity = ArbitrageOpportunity({
            pairA: pairA,
            pairB: pairB,
            token: token,
            profitAmount: profitAmount,
            direction: priceA > priceB
        });

        hasOpportunity = true;
    }

    /**
     * @notice 扫描所有注册交易对寻找套利机会
     * @return opportunities 发现的套利机会数组
     */
    function scanArbitrageOpportunities()
        external
        view
        returns (ArbitrageOpportunity[] memory opportunities)
    {
        uint256 opportunityCount = 0;
        ArbitrageOpportunity[] memory tempOpportunities = new ArbitrageOpportunity[](100);

        // 遍历所有交易对组合
        for (uint i = 0; i < registeredPairs.length; i++) {
            for (uint j = i + 1; j < registeredPairs.length; j++) {
                address pairA = registeredPairs[i];
                address pairB = registeredPairs[j];

                // 检查是否有共同的代币
                address commonToken = getCommonToken(pairA, pairB);
                if (commonToken != address(0) && supportedTokens[commonToken]) {
                    (bool hasOpportunity, ArbitrageOpportunity memory opportunity) =
                        this.checkArbitrageOpportunity(pairA, pairB, commonToken);

                    if (hasOpportunity && opportunityCount < 100) {
                        tempOpportunities[opportunityCount] = opportunity;
                        opportunityCount++;
                    }
                }
            }
        }

        // 创建正确大小的数组
        opportunities = new ArbitrageOpportunity[](opportunityCount);
        for (uint i = 0; i < opportunityCount; i++) {
            opportunities[i] = tempOpportunities[i];
        }
    }

    // ============ 套利执行功能 ============

    /**
     * @notice 执行套利交易
     * @param opportunity 套利机会
     * @param maxAmountIn 最大输入金额
     */
    function executeArbitrage(
        ArbitrageOpportunity calldata opportunity,
        uint256 maxAmountIn
    ) external nonReentrant {
        if (!isActive) revert BotInactive();

        // 验证套利机会仍然存在
        (bool hasOpportunity,) = this.checkArbitrageOpportunity(
            opportunity.pairA,
            opportunity.pairB,
            opportunity.token
        );

        if (!hasOpportunity) revert ArbitrageNotProfitable();

        // 计算最优交易金额
        uint256 optimalAmount = calculateOptimalAmount(opportunity, maxAmountIn);

        if (optimalAmount == 0) revert InsufficientProfit();

        // 执行套利交易
        uint256 initialBalance = getTokenBalance(opportunity.token, address(this));

        try this._executeArbitrageInternal(opportunity, optimalAmount) {
            uint256 finalBalance = getTokenBalance(opportunity.token, address(this));
            uint256 profit = finalBalance > initialBalance ? finalBalance - initialBalance : 0;

            if (profit < minProfitThreshold) revert InsufficientProfit();

            emit ArbitrageExecuted(
                opportunity.token,
                opportunity.pairA,
                opportunity.pairB,
                optimalAmount,
                profit
            );
        } catch {
            revert ArbitrageExecutionFailed();
        }
    }

    /**
     * @notice 内部套利执行函数
     * @param opportunity 套利机会
     * @param amountIn 输入金额
     */
    function _executeArbitrageInternal(
        ArbitrageOpportunity calldata opportunity,
        uint256 amountIn
    ) external {
        require(msg.sender == address(this), "Only self");

        if (opportunity.direction) {
            // 在 pairA 买入，在 pairB 卖出
            uint256 amountOut = _swap(opportunity.pairA, opportunity.token, amountIn, true);
            _swap(opportunity.pairB, opportunity.token, amountOut, false);
        } else {
            // 在 pairB 买入，在 pairA 卖出
            uint256 amountOut = _swap(opportunity.pairB, opportunity.token, amountIn, true);
            _swap(opportunity.pairA, opportunity.token, amountOut, false);
        }
    }

    // ============ 内部辅助函数 ============

    /**
     * @notice 获取交易对信息
     * @param pair 交易对地址
     * @return info 交易对信息
     */
    function getPairInfo(address pair) internal view returns (PairInfo memory info) {
        UniswapV2Pair pairContract = UniswapV2Pair(pair);

        info.token0 = pairContract.token0();
        info.token1 = pairContract.token1();
        (info.reserve0, info.reserve1,) = pairContract.getReserves();

        // 尝试获取 TWAP 价格
        try oracle.consult(pair) returns (uint256 price0, uint256 price1) {
            info.price0 = price0;
            info.price1 = price1;
        } catch {
            // 使用即时价格作为后备
            if (info.reserve0 > 0 && info.reserve1 > 0) {
                info.price0 = (uint256(info.reserve1) * (2**112)) / info.reserve0;
                info.price1 = (uint256(info.reserve0) * (2**112)) / info.reserve1;
            }
        }
    }

    /**
     * @notice 获取代币在交易对中的价格
     * @param pair 交易对地址
     * @param token 代币地址
     * @return price 价格（UQ112x112 格式）
     */
    function getTokenPriceInPair(address pair, address token) internal view returns (uint256 price) {
        UniswapV2Pair pairContract = UniswapV2Pair(pair);
        address token0 = pairContract.token0();
        address token1 = pairContract.token1();

        if (token != token0 && token != token1) return 0;

        PairInfo memory info = getPairInfo(pair);

        if (token == token0) {
            price = info.price0;
        } else {
            price = info.price1;
        }
    }

    /**
     * @notice 找到两个交易对的共同代币
     * @param pairA 第一个交易对
     * @param pairB 第二个交易对
     * @return commonToken 共同代币地址，没有则返回零地址
     */
    function getCommonToken(address pairA, address pairB) internal view returns (address commonToken) {
        UniswapV2Pair pairContractA = UniswapV2Pair(pairA);
        UniswapV2Pair pairContractB = UniswapV2Pair(pairB);

        address token0A = pairContractA.token0();
        address token1A = pairContractA.token1();
        address token0B = pairContractB.token0();
        address token1B = pairContractB.token1();

        if (token0A == token0B || token0A == token1B) {
            return token0A;
        }
        if (token1A == token0B || token1A == token1B) {
            return token1A;
        }

        return address(0);
    }

    /**
     * @notice 估算套利利润
     * @param pairA 第一个交易对
     * @param pairB 第二个交易对
     * @param token 套利代币
     * @param direction 套利方向
     * @return profit 预期利润
     */
    function estimateProfit(
        address pairA,
        address pairB,
        address token,
        bool direction
    ) internal view returns (uint256 profit) {
        // 简化的利润估算，实际实现需要考虑滑点、手续费等因素
        uint256 testAmount = 1 ether;

        if (direction) {
            // A买B卖的路径
            uint256 amountOut1 = getAmountOut(testAmount, pairA, token, true);
            uint256 amountOut2 = getAmountOut(amountOut1, pairB, token, false);
            if (amountOut2 > testAmount) {
                profit = amountOut2 - testAmount;
            }
        } else {
            // B买A卖的路径
            uint256 amountOut1 = getAmountOut(testAmount, pairB, token, true);
            uint256 amountOut2 = getAmountOut(amountOut1, pairA, token, false);
            if (amountOut2 > testAmount) {
                profit = amountOut2 - testAmount;
            }
        }
    }

    /**
     * @notice 计算最优套利金额
     * @param opportunity 套利机会
     * @param maxAmount 最大金额
     * @return optimal 最优金额
     */
    function calculateOptimalAmount(
        ArbitrageOpportunity calldata opportunity,
        uint256 maxAmount
    ) internal view returns (uint256 optimal) {
        // 简化实现：使用二分搜索找到最优金额
        uint256 low = minProfitThreshold;
        uint256 high = maxAmount;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            uint256 profit = estimateProfit(
                opportunity.pairA,
                opportunity.pairB,
                opportunity.token,
                opportunity.direction
            );

            if (profit > estimateProfit(
                opportunity.pairA,
                opportunity.pairB,
                opportunity.token,
                opportunity.direction
            )) {
                optimal = mid;
                low = mid + 1;
            } else {
                high = mid;
            }
        }
    }

    /**
     * @notice 执行交换
     * @param pair 交易对地址
     * @param token 代币地址
     * @param amount 交换数量
     * @param isBuy 是否为买入
     * @return amountOut 输出数量
     */
    function _swap(
        address pair,
        address token,
        uint256 amount,
        bool isBuy
    ) internal returns (uint256 amountOut) {
        UniswapV2Pair pairContract = UniswapV2Pair(pair);

        if (isBuy) {
            // 买入代币
            transferToken(token, pair, amount);
            amountOut = getAmountOut(amount, pair, token, true);

            if (token == pairContract.token0()) {
                pairContract.swap(amountOut, 0, address(this), "");
            } else {
                pairContract.swap(0, amountOut, address(this), "");
            }
        } else {
            // 卖出代币
            transferToken(token, pair, amount);
            amountOut = getAmountOut(amount, pair, token, false);

            if (token == pairContract.token0()) {
                pairContract.swap(0, amountOut, address(this), "");
            } else {
                pairContract.swap(amountOut, 0, address(this), "");
            }
        }
    }

    /**
     * @notice 计算输出数量
     * @param amountIn 输入数量
     * @param pair 交易对地址
     * @param token 代币地址
     * @param isBuy 是否为买入
     * @return amountOut 输出数量
     */
    function getAmountOut(
        uint256 amountIn,
        address pair,
        address token,
        bool isBuy
    ) internal view returns (uint256 amountOut) {
        UniswapV2Pair pairContract = UniswapV2Pair(pair);
        (uint112 reserve0, uint112 reserve1,) = pairContract.getReserves();

        if (isBuy) {
            if (token == pairContract.token0()) {
                amountOut = getAmountOutFormula(amountIn, reserve1, reserve0);
            } else {
                amountOut = getAmountOutFormula(amountIn, reserve0, reserve1);
            }
        } else {
            if (token == pairContract.token0()) {
                amountOut = getAmountOutFormula(amountIn, reserve0, reserve1);
            } else {
                amountOut = getAmountOutFormula(amountIn, reserve1, reserve0);
            }
        }
    }

    /**
     * @notice Uniswap 输出计算公式
     * @param amountIn 输入数量
     * @param reserveIn 输入储备
     * @param reserveOut 输出储备
     * @return amountOut 输出数量
     */
    function getAmountOutFormula(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // ============ 查询函数 ============

    /**
     * @notice 获取注册的交易对数量
     * @return 交易对数量
     */
    function getRegisteredPairsCount() external view returns (uint256) {
        return registeredPairs.length;
    }

    /**
     * @notice 获取所有注册的交易对
     * @return 交易对地址数组
     */
    function getAllRegisteredPairs() external view returns (address[] memory) {
        return registeredPairs;
    }

    // ============ 紧急功能 ============

    /**
     * @notice 紧急提取代币
     * @param token 代币地址
     * @param amount 提取数量
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        transferToken(token, owner(), amount);
    }

    /**
     * @notice 紧急提取 ETH
     * @param amount 提取数量
     */
    function emergencyWithdrawETH(uint256 amount) external onlyOwner {
        payable(owner()).transfer(amount);
    }

    // ============ 代币操作辅助函数 ============

    /**
     * @notice 获取代币余额
     * @param token 代币地址
     * @param account 账户地址
     * @return 余额
     */
    function getTokenBalance(address token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        require(success && data.length >= 32, "Balance query failed");
        return abi.decode(data, (uint256));
    }

    /**
     * @notice 转账代币
     * @param token 代币地址
     * @param to 接收地址
     * @param amount 转账数量
     */
    function transferToken(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    /**
     * @notice 接收 ETH
     */
    receive() external payable {}
}