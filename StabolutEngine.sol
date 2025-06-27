// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./Timelock.sol";

interface IUSBStablecoin {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function getUSDPrice() external view returns (uint256);
}

interface ITreasury {
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount, address to) external;
    function getReserveBalance(address token) external view returns (uint256);
}

interface IDeltaNeutralStrategy {
    function deposit(address token, uint256 amount) external returns (uint256 yield);
    function withdraw(uint256 amount, address to) external returns (uint256 actualAmount);
    function getPositionValue() external view returns (uint256);
    function closePosition() external returns (uint256 totalValue);
}

/**
 * @title Stabolut Engine
 * @dev Main engine contract that handles delta neutral strategies and USB minting/burning
 * @author Stabolut Protocol
 */
contract StabolutEngine is 
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    bytes32 public constant KYC_ADMIN_ROLE = keccak256("KYC_ADMIN_ROLE");

    /// @notice Timelock contract
    Timelock public timelock;

    /// @notice USB Stablecoin contract
    IUSBStablecoin public usbToken;
    
    /// @notice KYC verified users
    mapping(address => bool) public isKycVerified;

    /// @notice Treasury contract
    ITreasury public treasury;

    /// @notice Delta neutral strategy contract
    IDeltaNeutralStrategy public deltaNeutralStrategy;

    /// @notice Supported collateral tokens
    mapping(address => CollateralInfo) public supportedTokens;

    /// @notice User deposits tracking
    mapping(address => UserDeposit) public userDeposits;

    /// @notice Chainlink price feeds for collateral tokens
    mapping(address => AggregatorV3Interface) public priceFeeds;

    /// @notice Minimum collateralization ratio (in basis points)
    uint256 public constant MIN_COLLATERAL_RATIO = 15000; // 150%

    /// @notice Maximum slippage tolerance (in basis points)
    uint256 public constant MAX_SLIPPAGE = 300; // 3%

    /// @notice Depeg threshold (in basis points)
    uint256 public constant DEPEG_THRESHOLD = 500; // 5%

    /// @notice Emergency pause threshold
    uint256 public emergencyThreshold;

    /// @notice Total value locked in delta neutral strategies
    uint256 public totalValueLocked;

    /// @notice Total yield generated
    uint256 public totalYieldGenerated;

    /// @notice Treasury yield percentage (in basis points)
    uint256 public treasuryYieldPercentage;

    struct CollateralInfo {
        bool isSupported;
        uint256 minDepositAmount;
        uint256 maxDepositAmount;
        uint256 liquidationThreshold;
        uint256 stabilityFee;
    }

    struct UserDeposit {
        uint256 totalDeposited;
        uint256 usbMinted;
        uint256 lastUpdateTimestamp;
        address[] collateralTokens;
        mapping(address => uint256) collateralAmounts;
    }

    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 usbMinted,
        uint256 timestamp
    );

    event Withdrawal(
        address indexed user,
        address indexed token,
        uint256 usbBurned,
        uint256 amountWithdrawn,
        uint256 timestamp
    );

    event YieldGenerated(
        uint256 amount,
        uint256 treasuryAmount,
        uint256 timestamp
    );

    event EmergencyPause(
        string reason,
        uint256 timestamp
    );

    event CollateralAdded(
        address indexed token,
        uint256 minDeposit,
        uint256 maxDeposit,
        uint256 liquidationThreshold
    );

    event ParametersUpdated(
        uint256 treasuryYieldPercentage,
        uint256 emergencyThreshold
    );

    event TimelockUpdated(address newTimelock);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usbToken,
        address _treasury,
        address _deltaNeutralStrategy,
        uint256 _treasuryYieldPercentage,
        uint256 _emergencyThreshold,
        address _timelock
    ) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(TIMELOCK_ADMIN_ROLE, msg.sender);
        _grantRole(KYC_ADMIN_ROLE, msg.sender);

        usbToken = IUSBStablecoin(_usbToken);
        treasury = ITreasury(_treasury);
        deltaNeutralStrategy = IDeltaNeutralStrategy(_deltaNeutralStrategy);
        treasuryYieldPercentage = _treasuryYieldPercentage;
        emergencyThreshold = _emergencyThreshold;
        timelock = Timelock(_timelock);
    }

    /**
     * @dev Deposit crypto and mint USB tokens using delta neutral strategy
     * @param token Address of the token to deposit
     * @param amount Amount of tokens to deposit
     */
    function deposit(address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        // Checks
        require(isKycVerified[msg.sender], "Engine: KYC not verified");
        require(supportedTokens[token].isSupported, "Engine: token not supported");
        require(amount >= supportedTokens[token].minDepositAmount, "Engine: amount too small");
        require(amount <= supportedTokens[token].maxDepositAmount, "Engine: amount too large");
        
        uint256 usdValue = _getTokenValueInUSD(token, amount);
        require(usdValue > 0, "Engine: invalid price");

        // Check for depeg protection
        require(!_isDepegged(), "Engine: depeg detected, deposits paused");
        
        // Effects
        uint256 usbToMint = (usdValue * 10000) / MIN_COLLATERAL_RATIO;

        UserDeposit storage userDeposit = userDeposits[msg.sender];
        userDeposit.totalDeposited += amount;
        userDeposit.usbMinted += usbToMint;
        userDeposit.lastUpdateTimestamp = block.timestamp;
        userDeposit.collateralAmounts[token] += amount;

        // Add token to user's collateral list if not already present
        bool tokenExists = false;
        for (uint i = 0; i < userDeposit.collateralTokens.length; i++) {
            if (userDeposit.collateralTokens[i] == token) {
                tokenExists = true;
                break;
            }
        }
        if (!tokenExists) {
            require(userDeposit.collateralTokens.length < MAX_COLLATERAL_TYPES_PER_USER, "Engine: max collateral types reached");
            userDeposit.collateralTokens.push(token);
        }

        totalValueLocked += usdValue;

        // Interactions
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).safeApprove(address(deltaNeutralStrategy), amount);
        uint256 yieldGenerated = deltaNeutralStrategy.deposit(token, amount);
        totalYieldGenerated += yieldGenerated;
        _distributeYield(token, yieldGenerated);
        usbToken.mint(msg.sender, usbToMint);

        emit Deposit(msg.sender, token, amount, usbToMint, block.timestamp);
    }

    /**
     * @dev Withdraw crypto by burning USB tokens
     * @param token Address of the token to withdraw
     * @param usbAmount Amount of USB tokens to burn
     * @param minAmountOut Minimum amount of tokens to receive
     */
    function withdraw(address token, uint256 usbAmount, uint256 minAmountOut) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        // Checks
        require(supportedTokens[token].isSupported, "Engine: token not supported");
        require(usbAmount > 0, "Engine: amount must be positive");

        UserDeposit storage userDeposit = userDeposits[msg.sender];
        require(userDeposit.usbMinted >= usbAmount, "Engine: insufficient USB balance");
        require(userDeposit.collateralAmounts[token] > 0, "Engine: no collateral for token");

        uint256 usdValue = (usbAmount * MIN_COLLATERAL_RATIO) / 10000;
        uint256 tokenAmount = _getUSDValueInToken(token, usdValue);

        require(tokenAmount <= userDeposit.collateralAmounts[token], "Engine: insufficient collateral");

        uint256 remainingUSD = userDeposit.usbMinted - usbAmount;
        if (remainingUSD > 0) {
            uint256 remainingCollateralValue = _getUserTotalCollateralValue(msg.sender) - usdValue;
            uint256 collateralRatio = (remainingCollateralValue * 10000) / remainingUSD;
            require(collateralRatio >= MIN_COLLATERAL_RATIO, "Engine: insufficient collateralization");
        }

        // Effects
        userDeposit.usbMinted -= usbAmount;
        userDeposit.collateralAmounts[token] -= tokenAmount;
        userDeposit.lastUpdateTimestamp = block.timestamp;
        totalValueLocked -= usdValue;

        // Interactions
        usbToken.burnFrom(msg.sender, usbAmount);
        uint256 actualAmount = deltaNeutralStrategy.withdraw(tokenAmount, msg.sender);
        require(actualAmount >= minAmountOut, "Engine: slippage exceeded");

        emit Withdrawal(msg.sender, token, usbAmount, actualAmount, block.timestamp);
    }

    /**
     * @dev Distribute yield between treasury and users
     * @param yieldAmount Amount of yield to distribute
     */
    function _distributeYield(address yieldToken, uint256 yieldAmount) internal {
        if (yieldAmount == 0) return;

        uint256 treasuryAmount = (yieldAmount * treasuryYieldPercentage) / 10000;

        if (treasuryAmount > 0) {
            // Transfer yield to treasury
            IERC20(yieldToken).safeTransfer(address(treasury), treasuryAmount);
            treasury.deposit(yieldToken, treasuryAmount);
        }

        emit YieldGenerated(yieldAmount, treasuryAmount, block.timestamp);
    }

    /**
     * @dev Get token value in USD using Chainlink price feed
     * @param token Token address
     * @param amount Token amount
     * @return usdValue Value in USD (18 decimals)
     */
    function _getTokenValueInUSD(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        require(address(priceFeed) != address(0), "Engine: no price feed");

        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "Engine: invalid price");
        require(block.timestamp - updatedAt <= 900, "Engine: stale price"); // 15 minutes max

        uint8 decimals = priceFeed.decimals();
        uint256 usdValue = (amount * uint256(price)) / (10 ** decimals);

        return usdValue;
    }

    /**
     * @dev Get USD value in token amount
     * @param token Token address
     * @param usdValue USD value
     * @return tokenAmount Token amount
     */
    function _getUSDValueInToken(address token, uint256 usdValue) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        require(address(priceFeed) != address(0), "Engine: no price feed");

        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "Engine: invalid price");
        require(block.timestamp - updatedAt <= 900, "Engine: stale price"); // 15 minutes max

        uint8 decimals = priceFeed.decimals();
        uint256 tokenAmount = (usdValue * (10 ** decimals)) / uint256(price);

        return tokenAmount;
    }

    /**
     * @dev Get user's total collateral value in USD
     * @param user User address
     * @return totalValue Total collateral value in USD
     */
    function _getUserTotalCollateralValue(address user) internal view returns (uint256) {
        UserDeposit storage userDeposit = userDeposits[user];
        uint256 totalValue = 0;

        for (uint i = 0; i < userDeposit.collateralTokens.length; i++) {
            address token = userDeposit.collateralTokens[i];
            uint256 amount = userDeposit.collateralAmounts[token];
            if (amount > 0) {
                totalValue += _getTokenValueInUSD(token, amount);
            }
        }

        return totalValue;
    }

    /**
     * @dev Check if USB is depegged
     * @return true if depegged
     */
    function _isDepegged() internal view returns (bool) {
        uint256 usbPrice = usbToken.getUSDPrice();
        uint256 oneDollar = 10**18;
        uint256 priceDifference = usbPrice > oneDollar ? usbPrice - oneDollar : oneDollar - usbPrice;
        return (priceDifference * 10000) / oneDollar > DEPEG_THRESHOLD;
    }

    /**
     * @dev Add supported collateral token
     * @param token Token address
     * @param minDeposit Minimum deposit amount
     * @param maxDeposit Maximum deposit amount
     * @param liquidationThreshold Liquidation threshold
     * @param stabilityFee Stability fee
     * @param priceFeed Chainlink price feed address
     */
    function addSupportedToken(
        address token,
        uint256 minDeposit,
        uint256 maxDeposit,
        uint256 liquidationThreshold,
        uint256 stabilityFee,
        address priceFeed
    ) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(token != address(0), "Engine: invalid token");
        require(priceFeed != address(0), "Engine: invalid price feed");
        require(maxDeposit > minDeposit, "Engine: invalid deposit limits");

        supportedTokens[token] = CollateralInfo({
            isSupported: true,
            minDepositAmount: minDeposit,
            maxDepositAmount: maxDeposit,
            liquidationThreshold: liquidationThreshold,
            stabilityFee: stabilityFee
        });

        priceFeeds[token] = AggregatorV3Interface(priceFeed);

        emit CollateralAdded(token, minDeposit, maxDeposit, liquidationThreshold);
    }

    /**
     * @dev Update system parameters
     * @param _treasuryYieldPercentage New treasury yield percentage
     * @param _emergencyThreshold New emergency threshold
     */
    function updateParameters(
        uint256 _treasuryYieldPercentage,
        uint256 _emergencyThreshold
    ) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_treasuryYieldPercentage <= 10000, "Engine: invalid yield percentage");

        treasuryYieldPercentage = _treasuryYieldPercentage;
        emergencyThreshold = _emergencyThreshold;

        emit ParametersUpdated(_treasuryYieldPercentage, _emergencyThreshold);
    }
    
    /**
     * @dev Set the KYC status for a user
     * @param user The address of the user
     * @param status The KYC status
     */
    function setKycStatus(address user, bool status) external onlyRole(KYC_ADMIN_ROLE) {
        isKycVerified[user] = status;
    }

    /**
     * @dev Update timelock contract
     * @param _timelock New timelock contract address
     */
    function setTimelock(address _timelock) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_timelock != address(0), "Engine: invalid timelock");
        timelock = Timelock(_timelock);
        emit TimelockUpdated(_timelock);
    }

    /**
     * @dev Emergency pause function
     * @param reason Reason for emergency pause
     */
    function emergencyPause(string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyPause(reason, block.timestamp);
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Get user deposit information
     * @param user User address
     * @return totalDeposited Total deposited amount
     * @return usbMinted Total USB minted
     * @return lastUpdate Last update timestamp
     */
    function getUserDepositInfo(address user) 
        external 
        view 
        returns (uint256 totalDeposited, uint256 usbMinted, uint256 lastUpdate) 
    {
        UserDeposit storage userDeposit = userDeposits[user];
        return (userDeposit.totalDeposited, userDeposit.usbMinted, userDeposit.lastUpdateTimestamp);
    }

    /**
     * @dev Override _authorizeUpgrade for UUPS upgradeable pattern
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {}
}