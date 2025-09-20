// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/core/UniswapV2Pair.sol";
import "../../src/libraries/StorageOptimization.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Simple Gas Optimization Test
 * @notice Simple test suite for gas optimization verification
 */
contract SimpleGasTest is Test {
    UniswapV2Pair pair;
    TestToken token0;
    TestToken token1;
    
    address user1 = makeAddr("user1");

    function setUp() public {
        token0 = new TestToken("Token0", "TKN0", 18);
        token1 = new TestToken("Token1", "TKN1", 18);
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        pair = new UniswapV2Pair(address(token0), address(token1));
        token0.mint(user1, 1000 ether);
        token1.mint(user1, 1000 ether);
    }

    /**
     * @notice Test basic gas usage for reserve updates
     */
    function testBasicGasUsage() public {
        console.log("=== Basic Gas Usage Test ===");

        vm.startPrank(user1);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);

        uint256 gasBefore = gasleft();
        pair.mint(user1);
        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;

        vm.stopPrank();

        console.log("Gas used for mint operation:", gasUsed);
        assertTrue(gasUsed > 0, "Should consume gas");
        assertTrue(gasUsed < 500000, "Should be reasonable gas usage");
    }

    /**
     * @notice Test storage optimization library functions
     */
    function testStorageOptimizationLibrary() public view {
        console.log("=== Storage Optimization Library Test ===");

        // Test packing efficiency
        (uint256 efficiency, uint256 usedBits, uint256 wastedBits) = 
            StorageOptimization.getUniswapV2PackingEfficiency();

        console.log("Packing efficiency:", efficiency, "%");
        console.log("Used bits:", usedBits);
        console.log("Wasted bits:", wastedBits);

        assertEq(efficiency, 100, "Should have 100% efficiency");
        assertEq(usedBits, 256, "Should use 256 bits");
        assertEq(wastedBits, 0, "Should waste 0 bits");
    }

    /**
     * @notice Test pack and unpack operations
     */
    function testPackUnpack() public {
        uint112 reserve0 = 1000 ether;
        uint112 reserve1 = 2000 ether;
        uint32 timestamp = uint32(block.timestamp);

        uint256 packed = StorageOptimization.packValues(reserve0, reserve1, timestamp);
        (uint112 unpacked0, uint112 unpacked1, uint32 unpackedTime) = 
            StorageOptimization.unpackValues(packed);

        assertEq(unpacked0, reserve0, "Reserve0 should match");
        assertEq(unpacked1, reserve1, "Reserve1 should match");
        assertEq(unpackedTime, timestamp, "Timestamp should match");
    }

    /**
     * @notice Test storage slot analysis
     */
    function testStorageAnalysis() public view {
        console.log("=== Storage Analysis Test ===");

        (uint256 optimizedSlots, uint256 unoptimizedSlots, uint256 savedSlots) = 
            StorageOptimization.analyzeStorageUsage();

        console.log("Optimized slots:", optimizedSlots);
        console.log("Unoptimized slots:", unoptimizedSlots);
        console.log("Saved slots:", savedSlots);

        assertEq(optimizedSlots, 1, "Should use 1 optimized slot");
        assertEq(unoptimizedSlots, 4, "Should use 4 unoptimized slots");
        assertEq(savedSlots, 3, "Should save 3 slots");
    }

    /**
     * @notice Test multiple operations for cumulative gas savings
     */
    function testMultipleOperations() public {
        console.log("=== Multiple Operations Test ===");

        // Initialize pool
        vm.startPrank(user1);
        token0.transfer(address(pair), 100 ether);
        token1.transfer(address(pair), 100 ether);
        pair.mint(user1);
        vm.stopPrank();

        uint256 totalGas = 0;
        uint256 operations = 3;

        // Perform multiple swap operations
        for (uint256 i = 0; i < operations; i++) {
            vm.startPrank(user1);
            
            uint256 amountIn = 1 ether;
            token0.transfer(address(pair), amountIn);
            
            uint256 gasBefore = gasleft();
            pair.swap(0, 0.9 ether, user1, "");
            uint256 gasAfter = gasleft();
            
            totalGas += (gasBefore - gasAfter);
            vm.stopPrank();
        }

        console.log("Total gas for", operations, "operations:", totalGas);
        console.log("Average gas per operation:", totalGas / operations);

        assertTrue(totalGas > 0, "Should consume gas");
    }
}

/**
 * @title Test ERC20 Token
 */
contract TestToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}