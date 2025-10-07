// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/core/UniswapV2Factory.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/core/interfaces/IUniswapV2Callee.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Flashloaner is IUniswapV2Callee {
    error EmptyStrategy();

    IERC20 public immutable token;
    UniswapV2Pair public immutable pair;

    constructor(address token_, address pair_) {
        token = IERC20(token_);
        pair = UniswapV2Pair(pair_);
    }

    function executeFlashloan(uint256 amount, bytes calldata params) external {
        pair.swap(0, amount, address(this), params);
    }

    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata params
    ) external override {
        require(msg.sender == address(pair), "Flashloaner: only pair");

        bytes32 strategy = abi.decode(params, (bytes32));
        if (strategy == bytes32(0)) revert EmptyStrategy();

        uint256 fee = (amount1 * 1000) / 997 - amount1 + 1;
        token.transfer(address(pair), amount1 + fee);
    }
}

/**
 * @title UniswapV2PairFeeTest
 * @notice 覆盖 swap 手续费扣除场景，确保恒定乘积不被破坏
 */
contract UniswapV2PairFeeTest is Test {
    ERC20Mock private token0;
    ERC20Mock private token1;
    UniswapV2Factory private factory;
    UniswapV2Pair private pair;

    function _getAmountOut(uint256 amountIn, uint112 reserveIn, uint112 reserveOut) private pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = uint256(reserveIn) * 1000 + amountInWithFee;
        return numerator / denominator;
    }

    function setUp() public {
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();

        factory = new UniswapV2Factory(address(this));
        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = UniswapV2Pair(pairAddr);

        if (address(token0) != pair.token0()) {
            (token0, token1) = (token1, token0);
        }

        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 20 ether);

        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 2 ether);
        pair.mint(address(this));
    }

    function testSwapRevertsWhenFeeUnpaid() public {
        token0.transfer(address(pair), 0.1 ether);

        vm.expectRevert(UniswapV2Pair.InvalidK.selector);
        pair.swap(0, 0.181322178776029827 ether, address(this), "");
    }

    function testSwapSucceedsAfterFeeDeduction() public {
        token0.transfer(address(pair), 0.1 ether);

        pair.swap(0, 0.181322178776029826 ether, address(this), "");

        (uint112 reserve0After, uint112 reserve1After,) = pair.getReserves();
        assertGt(uint256(reserve0After) * uint256(reserve1After), 2 ether);
    }

    function testFlashloanAccumulatesFee() public {
        Flashloaner fl = new Flashloaner(address(token1), address(pair));

        uint256 loanAmount = 0.1 ether;
        uint256 fee = (loanAmount * 1000) / 997 - loanAmount + 1;

        token1.mint(address(fl), fee);

        (uint112 reserve0Before, uint112 reserve1Before,) = pair.getReserves();

        fl.executeFlashloan(loanAmount, abi.encode(bytes32("ARBITRAGE")));

        (uint112 reserve0After, uint112 reserve1After,) = pair.getReserves();

        assertEq(reserve0After, reserve0Before, unicode"token0 储备不应变化");
        assertEq(reserve1After, reserve1Before + uint112(fee), unicode"手续费应回流交易对");
        assertEq(token1.balanceOf(address(fl)), 0, unicode"借款方应清空余额");
    }

    function testProtocolFeeAccruesToFeeTo() public {
        address feeRecipient = address(0xFEE);
        factory.setFeeTo(feeRecipient);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 amountIn = 0.5 ether;
        uint256 amountOut = _getAmountOut(amountIn, reserve0, reserve1);

        token0.transfer(address(pair), amountIn);
        pair.swap(0, amountOut, address(this), "");

        uint256 liquidity = pair.balanceOf(address(this));
        pair.transfer(address(pair), liquidity);
        pair.burn(address(this));

        assertGt(pair.balanceOf(feeRecipient), 0, unicode"协议费接收地址应获得 LP 份额");
    }
}
