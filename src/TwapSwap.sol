/**
 * @title TwapSwap (TWAP Module for 1inch Security Dashboard)
 * @notice This contract enables creation and execution of Time-Weighted Average Price (TWAP) orders, providing a price sanity-check layer for swaps.
 * @dev Used as a price validation and execution module by SwapAuditor. Can integrate with external oracles or onchain TWAP sources (e.g., Uniswap V3) to compare swap prices with fair market rates. Part of the modular security and analytics system built on top of 1inch Router.
 *
 * Key Features:
 * - Allows users to create TWAP orders, splitting large swaps into smaller intervals to reduce slippage and market impact.
 * - Provides a reference price for SwapAuditor to validate swap plausibility and detect abnormal price deviations.
 * - Designed for extensibility and integration with other DeFi analytics and security modules.
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IAggregationRouterV6
 * @dev Interface for the 1inch Aggregation Router V6
 */
interface IAggregationRouterV6 {
    /**
     * @notice Swaps tokens via 1inch router
     * @param caller The address initiating the swap
     * @param data Encoded swap data
     * @return returnAmount The amount of output tokens received
     * @return spentAmount The amount of input tokens spent
     */
    function swap(address caller, bytes calldata data)
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount);
}

/**
 * @title TwapSwap
 * @notice Enables users to create and execute TWAP (Time-Weighted Average Price) orders using the 1inch router
 * @dev Inherits Ownable, Pausable, and ReentrancyGuard for access control, pausing, and reentrancy protection
 */
contract TwapSwap is Ownable, Pausable, ReentrancyGuard {
    /// @notice Address of the 1inch router
    address public oneInchRouter;
    /// @notice TWAP interval in seconds
    uint256 public twapInterval; // in seconds
    /// @notice Fee for executors in basis points (e.g., 50 = 0.5%)
    uint256 public executorFeeBps = 0; // Fee in basis points (e.g., 50 = 0.5%)

    /**
     * @notice Struct representing a TWAP order
     * @param user The user who created the order
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param totalAmountIn The total input amount for the order
     * @param amountPerInterval The amount to swap per interval
     * @param intervals The total number of intervals
     * @param executedIntervals The number of intervals already executed
     * @param lastExecution The timestamp of the last execution
     * @param active Whether the order is active
     */
    struct TwapOrder {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 totalAmountIn;
        uint256 amountPerInterval;
        uint256 intervals;
        uint256 executedIntervals;
        uint256 lastExecution;
        bool active;
    }

    /// @notice Mapping from orderId to TwapOrder
    mapping(bytes32 => TwapOrder) public twapOrders;

    /**
     * @notice Emitted when a new TWAP order is created
     * @param orderId The unique identifier of the order
     * @param user The user who created the order
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param totalAmountIn The total input amount
     * @param amountPerInterval The amount to swap per interval
     * @param intervals The total number of intervals
     */
    event TwapOrderCreated(
        bytes32 indexed orderId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        uint256 amountPerInterval,
        uint256 intervals
    );
    /**
     * @notice Emitted when a TWAP order is executed for an interval
     * @param orderId The unique identifier of the order
     * @param interval The interval number executed
     * @param amountIn The input amount swapped
     * @param amountOut The output amount received
     */
    event TwapOrderExecuted(bytes32 indexed orderId, uint256 interval, uint256 amountIn, uint256 amountOut);
    /**
     * @notice Emitted when a TWAP order is cancelled
     * @param orderId The unique identifier of the order
     */
    event TwapOrderCancelled(bytes32 indexed orderId);
    /**
     * @notice Emitted when the 1inch router address is updated
     * @param newRouter The new 1inch router address
     */
    event OneInchRouterUpdated(address newRouter);
    /**
     * @notice Emitted when the TWAP interval is updated
     * @param newInterval The new interval in seconds
     */
    event TwapIntervalUpdated(uint256 newInterval);
    /**
     * @notice Emitted when the executor fee is updated
     * @param newFeeBps The new fee in basis points
     */
    event ExecutorFeeUpdated(uint256 newFeeBps);

    /**
     * @notice Constructor to initialize the contract
     * @param _oneInchRouter The address of the 1inch router
     * @param _twapInterval The TWAP interval in seconds
     */
    constructor(address _oneInchRouter, uint256 _twapInterval) Ownable(msg.sender) {
        require(_oneInchRouter != address(0), "Invalid 1inch router");
        oneInchRouter = _oneInchRouter;
        twapInterval = _twapInterval;
    }

    /**
     * @notice Updates the 1inch router address
     * @param _router The new router address
     */
    function setOneInchRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        oneInchRouter = _router;
        emit OneInchRouterUpdated(_router);
    }

    /**
     * @notice Updates the TWAP interval
     * @param _interval The new interval in seconds
     */
    function setTwapInterval(uint256 _interval) external onlyOwner {
        require(_interval > 0, "Interval must be positive");
        twapInterval = _interval;
        emit TwapIntervalUpdated(_interval);
    }

    /**
     * @notice Updates the executor fee in basis points
     * @param _feeBps The new fee in basis points (max 1000 = 10%)
     */
    function setExecutorFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "Fee too high"); // Max 10%
        executorFeeBps = _feeBps;
        emit ExecutorFeeUpdated(_feeBps);
    }

    /**
     * @notice Creates a new TWAP order
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param totalAmountIn The total input amount
     * @param amountPerInterval The amount to swap per interval
     * @param intervals The total number of intervals
     * @return orderId The unique identifier of the created order
     */
    function createTwapOrder(
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        uint256 amountPerInterval,
        uint256 intervals
    ) external whenNotPaused returns (bytes32) {
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid token address");
        require(totalAmountIn > 0 && amountPerInterval > 0 && intervals > 0, "Invalid amounts");
        require(totalAmountIn == amountPerInterval * intervals, "Amounts mismatch");

        bytes32 orderId = keccak256(abi.encode(msg.sender, tokenIn, tokenOut, block.timestamp, totalAmountIn));
        require(!twapOrders[orderId].active, "Order already exists");

        // Transfer tokens from user to contract
        IERC20(tokenIn).transferFrom(msg.sender, address(this), totalAmountIn);

        twapOrders[orderId] = TwapOrder({
            user: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            totalAmountIn: totalAmountIn,
            amountPerInterval: amountPerInterval,
            intervals: intervals,
            executedIntervals: 0,
            lastExecution: 0,
            active: true
        });

        emit TwapOrderCreated(orderId, msg.sender, tokenIn, tokenOut, totalAmountIn, amountPerInterval, intervals);
        return orderId;
    }

    /**
     * @notice Executes a TWAP order for the next interval
     * @param orderId The unique identifier of the order
     * @param oneInchData Encoded swap data for the 1inch router
     * @param minOut Minimum acceptable output amount (slippage protection)
     */
    function executeTwapOrder(bytes32 orderId, bytes calldata oneInchData, uint256 minOut)
        external
        nonReentrant
        whenNotPaused
    {
        TwapOrder storage order = twapOrders[orderId];
        require(order.active, "Order inactive");
        require(order.executedIntervals < order.intervals, "Order complete");
        require(
            block.timestamp >= order.lastExecution + twapInterval || order.lastExecution == 0, "Interval not reached"
        );

        // Safe approve pattern
        IERC20(order.tokenIn).approve(oneInchRouter, 0);
        IERC20(order.tokenIn).approve(oneInchRouter, order.amountPerInterval);

        // Call 1inch router
        (uint256 returnAmount,) = IAggregationRouterV6(oneInchRouter).swap(address(this), oneInchData);
        require(returnAmount >= minOut, "Slippage: amountOut below minOut");

        order.executedIntervals++;
        order.lastExecution = block.timestamp;

        // Calculate executor fee
        uint256 fee = (returnAmount * executorFeeBps) / 10000;
        uint256 userAmount = returnAmount - fee;

        // Transfer output tokens to user and executor
        IERC20(order.tokenOut).transfer(order.user, userAmount);
        if (fee > 0) {
            IERC20(order.tokenOut).transfer(msg.sender, fee);
        }

        emit TwapOrderExecuted(orderId, order.executedIntervals, order.amountPerInterval, returnAmount);

        // Deactivate order if complete
        if (order.executedIntervals == order.intervals) {
            order.active = false;
        }
    }

    /**
     * @notice Cancels an active TWAP order and refunds remaining tokens
     * @param orderId The unique identifier of the order
     */
    function cancelTwapOrder(bytes32 orderId) external nonReentrant {
        TwapOrder storage order = twapOrders[orderId];
        require(order.active, "Order inactive");
        require(msg.sender == order.user || msg.sender == owner(), "Not authorized");

        uint256 remaining = (order.intervals - order.executedIntervals) * order.amountPerInterval;
        if (remaining > 0) {
            IERC20(order.tokenIn).transfer(order.user, remaining);
        }
        order.active = false;
        emit TwapOrderCancelled(orderId);
    }

    /**
     * @notice Pauses the contract (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
