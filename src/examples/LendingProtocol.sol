// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../oracle/UniswapV2Oracle.sol";
import "../libraries/UQ112x112.sol";
import "../security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title 借贷协议价格模块
 * @notice 展示如何将 UniswapV2 预言机集成到 DeFi 协议中
 * @dev 简化的借贷协议实现，演示价格预言机的使用
 */
contract LendingProtocol is Ownable, ReentrancyGuard {
    using UQ112x112 for uint224;

    // ============ 结构体定义 ============

    /// @notice 抵押品配置
    struct CollateralConfig {
        bool isSupported;          // 是否支持作为抵押品
        uint256 collateralFactor;  // 抵押率（basis points，10000 = 100%）
        address pairAddress;       // 对应的交易对地址
        uint256 liquidationThreshold; // 清算阈值（basis points）
    }

    /// @notice 用户借贷数据
    struct UserLoan {
        uint256 collateralAmount;  // 抵押品数量
        address collateralToken;   // 抵押品代币
        uint256 borrowAmount;      // 借款数量（以 ETH 计价）
        uint256 lastUpdateTime;    // 最后更新时间
    }

    // ============ 状态变量 ============

    /// @notice 价格预言机实例
    UniswapV2Oracle public immutable priceOracle;

    /// @notice WETH 地址（用作基准货币）
    address public immutable WETH;

    /// @notice 抵押品配置映射
    mapping(address => CollateralConfig) public collateralConfigs;

    /// @notice 用户借贷数据映射
    mapping(address => UserLoan) public userLoans;

    /// @notice 协议总借款量
    uint256 public totalBorrowed;

    /// @notice 协议储备金
    uint256 public protocolReserves;

    /// @notice 年化利率（basis points）
    uint256 public constant ANNUAL_INTEREST_RATE = 500; // 5%

    /// @notice 清算奖励（basis points）
    uint256 public constant LIQUIDATION_BONUS = 500; // 5%

    // ============ 事件定义 ============

    event CollateralAdded(address indexed user, address token, uint256 amount);
    event LoanBorrowed(address indexed user, uint256 amount);
    event LoanRepaid(address indexed user, uint256 amount);
    event Liquidation(address indexed liquidator, address indexed borrower, uint256 repayAmount, uint256 collateralAmount);
    event CollateralConfigUpdated(address indexed token, uint256 collateralFactor, uint256 liquidationThreshold);

    // ============ 自定义错误 ============

    error UnsupportedCollateral();
    error InsufficientCollateral();
    error ExceedsCollateralValue();
    error NoActiveLoan();
    error HealthyLoan();
    error InsufficientLiquidity();
    error InvalidCollateralFactor();
    error PriceDataStale();

    // ============ 构造函数 ============

    constructor(address _priceOracle, address _weth) Ownable(msg.sender) {
        priceOracle = UniswapV2Oracle(_priceOracle);
        WETH = _weth;
    }

    // ============ 管理函数 ============

    /**
     * @notice 配置抵押品参数
     * @param token 抵押品代币地址
     * @param collateralFactor 抵押率（basis points）
     * @param liquidationThreshold 清算阈值（basis points）
     * @param pairAddress 对应的交易对地址
     */
    function setCollateralConfig(
        address token,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        address pairAddress
    ) external onlyOwner {
        if (collateralFactor > 9000 || liquidationThreshold > 9500) {
            revert InvalidCollateralFactor();
        }

        collateralConfigs[token] = CollateralConfig({
            isSupported: true,
            collateralFactor: collateralFactor,
            pairAddress: pairAddress,
            liquidationThreshold: liquidationThreshold
        });

        emit CollateralConfigUpdated(token, collateralFactor, liquidationThreshold);
    }

    /**
     * @notice 向协议存入储备金
     */
    function depositReserves() external payable onlyOwner {
        protocolReserves += msg.value;
    }

    /**
     * @notice 提取协议储备金
     * @param amount 提取数量
     */
    function withdrawReserves(uint256 amount) external onlyOwner {
        require(amount <= protocolReserves, "Insufficient reserves");
        protocolReserves -= amount;
        payable(owner()).transfer(amount);
    }

    // ============ 用户借贷功能 ============

    /**
     * @notice 添加抵押品
     * @param token 抵押品代币地址
     * @param amount 抵押品数量
     */
    function addCollateral(address token, uint256 amount) external nonReentrant {
        CollateralConfig memory config = collateralConfigs[token];
        if (!config.isSupported) revert UnsupportedCollateral();

        // 转账抵押品到合约
        transferFromToken(token, msg.sender, address(this), amount);

        // 更新用户数据
        UserLoan storage userLoan = userLoans[msg.sender];
        if (userLoan.collateralToken == address(0)) {
            userLoan.collateralToken = token;
        } else {
            require(userLoan.collateralToken == token, "Can only use one collateral type");
        }

        userLoan.collateralAmount += amount;
        userLoan.lastUpdateTime = block.timestamp;

        emit CollateralAdded(msg.sender, token, amount);
    }

    /**
     * @notice 借款
     * @param amount 借款数量（以 ETH 计价）
     */
    function borrow(uint256 amount) external nonReentrant {
        UserLoan storage userLoan = userLoans[msg.sender];
        if (userLoan.collateralToken == address(0)) revert InsufficientCollateral();

        // 计算可借款金额
        uint256 maxBorrowAmount = getMaxBorrowAmount(msg.sender);
        if (amount > maxBorrowAmount) revert ExceedsCollateralValue();

        // 检查协议流动性
        if (amount > protocolReserves) revert InsufficientLiquidity();

        // 计算并添加利息
        _accrueInterest(msg.sender);

        // 更新借款数据
        userLoan.borrowAmount += amount;
        totalBorrowed += amount;
        protocolReserves -= amount;

        // 转账给用户
        payable(msg.sender).transfer(amount);

        emit LoanBorrowed(msg.sender, amount);
    }

    /**
     * @notice 还款
     */
    function repay() external payable nonReentrant {
        UserLoan storage userLoan = userLoans[msg.sender];
        if (userLoan.borrowAmount == 0) revert NoActiveLoan();

        // 计算利息
        _accrueInterest(msg.sender);

        uint256 repayAmount = msg.value;
        uint256 currentDebt = userLoan.borrowAmount;

        if (repayAmount >= currentDebt) {
            // 全额还款
            userLoan.borrowAmount = 0;
            totalBorrowed -= currentDebt;
            protocolReserves += currentDebt;

            // 退还多余资金
            if (repayAmount > currentDebt) {
                payable(msg.sender).transfer(repayAmount - currentDebt);
            }

            emit LoanRepaid(msg.sender, currentDebt);
        } else {
            // 部分还款
            userLoan.borrowAmount -= repayAmount;
            totalBorrowed -= repayAmount;
            protocolReserves += repayAmount;

            emit LoanRepaid(msg.sender, repayAmount);
        }
    }

    /**
     * @notice 提取抵押品
     * @param amount 提取数量
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        UserLoan storage userLoan = userLoans[msg.sender];
        require(userLoan.collateralAmount >= amount, "Insufficient collateral");

        // 计算利息
        _accrueInterest(msg.sender);

        // 检查提取后是否还能维持健康的抵押率
        userLoan.collateralAmount -= amount;
        uint256 maxBorrowAmount = getMaxBorrowAmount(msg.sender);

        if (userLoan.borrowAmount > maxBorrowAmount) {
            userLoan.collateralAmount += amount; // 回滚
            revert InsufficientCollateral();
        }

        // 转账抵押品给用户
        transferToken(userLoan.collateralToken, msg.sender, amount);
    }

    // ============ 清算功能 ============

    /**
     * @notice 清算不健康的贷款
     * @param borrower 借款人地址
     */
    function liquidate(address borrower) external payable nonReentrant {
        UserLoan storage userLoan = userLoans[borrower];
        if (userLoan.borrowAmount == 0) revert NoActiveLoan();

        // 计算利息
        _accrueInterest(borrower);

        // 检查是否需要清算
        if (!shouldLiquidate(borrower)) revert HealthyLoan();

        uint256 repayAmount = msg.value;
        uint256 currentDebt = userLoan.borrowAmount;

        // 计算可获得的抵押品数量
        uint256 collateralValue = getCollateralValue(borrower);
        uint256 maxRepayAmount = currentDebt;

        if (repayAmount > maxRepayAmount) {
            repayAmount = maxRepayAmount;
            // 退还多余资金
            payable(msg.sender).transfer(msg.value - repayAmount);
        }

        // 计算清算奖励
        uint256 collateralToLiquidator = (repayAmount * (10000 + LIQUIDATION_BONUS)) / 10000;
        collateralToLiquidator = (collateralToLiquidator * (2**112)) / getTokenPrice(userLoan.collateralToken);
        collateralToLiquidator = collateralToLiquidator / (2**112);

        if (collateralToLiquidator > userLoan.collateralAmount) {
            collateralToLiquidator = userLoan.collateralAmount;
        }

        // 更新借款人数据
        userLoan.borrowAmount -= repayAmount;
        userLoan.collateralAmount -= collateralToLiquidator;
        totalBorrowed -= repayAmount;
        protocolReserves += repayAmount;

        // 转账抵押品给清算人
        transferToken(userLoan.collateralToken, msg.sender, collateralToLiquidator);

        emit Liquidation(msg.sender, borrower, repayAmount, collateralToLiquidator);
    }

    // ============ 查询函数 ============

    /**
     * @notice 计算抵押品价值
     * @param user 用户地址
     * @return value 以 ETH 计价的抵押品价值
     */
    function getCollateralValue(address user) public view returns (uint256 value) {
        UserLoan memory userLoan = userLoans[user];
        if (userLoan.collateralToken == address(0)) return 0;

        uint256 tokenPrice = getTokenPrice(userLoan.collateralToken);
        value = (userLoan.collateralAmount * tokenPrice) / (2**112);
    }

    /**
     * @notice 获取最大可借款金额
     * @param user 用户地址
     * @return 最大可借款金额
     */
    function getMaxBorrowAmount(address user) public view returns (uint256) {
        UserLoan memory userLoan = userLoans[user];
        if (userLoan.collateralToken == address(0)) return 0;

        CollateralConfig memory config = collateralConfigs[userLoan.collateralToken];
        uint256 collateralValue = getCollateralValue(user);

        return (collateralValue * config.collateralFactor) / 10000;
    }

    /**
     * @notice 检查是否需要清算
     * @param borrower 借款人地址
     * @return 是否需要清算
     */
    function shouldLiquidate(address borrower) public view returns (bool) {
        UserLoan memory userLoan = userLoans[borrower];
        if (userLoan.borrowAmount == 0) return false;

        CollateralConfig memory config = collateralConfigs[userLoan.collateralToken];
        uint256 collateralValue = getCollateralValue(borrower);
        uint256 maxBorrowAmount = (collateralValue * config.liquidationThreshold) / 10000;

        return userLoan.borrowAmount > maxBorrowAmount;
    }

    /**
     * @notice 获取代币相对 ETH 的价格
     * @param token 代币地址
     * @return price UQ112x112 格式的价格
     */
    function getTokenPrice(address token) public view returns (uint256 price) {
        CollateralConfig memory config = collateralConfigs[token];
        require(config.isSupported, "Unsupported token");

        // 检查预言机数据是否太旧
        uint32 lastUpdate = priceOracle.getObservationTimestamp(config.pairAddress);
        if (block.timestamp - lastUpdate > 7200) revert PriceDataStale(); // 2小时

        try priceOracle.consult(config.pairAddress) returns (uint256 price0, uint256 price1) {
            // 假设 token0 是查询的代币，token1 是 WETH
            // 实际实现中需要检查代币顺序
            return price0;
        } catch {
            revert PriceDataStale();
        }
    }

    /**
     * @notice 计算用户当前债务（包含利息）
     * @param user 用户地址
     * @return 当前债务
     */
    function getCurrentDebt(address user) external view returns (uint256) {
        UserLoan memory userLoan = userLoans[user];
        if (userLoan.borrowAmount == 0) return 0;

        // 计算利息
        uint256 timeElapsed = block.timestamp - userLoan.lastUpdateTime;
        uint256 interest = (userLoan.borrowAmount * ANNUAL_INTEREST_RATE * timeElapsed) / (365 days * 10000);

        return userLoan.borrowAmount + interest;
    }

    /**
     * @notice 获取用户健康因子
     * @param user 用户地址
     * @return healthFactor 健康因子（1e18 = 100%）
     */
    function getHealthFactor(address user) external view returns (uint256 healthFactor) {
        UserLoan memory userLoan = userLoans[user];
        if (userLoan.borrowAmount == 0) return type(uint256).max;

        CollateralConfig memory config = collateralConfigs[userLoan.collateralToken];
        uint256 collateralValue = getCollateralValue(user);
        uint256 liquidationValue = (collateralValue * config.liquidationThreshold) / 10000;

        return (liquidationValue * 1e18) / userLoan.borrowAmount;
    }

    // ============ 内部函数 ============

    /**
     * @notice 累积利息
     * @param user 用户地址
     */
    function _accrueInterest(address user) internal {
        UserLoan storage userLoan = userLoans[user];
        if (userLoan.borrowAmount == 0) return;

        uint256 timeElapsed = block.timestamp - userLoan.lastUpdateTime;
        if (timeElapsed == 0) return;

        uint256 interest = (userLoan.borrowAmount * ANNUAL_INTEREST_RATE * timeElapsed) / (365 days * 10000);
        userLoan.borrowAmount += interest;
        userLoan.lastUpdateTime = block.timestamp;
        totalBorrowed += interest;
    }

    // ============ 紧急功能 ============

    /**
     * @notice 紧急暂停（仅限所有者）
     */
    function emergencyPause() external onlyOwner {
        // 实现紧急暂停逻辑
    }

    // ============ 代币操作辅助函数 ============

    /**
     * @notice 转账代币（来自用户）
     * @param token 代币地址
     * @param from 发送地址
     * @param to 接收地址
     * @param amount 转账数量
     */
    function transferFromToken(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
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
    receive() external payable {
        protocolReserves += msg.value;
    }
}