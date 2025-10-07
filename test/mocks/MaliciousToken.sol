// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../../src/core/UniswapV2Pair.sol";
import "forge-std/console.sol";

/**
 * @title 恶意代币合约
 * @notice 模拟攻击者控制的恶意代币合约，用于测试重入攻击
 * @dev 在转账时尝试重入交易对合约的函数
 */
contract MaliciousToken {
    string public name = "Malicious Token";
    string public symbol = "MAL";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1000000 ether;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public pair;
    bool public attackEnabled = false;
    uint256 public attackCount = 0;
    uint256 public maxAttacks = 3;
    bool public isToken0;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }

    /**
     * @notice 设置要攻击的交易对地址
     * @param _pair 交易对合约地址
     */
    function setPair(address _pair) external {
        pair = _pair;
        isToken0 = UniswapV2Pair(_pair).token0() == address(this);
    }

    /**
     * @notice 启用攻击模式
     */
    function enableAttack() external {
        attackEnabled = true;
        attackCount = 0;
    }

    /**
     * @notice 禁用攻击模式
     */
    function disableAttack() external {
        attackEnabled = false;
    }

    /**
     * @notice 恶意的转账函数，在转账时发起重入攻击
     * @param to 转账目标地址
     * @param amount 转账数量
     * @return 转账是否成功
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        // 发起重入攻击
        if (attackEnabled && msg.sender == pair && attackCount < maxAttacks) {
            attackCount++;
            console.log("Launching reentrancy attack, attempt:", attackCount);

            // 尝试重入 swap 函数
            if (isToken0) {
                try UniswapV2Pair(pair).swap(100 ether, 0, address(this), "") {
                    console.log("Reentrancy attack succeeded");
                } catch Error(string memory reason) {
                    console.log("Reentrancy attack failed:", reason);
                } catch {
                    console.log("Reentrancy attack failed with unknown error");
                }
            } else {
                try UniswapV2Pair(pair).swap(0, 100 ether, address(this), "") {
                    console.log("Reentrancy attack succeeded");
                } catch Error(string memory reason) {
                    console.log("Reentrancy attack failed:", reason);
                } catch {
                    console.log("Reentrancy attack failed with unknown error");
                }
            }
        }

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice 授权函数
     * @param spender 被授权地址
     * @param amount 授权数量
     * @return 是否成功
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice 代理转账函数
     * @param from 转账来源地址
     * @param to 转账目标地址
     * @param amount 转账数量
     * @return 是否成功
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        emit Transfer(from, to, amount);
        return true;
    }

    /**
     * @notice 铸造代币（仅用于测试）
     * @param to 接收地址
     * @param amount 铸造数量
     */
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    // 事件定义
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/**
 * @title 闪电贷攻击者合约
 * @notice 模拟使用闪电贷进行重入攻击的场景
 */
contract FlashLoanAttacker {
    UniswapV2Pair public target;
    bool public attacking = false;

    /**
     * @notice 执行闪电贷攻击
     * @param pairAddress 目标交易对地址
     */
    function executeFlashLoan(address pairAddress) external {
        target = UniswapV2Pair(pairAddress);
        attacking = true;

        // 模拟闪电贷：借出大量代币
        try target.swap(500 ether, 0, address(this), "") {
            return;
        } catch {
            target.swap(0, 500 ether, address(this), "");
        }
    }

    /**
     * @notice 在接收代币时尝试重入攻击
     */
    function onTokenReceived() external {
        if (attacking) {
            attacking = false;
            // 尝试再次调用 swap
            try target.swap(100 ether, 0, address(this), "") {
                return;
            } catch {
                target.swap(0, 100 ether, address(this), "");
            }
        }
    }

    /**
     * @notice 接收 ETH
     */
    receive() external payable {}
}
