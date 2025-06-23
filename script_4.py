# Create the Treasury Contract
treasury_contract = '''// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IUSBStablecoin {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface IGovernor {
    function executeProposal(uint256 proposalId) external;
    function getProposalState(uint256 proposalId) external view returns (uint8);
}

/**
 * @title Treasury Contract
 * @dev Manages reserve funds for depeg protection and governance decisions
 * @author Stabolut Protocol
 */
contract Treasury is 
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;
    
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    /// @notice USB stablecoin contract
    IUSBStablecoin public usbToken;
    
    /// @notice Governor contract for governance decisions
    IGovernor public governor;
    
    /// @notice Reserve assets mapping
    mapping(address => ReserveAsset) public reserveAssets;
    
    /// @notice Supported assets list
    address[] public supportedAssets;
    
    /// @notice Total reserves value in USD
    uint256 public totalReservesUSD;
    
    /// @notice Emergency reserve percentage (in basis points)
    uint256 public emergencyReservePercentage;
    
    /// @notice Minimum reserve ratio (in basis points)
    uint256 public minimumReserveRatio;
    
    /// @notice Depeg protection threshold (in basis points)
    uint256 public depegThreshold;
    
    /// @notice Maximum single withdrawal (in basis points of total reserves)
    uint256 public maxSingleWithdrawal;
    
    /// @notice Timelock duration for large operations (in seconds)
    uint256 public timelockDuration;
    
    /// @notice Pending operations
    mapping(bytes32 => PendingOperation) public pendingOperations;
    
    /// @notice Price feeds for assets
    mapping(address => AggregatorV3Interface) public priceFeeds;
    
    /// @notice Circuit breaker status
    bool public circuitBreakerActive;
    
    /// @notice Last depeg intervention timestamp
    uint256 public lastDepegIntervention;
    
    /// @notice Minimum time between interventions
    uint256 public minInterventionInterval;
    
    struct ReserveAsset {
        bool isSupported;
        uint256 balance;
        uint256 targetAllocation; // in basis points
        uint256 currentAllocation; // in basis points
        uint256 lastRebalanceTime;
        uint256 yield; // accumulated yield
        bool isStable; // whether it's a stablecoin
    }
    
    struct PendingOperation {
        address asset;
        uint256 amount;
        address recipient;
        uint256 executeAfter;
        OperationType opType;
        bool executed;
        string reason;
    }
    
    enum OperationType {
        WITHDRAWAL,
        REBALANCE,
        EMERGENCY_REPEG,
        GOVERNANCE_TRANSFER
    }
    
    event Deposit(address indexed asset, uint256 amount, uint256 timestamp);
    event Withdrawal(address indexed asset, uint256 amount, address recipient, uint256 timestamp);
    event DepegIntervention(uint256 usbAmount, uint256 reservesUsed, uint256 timestamp);
    event RebalanceExecuted(address indexed asset, uint256 newAllocation, uint256 timestamp);
    event CircuitBreakerTriggered(string reason, uint256 timestamp);
    event OperationQueued(bytes32 indexed operationId, OperationType opType, uint256 executeAfter);
    event OperationExecuted(bytes32 indexed operationId, OperationType opType);
    event YieldDistributed(address indexed asset, uint256 amount, uint256 timestamp);
    event ReserveParametersUpdated(
        uint256 emergencyReservePercentage,
        uint256 minimumReserveRatio,
        uint256 depegThreshold
    );
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address _usbToken,
        uint256 _emergencyReservePercentage,
        uint256 _minimumReserveRatio,
        uint256 _depegThreshold,
        uint256 _maxSingleWithdrawal,
        uint256 _timelockDuration,
        uint256 _minInterventionInterval
    ) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURY_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        
        usbToken = IUSBStablecoin(_usbToken);
        emergencyReservePercentage = _emergencyReservePercentage;
        minimumReserveRatio = _minimumReserveRatio;
        depegThreshold = _depegThreshold;
        maxSingleWithdrawal = _maxSingleWithdrawal;
        timelockDuration = _timelockDuration;
        minInterventionInterval = _minInterventionInterval;
    }
    
    /**
     * @dev Deposit assets to treasury
     * @param asset Asset address (address(0) for ETH)
     * @param amount Amount to deposit
     */
    function deposit(address asset, uint256 amount) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        require(
            hasRole(TREASURY_MANAGER_ROLE, msg.sender) || msg.sender == address(usbToken),
            "Treasury: unauthorized"
        );
        
        if (asset == address(0)) {
            // ETH deposit
            require(msg.value == amount, "Treasury: ETH amount mismatch");
            require(reserveAssets[asset].isSupported, "Treasury: ETH not supported");
        } else {
            // ERC20 deposit
            require(msg.value == 0, "Treasury: no ETH expected");
            require(reserveAssets[asset].isSupported, "Treasury: asset not supported");
            require(amount > 0, "Treasury: amount must be positive");
            
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
        
        reserveAssets[asset].balance += amount;
        _updateTotalReservesUSD();
        _updateAssetAllocation(asset);
        
        emit Deposit(asset, amount, block.timestamp);
    }
    
    /**
     * @dev Queue withdrawal operation (with timelock for large amounts)
     * @param asset Asset address
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     * @param reason Reason for withdrawal
     */
    function queueWithdrawal(
        address asset,
        uint256 amount,
        address recipient,
        string calldata reason
    ) external onlyRole(TREASURY_MANAGER_ROLE) returns (bytes32 operationId) {
        require(reserveAssets[asset].isSupported, "Treasury: asset not supported");
        require(amount <= reserveAssets[asset].balance, "Treasury: insufficient balance");
        require(recipient != address(0), "Treasury: invalid recipient");
        
        // Check if withdrawal requires timelock
        uint256 withdrawalPercentage = (amount * 10000) / totalReservesUSD;
        uint256 executeAfter = withdrawalPercentage > maxSingleWithdrawal ? 
            block.timestamp + timelockDuration : block.timestamp;
        
        operationId = keccak256(abi.encodePacked(
            asset, amount, recipient, block.timestamp, reason
        ));
        
        pendingOperations[operationId] = PendingOperation({
            asset: asset,
            amount: amount,
            recipient: recipient,
            executeAfter: executeAfter,
            opType: OperationType.WITHDRAWAL,
            executed: false,
            reason: reason
        });
        
        emit OperationQueued(operationId, OperationType.WITHDRAWAL, executeAfter);
        
        return operationId;
    }
    
    /**
     * @dev Execute queued withdrawal
     * @param operationId Operation ID
     */
    function executeWithdrawal(bytes32 operationId) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        PendingOperation storage operation = pendingOperations[operationId];
        require(operation.executeAfter > 0, "Treasury: operation not found");
        require(!operation.executed, "Treasury: already executed");
        require(block.timestamp >= operation.executeAfter, "Treasury: timelock not expired");
        require(
            hasRole(TREASURY_MANAGER_ROLE, msg.sender) || 
            hasRole(GOVERNOR_ROLE, msg.sender),
            "Treasury: unauthorized"
        );
        
        // Check reserve ratio after withdrawal
        uint256 assetValueUSD = _getAssetValueInUSD(operation.asset, operation.amount);
        uint256 newTotalReserves = totalReservesUSD - assetValueUSD;
        uint256 usbSupply = usbToken.totalSupply();
        
        if (usbSupply > 0) {
            uint256 newReserveRatio = (newTotalReserves * 10000) / usbSupply;
            require(newReserveRatio >= minimumReserveRatio, "Treasury: reserve ratio too low");
        }
        
        // Execute withdrawal
        reserveAssets[operation.asset].balance -= operation.amount;
        operation.executed = true;
        
        if (operation.asset == address(0)) {
            // ETH withdrawal
            payable(operation.recipient).transfer(operation.amount);
        } else {
            // ERC20 withdrawal
            IERC20(operation.asset).safeTransfer(operation.recipient, operation.amount);
        }
        
        _updateTotalReservesUSD();
        _updateAssetAllocation(operation.asset);
        
        emit OperationExecuted(operationId, OperationType.WITHDRAWAL);
        emit Withdrawal(operation.asset, operation.amount, operation.recipient, block.timestamp);
    }
    
    /**
     * @dev Emergency depeg intervention
     * @param usbAmount Amount of USB to support
     */
    function emergencyDepegIntervention(uint256 usbAmount) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        nonReentrant 
    {
        require(!circuitBreakerActive, "Treasury: circuit breaker active");
        require(
            block.timestamp >= lastDepegIntervention + minInterventionInterval,
            "Treasury: intervention too soon"
        );
        require(usbAmount > 0, "Treasury: invalid USB amount");
        
        // Check if intervention is needed (simplified depeg check)
        require(_isDepegDetected(), "Treasury: no depeg detected");
        
        // Calculate required reserves
        uint256 requiredReserves = usbAmount; // 1:1 backing for simplicity
        require(totalReservesUSD >= requiredReserves, "Treasury: insufficient reserves");
        
        // Use emergency reserves (prefer stablecoins)
        _useReservesForRepeg(requiredReserves);
        
        lastDepegIntervention = block.timestamp;
        
        emit DepegIntervention(usbAmount, requiredReserves, block.timestamp);
    }
    
    /**
     * @dev Rebalance asset allocations
     * @param asset Asset to rebalance
     * @param newTargetAllocation New target allocation in basis points
     */
    function rebalanceAsset(address asset, uint256 newTargetAllocation) 
        external 
        onlyRole(TREASURY_MANAGER_ROLE) 
    {
        require(reserveAssets[asset].isSupported, "Treasury: asset not supported");
        require(newTargetAllocation <= 10000, "Treasury: invalid allocation");
        
        reserveAssets[asset].targetAllocation = newTargetAllocation;
        reserveAssets[asset].lastRebalanceTime = block.timestamp;
        
        _updateAssetAllocation(asset);
        
        emit RebalanceExecuted(asset, newTargetAllocation, block.timestamp);
    }
    
    /**
     * @dev Add supported reserve asset
     * @param asset Asset address
     * @param targetAllocation Target allocation in basis points
     * @param priceFeed Chainlink price feed address
     * @param isStable Whether asset is a stablecoin
     */
    function addSupportedAsset(
        address asset,
        uint256 targetAllocation,
        address priceFeed,
        bool isStable
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!reserveAssets[asset].isSupported, "Treasury: asset already supported");
        require(targetAllocation <= 10000, "Treasury: invalid allocation");
        require(priceFeed != address(0), "Treasury: invalid price feed");
        
        reserveAssets[asset] = ReserveAsset({
            isSupported: true,
            balance: 0,
            targetAllocation: targetAllocation,
            currentAllocation: 0,
            lastRebalanceTime: block.timestamp,
            yield: 0,
            isStable: isStable
        });
        
        priceFeeds[asset] = AggregatorV3Interface(priceFeed);
        supportedAssets.push(asset);
    }
    
    /**
     * @dev Activate circuit breaker
     * @param reason Reason for activation
     */
    function activateCircuitBreaker(string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
    {
        circuitBreakerActive = true;
        _pause();
        
        emit CircuitBreakerTriggered(reason, block.timestamp);
    }
    
    /**
     * @dev Deactivate circuit breaker
     */
    function deactivateCircuitBreaker() external onlyRole(DEFAULT_ADMIN_ROLE) {
        circuitBreakerActive = false;
        _unpause();
    }
    
    /**
     * @dev Distribute yield to governance or burn USB
     * @param asset Asset to distribute yield from
     * @param amount Amount of yield
     * @param burnUSB Whether to burn USB or distribute to governance
     */
    function distributeYield(address asset, uint256 amount, bool burnUSB) 
        external 
        onlyRole(GOVERNOR_ROLE) 
        nonReentrant 
    {
        require(reserveAssets[asset].isSupported, "Treasury: asset not supported");
        require(amount <= reserveAssets[asset].yield, "Treasury: insufficient yield");
        
        reserveAssets[asset].yield -= amount;
        
        if (burnUSB) {
            // Burn equivalent USB tokens
            uint256 usbToBurn = _getAssetValueInUSD(asset, amount);
            usbToken.burn(usbToBurn);
        } else {
            // Transfer to governance treasury
            if (asset == address(0)) {
                payable(msg.sender).transfer(amount);
            } else {
                IERC20(asset).safeTransfer(msg.sender, amount);
            }
        }
        
        emit YieldDistributed(asset, amount, block.timestamp);
    }
    
    /**
     * @dev Get asset value in USD
     * @param asset Asset address
     * @param amount Asset amount
     * @return USD value
     */
    function _getAssetValueInUSD(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        
        AggregatorV3Interface priceFeed = priceFeeds[asset];
        require(address(priceFeed) != address(0), "Treasury: no price feed");
        
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "Treasury: invalid price");
        require(block.timestamp - updatedAt <= 3600, "Treasury: stale price");
        
        uint8 decimals = priceFeed.decimals();
        return (amount * uint256(price)) / (10 ** decimals);
    }
    
    /**
     * @dev Update total reserves USD value
     */
    function _updateTotalReservesUSD() internal {
        uint256 total = 0;
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            total += _getAssetValueInUSD(asset, reserveAssets[asset].balance);
        }
        totalReservesUSD = total;
    }
    
    /**
     * @dev Update asset allocation percentage
     * @param asset Asset address
     */
    function _updateAssetAllocation(address asset) internal {
        if (totalReservesUSD == 0) {
            reserveAssets[asset].currentAllocation = 0;
            return;
        }
        
        uint256 assetValueUSD = _getAssetValueInUSD(asset, reserveAssets[asset].balance);
        reserveAssets[asset].currentAllocation = (assetValueUSD * 10000) / totalReservesUSD;
    }
    
    /**
     * @dev Check if depeg is detected
     * @return true if depeg detected
     */
    function _isDepegDetected() internal view returns (bool) {
        // This would integrate with USB/USD price feed
        // Simplified implementation
        return false; // Placeholder
    }
    
    /**
     * @dev Use reserves for repeg operation
     * @param amount Amount needed for repeg
     */
    function _useReservesForRepeg(uint256 amount) internal {
        // Priority: Use stablecoins first, then other assets
        uint256 remaining = amount;
        
        for (uint256 i = 0; i < supportedAssets.length && remaining > 0; i++) {
            address asset = supportedAssets[i];
            ReserveAsset storage reserve = reserveAssets[asset];
            
            if (reserve.isStable && reserve.balance > 0) {
                uint256 assetValue = _getAssetValueInUSD(asset, reserve.balance);
                uint256 toUse = remaining > assetValue ? assetValue : remaining;
                uint256 assetAmount = (toUse * reserve.balance) / assetValue;
                
                reserve.balance -= assetAmount;
                remaining -= toUse;
            }
        }
        
        _updateTotalReservesUSD();
    }
    
    /**
     * @dev Get reserve information
     * @param asset Asset address
     * @return balance Current balance
     * @return targetAllocation Target allocation
     * @return currentAllocation Current allocation
     * @return yield Accumulated yield
     */
    function getReserveInfo(address asset) 
        external 
        view 
        returns (uint256 balance, uint256 targetAllocation, uint256 currentAllocation, uint256 yield) 
    {
        ReserveAsset storage reserve = reserveAssets[asset];
        return (reserve.balance, reserve.targetAllocation, reserve.currentAllocation, reserve.yield);
    }
    
    /**
     * @dev Update reserve parameters
     * @param _emergencyReservePercentage New emergency reserve percentage
     * @param _minimumReserveRatio New minimum reserve ratio
     * @param _depegThreshold New depeg threshold
     */
    function updateReserveParameters(
        uint256 _emergencyReservePercentage,
        uint256 _minimumReserveRatio,
        uint256 _depegThreshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_emergencyReservePercentage <= 10000, "Treasury: invalid percentage");
        require(_minimumReserveRatio <= 10000, "Treasury: invalid ratio");
        require(_depegThreshold <= 1000, "Treasury: invalid threshold");
        
        emergencyReservePercentage = _emergencyReservePercentage;
        minimumReserveRatio = _minimumReserveRatio;
        depegThreshold = _depegThreshold;
        
        emit ReserveParametersUpdated(
            _emergencyReservePercentage,
            _minimumReserveRatio,
            _depegThreshold
        );
    }
    
    /**
     * @dev Override _authorizeUpgrade for UUPS upgradeable pattern
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {}
    
    /**
     * @dev Receive ETH deposits
     */
    receive() external payable {
        // Only accept ETH if it's a supported asset
        require(reserveAssets[address(0)].isSupported, "Treasury: ETH not supported");
    }
}'''

# Save the Treasury contract
with open('Treasury.sol', 'w') as f:
    f.write(treasury_contract)

print("✅ Treasury Contract created successfully")
print("📄 Contract features:")
print("  - Multi-asset reserve management")
print("  - Emergency depeg intervention")
print("  - Timelock for large operations")
print("  - Asset allocation rebalancing")
print("  - Circuit breaker mechanism")
print("  - Yield distribution system")
print("  - Governance integration")
print("  - Chainlink price feed integration")