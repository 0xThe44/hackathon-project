// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/TwapSwap.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is IERC20 {
    string public name = "MockToken";
    string public symbol = "MTK";
    uint8 public decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient");
        require(allowance[from][msg.sender] >= amount, "Not allowed");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract Mock1InchRouter is IAggregationRouterV6 {
    uint256 public returnAmount;
    address public tokenOut;

    function setReturnAmount(uint256 amt) external {
        returnAmount = amt;
    }

    function setTokenOut(address _tokenOut) external {
        tokenOut = _tokenOut;
    }

    function swap(address, bytes calldata) external payable override returns (uint256, uint256) {
        if (tokenOut != address(0) && returnAmount > 0) {
            IERC20(tokenOut).transfer(msg.sender, returnAmount);
        }
        return (returnAmount, 0);
    }
}

contract TwapSwapTest is Test {
    TwapSwap twap;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    Mock1InchRouter router;
    address user = address(0x1);
    address executor = address(0x2);

    function setUp() public {
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        router = new Mock1InchRouter();
        twap = new TwapSwap(address(router), 1); // 1 second interval
        tokenIn.mint(user, 100e18);
        tokenOut.mint(address(router), 100e18);
        router.setTokenOut(address(tokenOut));
    }

    function testCreateAndExecuteTwapOrder() public {
        vm.startPrank(user);
        tokenIn.approve(address(twap), 10e18);
        bytes32 orderId = twap.createTwapOrder(address(tokenIn), address(tokenOut), 10e18, 2e18, 5);
        vm.stopPrank();

        // Set router to return 2e18 tokenOut
        router.setReturnAmount(2e18);
        // Executor executes interval
        vm.prank(executor);
        twap.executeTwapOrder(orderId, bytes(""), 2e18);
        // Check user received tokenOut
        assertEq(tokenOut.balanceOf(user), 2e18);
        // Check order state
        (,,,,,,,, bool active) = twap.twapOrders(orderId);
        assertTrue(active);
    }

    function testSlippageProtection() public {
        vm.startPrank(user);
        tokenIn.approve(address(twap), 10e18);
        bytes32 orderId = twap.createTwapOrder(address(tokenIn), address(tokenOut), 10e18, 2e18, 5);
        vm.stopPrank();
        router.setReturnAmount(1e18); // less than minOut
        vm.prank(executor);
        vm.expectRevert("Slippage: amountOut below minOut");
        twap.executeTwapOrder(orderId, bytes(""), 2e18);
    }

    function testExecutorFee() public {
        twap.setExecutorFee(500); // 5%
        vm.startPrank(user);
        tokenIn.approve(address(twap), 10e18);
        bytes32 orderId = twap.createTwapOrder(address(tokenIn), address(tokenOut), 10e18, 2e18, 5);
        vm.stopPrank();
        router.setReturnAmount(2e18);
        uint256 executorStart = tokenOut.balanceOf(executor);
        vm.prank(executor);
        twap.executeTwapOrder(orderId, bytes(""), 2e18);
        // User gets 1.9e18, executor gets 0.1e18
        assertEq(tokenOut.balanceOf(user), 1.9e18);
        assertEq(tokenOut.balanceOf(executor), executorStart + 0.1e18);
    }

    function testCancelOrder() public {
        vm.startPrank(user);
        tokenIn.approve(address(twap), 10e18);
        bytes32 orderId = twap.createTwapOrder(address(tokenIn), address(tokenOut), 10e18, 2e18, 5);
        vm.stopPrank();
        // Cancel as user
        vm.prank(user);
        twap.cancelTwapOrder(orderId);
        (,,,,,,,, bool active) = twap.twapOrders(orderId);
        assertFalse(active);
        // Remaining tokens refunded
        assertEq(tokenIn.balanceOf(user), 100e18);
    }

    function testOnlyOwnerSetExecutorFee() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user));
        twap.setExecutorFee(100);
    }

    function testOrderCompletesAfterAllIntervals() public {
        vm.startPrank(user);
        tokenIn.approve(address(twap), 10e18);
        bytes32 orderId = twap.createTwapOrder(address(tokenIn), address(tokenOut), 10e18, 2e18, 5);
        vm.stopPrank();
        router.setReturnAmount(2e18);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(executor);
            twap.executeTwapOrder(orderId, bytes(""), 2e18);
        }
        (,,,,,,,, bool active) = twap.twapOrders(orderId);
        assertFalse(active);
    }
}
