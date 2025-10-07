// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/core/interfaces/IUniswapV2Callee.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title 恶意回调合约，用于测试交易对的重入防护
contract ReentrantCallee is IUniswapV2Callee {
    error CallerNotPair();

    UniswapV2Pair public immutable pair;
    uint256 private amount0Out;
    uint256 private amount1Out;

    constructor(address pair_) {
        pair = UniswapV2Pair(pair_);
    }

    /// @notice 通过闪电贷调用交易对，尝试在回调中重入
    function attack(uint256 amount0, uint256 amount1) external {
        amount0Out = amount0;
        amount1Out = amount1;
        pair.swap(amount0, amount1, address(this), abi.encode(uint256(1)));
    }

    function uniswapV2Call(
        address,
        uint256,
        uint256,
        bytes calldata
    ) external override {
        if (msg.sender != address(pair)) revert CallerNotPair();

        // 重入调用应触发交易对中的重入保护
        pair.swap(amount0Out, amount1Out, address(this), "");
    }
}

/// @title UniswapV2Pair 重入防护测试
contract UniswapV2PairReentrancyTest is Test {
    ERC20Mock private token0;
    ERC20Mock private token1;
    UniswapV2Pair private pair;
    ReentrantCallee private attacker;

    function setUp() public {
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();

        pair = new UniswapV2Pair();
        pair.initialize(address(token0), address(token1));

        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 20 ether);

        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 2 ether);

        pair.mint(address(this));

        attacker = new ReentrantCallee(address(pair));
    }

    function testReentrancyGuardBlocksNestedSwap() public {
        vm.expectRevert(UniswapV2Pair.ReentrancyGuard.selector);
        attacker.attack(0, 0.1 ether);
    }
}
