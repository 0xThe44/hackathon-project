/**
 * @title SwapProxy (Auditable Proxy for 1inch Security Dashboard)
 * @notice Secure proxy contract for forwarding swaps to 1inch Router with integrated analytics and risk checks.
 * @dev Wraps 1inch Router calls, enforces token whitelisting, and logs all swaps. Forwards swap data to SwapAuditor for real-time analysis, risk detection, and event emission. Designed as a modular, extensible entry point for DeFi swap security and monitoring.
 *
 * Key Features:
 * - Forwards swaps to 1inch Router with pre- and post-swap analytics
 * - Integrates with SwapAuditor for risk checks and event logging
 * - Enforces token whitelisting for additional security
 * - Emits events for off-chain dashboards and monitoring
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

interface ISwapAuditor {
    /**
     * @notice Analyzes a swap for safety and risk
     * @param sender The address initiating the swap
     * @param amountIn The input amount
     * @param amountOut The output amount
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param minOut Minimum acceptable output amount (slippage protection)
     * @return swapId The unique identifier of the analyzed swap
     */
    function analyzeSwap(
        address sender,
        uint256 amountIn,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        uint256 minOut
    ) external returns (bytes32);
    /**
     * @notice Gets the swap status (isSafe) by swapId
     * @param swapId The unique identifier of the swap
     * @return isSafe True if the swap is considered safe
     */
    function getSwapStatus(bytes32 swapId) external view returns (bool);
}

/**
 * @notice Main proxy contract for secure, auditable swaps via 1inch Router
 * @dev Forwards swaps to 1inch, enforces token whitelisting, and integrates with SwapAuditor for analytics and risk checks
 */
contract SwapProxy is Ownable, Pausable, ReentrancyGuard {
    /// @notice Address of the 1inch router
    address public oneInchRouter;
    /// @notice Address of the SwapAuditor contract
    address public swapAuditor;
    /// @notice Mapping of whitelisted tokens
    mapping(address => bool) public whitelistedTokens;

    /**
     * @notice Emitted when a swap is forwarded to 1inch
     * @param sender The address initiating the swap
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The input amount
     * @param minOut The minimum output amount required
     * @param oneInchData Encoded swap data for 1inch router
     */
    event SwapForwarded(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes oneInchData
    );
    /**
     * @notice Emitted when a swap is audited by SwapAuditor
     * @param swapId The unique identifier of the swap
     * @param isSafe Whether the swap is considered safe
     */
    event SwapAudited(bytes32 swapId, bool isSafe);
    /**
     * @notice Emitted when a token is whitelisted or removed from whitelist
     * @param token The token address
     * @param whitelisted Whether the token is whitelisted
     */
    event TokenWhitelisted(address token, bool whitelisted);
    /**
     * @notice Emitted when the 1inch router address is updated
     * @param newRouter The new 1inch router address
     */
    event OneInchRouterUpdated(address newRouter);
    /**
     * @notice Emitted when the SwapAuditor address is updated
     * @param newAuditor The new SwapAuditor address
     */
    event SwapAuditorUpdated(address newAuditor);

    /**
     * @notice Initializes the SwapProxy contract
     * @param _oneInchRouter The address of the 1inch router
     * @param _swapAuditor The address of the SwapAuditor contract
     */
    constructor(address _oneInchRouter, address _swapAuditor) Ownable(msg.sender) {
        require(_oneInchRouter != address(0), "Invalid 1inch router");
        require(_swapAuditor != address(0), "Invalid auditor");
        oneInchRouter = _oneInchRouter;
        swapAuditor = _swapAuditor;
    }

    /**
     * @notice Updates the 1inch router address
     * @param _router The new 1inch router address
     */
    function setOneInchRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        oneInchRouter = _router;
        emit OneInchRouterUpdated(_router);
    }

    /**
     * @notice Updates the SwapAuditor contract address
     * @param _auditor The new SwapAuditor address
     */
    function setSwapAuditor(address _auditor) external onlyOwner {
        require(_auditor != address(0), "Invalid auditor");
        swapAuditor = _auditor;
        emit SwapAuditorUpdated(_auditor);
    }

    /**
     * @notice Whitelists or removes a token from the whitelist
     * @param token The token address
     * @param whitelisted Whether the token should be whitelisted
     */
    function setWhitelistedToken(address token, bool whitelisted) external onlyOwner {
        whitelistedTokens[token] = whitelisted;
        emit TokenWhitelisted(token, whitelisted);
    }

    /**
     * @notice Forwards a swap to 1inch Router, then calls SwapAuditor for analysis
     * @dev Transfers input tokens from user, approves 1inch, executes swap, transfers output to user, and audits the swap
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The input amount
     * @param minOut The minimum output amount required (slippage protection)
     * @param oneInchData Encoded swap data for 1inch router
     * @return returnAmount The amount of output tokens received
     * @return spentAmount The amount of input tokens spent
     * @return swapId The unique identifier of the audited swap
     */
    function proxySwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata oneInchData)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 returnAmount, uint256 spentAmount, bytes32 swapId)
    {
        require(whitelistedTokens[tokenIn] && whitelistedTokens[tokenOut], "Token not whitelisted");
        require(amountIn > 0, "AmountIn must be > 0");
        require(minOut > 0, "minOut must be > 0");

        // Transfer tokenIn from user to this contract
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Approve 1inch router
        IERC20(tokenIn).approve(oneInchRouter, 0);
        IERC20(tokenIn).approve(oneInchRouter, amountIn);

        emit SwapForwarded(msg.sender, tokenIn, tokenOut, amountIn, minOut, oneInchData);

        // Call 1inch router
        (returnAmount, spentAmount) = IAggregationRouterV6(oneInchRouter).swap(address(this), oneInchData);
        require(returnAmount >= minOut, "Slippage: amountOut below minOut");

        // Transfer output tokens to user
        IERC20(tokenOut).transfer(msg.sender, returnAmount);

        // Call SwapAuditor
        swapId = ISwapAuditor(swapAuditor).analyzeSwap(msg.sender, amountIn, returnAmount, tokenIn, tokenOut, minOut);
        bool isSafe = ISwapAuditor(swapAuditor).getSwapStatus(swapId);
        emit SwapAudited(swapId, isSafe);
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
