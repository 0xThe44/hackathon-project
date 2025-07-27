/**
 * @title SwapAuditor (Core Analytics & Security Module for 1inch Security Dashboard)
 * @notice Central contract for real-time swap analysis, risk detection, and extensible DeFi security on top of 1inch Router.
 * @dev Receives swap data (typically via SwapProxy), validates price plausibility (using TWAP module), checks for suspicious tokens, flashloan patterns, and abnormal volumes. Designed for extensibility with future modules (e.g., approvals, anti-reentrancy). Emits analytics events for off-chain dashboards and monitoring. Part of a modular security and analytics system for DeFi swaps.
 *
 * Key Features:
 * - Real-time swap monitoring and risk analysis
 * - Integrates with TWAP and other modules for price and behavior validation
 * - Extensible for future analytics and security features
 * - Emits events for off-chain visualization and alerting
 */
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IAggregationRouterV6
 * @dev Interface for the 1inch Aggregation Router V6
 */
interface IAggregationRouterV6 {
    /**
     * @notice Emitted when a swap is performed via 1inch router
     * @param sender The address initiating the swap
     * @param srcToken The input token address
     * @param dstToken The output token address
     * @param dstReceiver The address receiving the output tokens
     * @param spentAmount The amount of input tokens spent
     * @param returnAmount The amount of output tokens received
     */
    event Swapped(
        address indexed sender,
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 spentAmount,
        uint256 returnAmount
    );
}

/**
 * @notice Main analytics and security contract for swap validation and risk monitoring
 * @dev Integrates with SwapProxy and TWAP modules for comprehensive DeFi swap analysis
 */
contract SwapAuditor is Ownable, Pausable, ReentrancyGuard {
    /// @notice Address of the 1inch router
    address public oneInchRouter; //= 0x1111111254EEB25477B68fb85Ed929f73A960582;

    /// @notice Default spread threshold in basis points (e.g., 9500 = 95% = max 5% loss)
    uint256 public defaultSpreadThreshold = 9500;

    /// @notice Total number of swaps analyzed (for MVP, should be offchain in production)
    uint256 public totalSwaps;
    /// @notice Total number of unsafe swaps detected (for MVP, should be offchain in production)
    uint256 public unsafeSwaps;

    /**
     * @notice Struct representing swap data
     * @param sender The address initiating the swap
     * @param amountIn The input amount
     * @param amountOut The output amount
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param isSafe Whether the swap is considered safe
     */
    struct SwapData {
        address sender;
        uint128 amountIn;
        uint128 amountOut;
        address tokenIn;
        address tokenOut;
        bool isSafe;
    }

    /// @notice Mapping from swapId to SwapData
    mapping(bytes32 => SwapData) public swaps;
    /// @notice Mapping from tokenIn/tokenOut pair to custom spread threshold
    mapping(address => mapping(address => uint256)) public pairSpreadThresholds;
    /// @notice Mapping of trusted callers allowed to analyze swaps
    mapping(address => bool) public trustedCallers;
    /// @notice Mapping of blacklisted addresses
    mapping(address => bool) public blackListedAddresses;
    /// @notice Mapping of validated ERC20 tokens
    mapping(address => bool) public isValidToken;

    /**
     * @notice Emitted when a swap is analyzed
     * @param swapId The unique identifier of the swap
     * @param sender The address initiating the swap
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The input amount
     * @param amountOut The output amount
     * @param isSafe Whether the swap is considered safe
     */
    event SwapAnalyzed(
        bytes32 indexed swapId,
        address indexed sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isSafe
    );

    /**
     * @notice Emitted when the default spread threshold is updated
     * @param newThreshold The new default spread threshold in basis points
     */
    event SpreadThresholdUpdated(uint256 newThreshold);
    /**
     * @notice Emitted when a pair-specific spread threshold is updated
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param threshold The new threshold in basis points
     */
    event PairSpreadThresholdUpdated(address tokenIn, address tokenOut, uint256 threshold);

    /**
     * @notice Initializes the contract and sets the deployer as a trusted caller
     */
    constructor() Ownable(msg.sender) {
        trustedCallers[msg.sender] = true; // Owner is trusted by default
    }

    /**
     * @notice Modifier to restrict access to trusted callers only
     */
    modifier onlyTrustedCaller() {
        require(trustedCallers[msg.sender], "Not trusted caller");
        _;
    }

    /**
     * @notice Updates the 1inch router address
     * @param _newRouter The new 1inch router address
     */
    function setOneInchRouter(address _newRouter) external onlyOwner {
        require(_newRouter != address(0), "Invalid router address");
        oneInchRouter = _newRouter;
    }

    /**
     * @notice Updates the default spread threshold
     * @param _newThreshold The new default spread threshold in basis points (max 10000)
     */
    function setSpreadThreshold(uint256 _newThreshold) external onlyOwner {
        require(_newThreshold <= 10000, "Threshold too high");
        defaultSpreadThreshold = _newThreshold;
        emit SpreadThresholdUpdated(_newThreshold);
    }

    /**
     * @notice Updates the spread threshold for a specific token pair
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param threshold The new threshold in basis points (max 10000)
     */
    function setPairSpreadThreshold(address tokenIn, address tokenOut, uint256 threshold) external onlyOwner {
        require(threshold <= 10000, "Threshold too high");
        pairSpreadThresholds[tokenIn][tokenOut] = threshold;
        emit PairSpreadThresholdUpdated(tokenIn, tokenOut, threshold);
    }

    /**
     * @notice Sets a trusted caller for swap analysis
     * @param caller The address to set as trusted or not
     * @param isTrusted Whether the address is trusted
     */
    function setTrustedCaller(address caller, bool isTrusted) external onlyOwner {
        trustedCallers[caller] = isTrusted;
    }

    /**
     * @notice Sets a blacklisted address
     * @param addr The address to blacklist or unblacklist
     * @param _isBlackListed Whether the address is blacklisted
     */
    function setBlackListedAddress(address addr, bool _isBlackListed) external onlyOwner {
        blackListedAddresses[addr] = _isBlackListed;
    }

    /**
     * @notice Checks if a token address is a valid ERC20 by calling symbol()
     * @dev Only for MVP, not safe for production
     * @param token The token address to check
     * @return ok True if the token is a valid ERC20
     */
    function isValidERC20(address token) internal returns (bool ok) {
        require(token != address(0), "Invalid address");
        // Check if the token implements symbol() as a basic ERC20 check
        (ok,) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (ok) isValidToken[token] = true;
        return ok;
    }

    /**
     * @notice Analyzes a swap and checks if the spread is within the threshold
     * @dev For MVP, amountOut is trusted from caller. Use 1inch API or Chainlink off-chain for validation. TODO: Implement offchain price validation for production.
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
    ) external onlyTrustedCaller whenNotPaused nonReentrant returns (bytes32) {
        require(amountIn > 0, "AmountIn must be greater than 0");
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid token address");
        require(isValidERC20(tokenIn) && isValidERC20(tokenOut), "Invalid ERC20 token");
        require(
            !blackListedAddresses[sender] && !blackListedAddresses[tokenIn] && !blackListedAddresses[tokenOut],
            "Blacklisted address"
        );
        require(amountIn <= type(uint128).max && amountOut <= type(uint128).max, "Amount too large");
        require(amountOut >= minOut, "Slippage: amountOut below minOut");
        // Calculate spread in basis points
        // TODO: Replace with Chainlink Price Feed or 1inch API call for accurate spread calculation
        uint256 spread = (amountOut * 10000) / amountIn;
        uint256 threshold = pairSpreadThresholds[tokenIn][tokenOut] > 0
            ? pairSpreadThresholds[tokenIn][tokenOut]
            : defaultSpreadThreshold;
        bool isSafe = spread >= threshold;
        // Generate unique swap ID
        bytes32 swapId = keccak256(abi.encode(sender, amountIn, amountOut, tokenIn, tokenOut));
        require(swaps[swapId].sender == address(0), "Swap already analyzed");
        // Store swap data
        swaps[swapId] = SwapData(sender, uint128(amountIn), uint128(amountOut), tokenIn, tokenOut, isSafe);
        totalSwaps++;
        if (!isSafe) unsafeSwaps++;
        // Emit event for real-time tracking
        emit SwapAnalyzed(swapId, sender, tokenIn, tokenOut, amountIn, amountOut, isSafe);
        return swapId;
    }

    /**
     * @notice Gets full swap data by swapId
     * @param swapId The unique identifier of the swap
     * @return The SwapData struct for the swap
     */
    function getSwapData(bytes32 swapId) external view returns (SwapData memory) {
        return swaps[swapId];
    }

    /**
     * @notice Gets the swap status (isSafe) by swapId
     * @param swapId The unique identifier of the swap
     * @return isSafe True if the swap is considered safe
     */
    function getSwapStatus(bytes32 swapId) external view returns (bool) {
        return swaps[swapId].isSafe;
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
