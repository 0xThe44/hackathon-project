// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/SwapAuditor.sol";

contract NotERC20 {}

contract SwapAuditorTest is Test {
    SwapAuditor swapAuditor;
    address tokenIn = address(0x123);
    address tokenOut = address(0x456);
    address owner;
    address user = address(0x1);
    address attacker = address(0x2);
    address trustedCaller = address(0x3);
    uint256 constant DEFAULT_SPREAD_THRESHOLD = 9500;

    function setUp() public {
        owner = address(this); // Тестовый контракт — владелец
        swapAuditor = new SwapAuditor();
        swapAuditor.setTrustedCaller(trustedCaller, true);

        // Эмулируем вызов symbol() для валидных токенов
        vm.mockCall(tokenIn, abi.encodeWithSignature("symbol()"), abi.encode("TIN"));
        vm.mockCall(tokenOut, abi.encodeWithSignature("symbol()"), abi.encode("TOUT"));
    }

    function testDeployment() public view {
        assertEq(swapAuditor.owner(), owner);
        assertEq(swapAuditor.defaultSpreadThreshold(), DEFAULT_SPREAD_THRESHOLD);
        assertFalse(swapAuditor.paused());
        assertTrue(swapAuditor.trustedCallers(owner));
        assertTrue(swapAuditor.trustedCallers(trustedCaller));
    }

    function testAnalyzeSafeSwap() public {
        uint128 amountIn = 1e18; // 1 токен
        uint128 amountOut = 0.95e18; // Спред = 95%, безопасно
        bytes32 swapId = keccak256(abi.encode(user, amountIn, amountOut, tokenIn, tokenOut));

        vm.prank(trustedCaller);
        vm.expectEmit(true, true, false, true);
        emit SwapAuditor.SwapAnalyzed(swapId, user, tokenIn, tokenOut, amountIn, amountOut, true);
        swapAuditor.analyzeSwap(user, amountIn, amountOut, tokenIn, tokenOut, amountOut); // minOut = amountOut

        SwapAuditor.SwapData memory swapData = swapAuditor.getSwapData(swapId);
        assertEq(swapData.sender, user);
        assertEq(swapData.amountIn, amountIn);
        assertEq(swapData.amountOut, amountOut);
        assertEq(swapData.tokenIn, tokenIn);
        assertEq(swapData.tokenOut, tokenOut);
        assertTrue(swapData.isSafe);
        assertEq(swapAuditor.totalSwaps(), 1);
        assertEq(swapAuditor.unsafeSwaps(), 0);
    }

    function testAnalyzeUnsafeSwap() public {
        uint128 amountIn = 1e18;
        uint128 amountOut = 0.9e18; // Спред = 90%, небезопасно
        bytes32 swapId = keccak256(abi.encode(user, amountIn, amountOut, tokenIn, tokenOut));

        vm.prank(trustedCaller);
        vm.expectEmit(true, true, false, true);
        emit SwapAuditor.SwapAnalyzed(swapId, user, tokenIn, tokenOut, amountIn, amountOut, false);
        swapAuditor.analyzeSwap(user, amountIn, amountOut, tokenIn, tokenOut, amountOut); // minOut = amountOut

        SwapAuditor.SwapData memory swapData = swapAuditor.getSwapData(swapId);
        assertFalse(swapData.isSafe);
        assertEq(swapAuditor.totalSwaps(), 1);
        assertEq(swapAuditor.unsafeSwaps(), 1);
    }

    function testRevertZeroAmountIn() public {
        vm.prank(trustedCaller);
        vm.expectRevert("AmountIn must be greater than 0");
        swapAuditor.analyzeSwap(user, 0, 1e18, tokenIn, tokenOut, 1e18);
    }

    function testRevertZeroTokenAddress() public {
        vm.prank(trustedCaller);
        vm.expectRevert("Invalid token address");
        swapAuditor.analyzeSwap(user, 1e18, 1e18, address(0), tokenOut, 1e18);

        vm.prank(trustedCaller);
        vm.expectRevert("Invalid token address");
        swapAuditor.analyzeSwap(user, 1e18, 1e18, tokenIn, address(0), 1e18);
    }

    function testRevertInvalidERC20() public {
        NotERC20 invalidToken = new NotERC20();
        vm.prank(trustedCaller);
        vm.expectRevert("Invalid ERC20 token");
        swapAuditor.analyzeSwap(user, 1e18, 1e18, address(invalidToken), tokenOut, 1e18);
    }

    function testRevertBlacklistedSender() public {
        swapAuditor.setBlackListedAddress(user, true);
        vm.prank(trustedCaller);
        vm.expectRevert("Blacklisted address");
        swapAuditor.analyzeSwap(user, 1e18, 1e18, tokenIn, tokenOut, 1e18);
    }

    function testRevertBlacklistedToken() public {
        swapAuditor.setBlackListedAddress(tokenIn, true);
        vm.prank(trustedCaller);
        vm.expectRevert("Blacklisted address");
        swapAuditor.analyzeSwap(user, 1e18, 1e18, tokenIn, tokenOut, 1e18);
    }

    function testRevertSwapAlreadyAnalyzed() public {
        uint128 amountIn = 1e18;
        uint128 amountOut = 0.95e18;
        vm.prank(trustedCaller);
        swapAuditor.analyzeSwap(user, amountIn, amountOut, tokenIn, tokenOut, amountOut);
        vm.prank(trustedCaller);
        vm.expectRevert("Swap already analyzed");
        swapAuditor.analyzeSwap(user, amountIn, amountOut, tokenIn, tokenOut, amountOut);
    }

    function testRevertNonTrustedCaller() public {
        vm.prank(attacker);
        vm.expectRevert("Not trusted caller");
        swapAuditor.analyzeSwap(user, 1e18, 1e18, tokenIn, tokenOut, 1e18);
    }

    function testRevertWhenPaused() public {
        swapAuditor.pause();
        vm.prank(trustedCaller);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        swapAuditor.analyzeSwap(user, 1e18, 1e18, tokenIn, tokenOut, 1e18);
    }

    function testSetSpreadThreshold() public {
        uint256 newThreshold = 9600;
        vm.expectEmit(false, false, false, true);
        emit SwapAuditor.SpreadThresholdUpdated(newThreshold);
        swapAuditor.setSpreadThreshold(newThreshold);
        assertEq(swapAuditor.defaultSpreadThreshold(), newThreshold);
    }

    function testRevertSetSpreadThresholdTooHigh() public {
        vm.expectRevert("Threshold too high");
        swapAuditor.setSpreadThreshold(10001);
    }

    function testRevertSetSpreadThresholdNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), attacker));
        swapAuditor.setSpreadThreshold(9600);
    }

    function testSetPairSpreadThreshold() public {
        uint256 threshold = 9700;
        vm.expectEmit(true, true, false, true);
        emit SwapAuditor.PairSpreadThresholdUpdated(tokenIn, tokenOut, threshold);
        swapAuditor.setPairSpreadThreshold(tokenIn, tokenOut, threshold);
        assertEq(swapAuditor.pairSpreadThresholds(tokenIn, tokenOut), threshold);

        // Проверяем, что порог для пары работает
        uint128 amountIn = 1e18;
        uint128 amountOut = 0.96e18; // Спред = 96%, небезопасно для 97%
        bytes32 swapId = keccak256(abi.encode(user, amountIn, amountOut, tokenIn, tokenOut));
        vm.prank(trustedCaller);
        swapAuditor.analyzeSwap(user, amountIn, amountOut, tokenIn, tokenOut, amountOut);
        SwapAuditor.SwapData memory swapData = swapAuditor.getSwapData(swapId);
        assertFalse(swapData.isSafe);
    }

    function testFuzzAnalyzeSwap(uint128 amountIn, uint128 amountOut) public {
        vm.assume(amountIn > 0); // Избегаем реверта на нуле
        bytes32 swapId = keccak256(abi.encode(user, amountIn, amountOut, tokenIn, tokenOut));
        uint256 spread = (uint256(amountOut) * 10000) / uint256(amountIn);
        bool expectedIsSafe = spread >= DEFAULT_SPREAD_THRESHOLD;

        vm.prank(trustedCaller);
        vm.expectEmit(true, true, false, true);
        emit SwapAuditor.SwapAnalyzed(swapId, user, tokenIn, tokenOut, amountIn, amountOut, expectedIsSafe);
        swapAuditor.analyzeSwap(user, amountIn, amountOut, tokenIn, tokenOut, amountOut);

        SwapAuditor.SwapData memory swapData = swapAuditor.getSwapData(swapId);
        assertEq(swapData.isSafe, expectedIsSafe);
        assertEq(swapAuditor.totalSwaps(), 1);
        assertEq(swapAuditor.unsafeSwaps(), expectedIsSafe ? 0 : 1);
    }

    // New test for minOut slippage protection
    function testRevertSlippageProtection() public {
        uint128 amountIn = 1e18;
        uint128 amountOut = 0.9e18;
        uint128 minOut = 0.95e18; // minOut > amountOut
        vm.prank(trustedCaller);
        vm.expectRevert("Slippage: amountOut below minOut");
        swapAuditor.analyzeSwap(user, amountIn, amountOut, tokenIn, tokenOut, minOut);
    }

    function testRevertSetBlackListedAddressNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), attacker));
        swapAuditor.setBlackListedAddress(user, true);
    }

    function testRevertSetTrustedCallerNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), attacker));
        swapAuditor.setTrustedCaller(attacker, true);
    }
}
