// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Timelock.sol";

/**
 * @title USB Stablecoin
 * @dev Stablecoin token with minting/burning capabilities based on delta neutral strategies
 * @author Stabolut Protocol
 */
contract USBStablecoin is 
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    /// @notice Timelock contract
    Timelock public timelock;

    /// @notice Emergency circuit breaker threshold (in basis points)
    uint256 public constant CIRCUIT_BREAKER_THRESHOLD = 1000; // 10%

    /// @notice Maximum supply cap
    uint256 public maxSupply;

    /// @notice Stabolut Engine contract address
    address public stabolutEngine;

    /// @notice Last block number when minting occurred
    uint256 public lastMintBlock;

    /// @notice Minting rate limit per block
    uint256 public mintingRateLimit;

    /// @notice Total minted in current block
    uint256 public currentBlockMinted;

    /// @notice Chainlink price feed for USB/USD
    AggregatorV3Interface public usdPriceFeed;

    event MaxSupplyUpdated(uint256 newMaxSupply);
    event MintingRateLimitUpdated(uint256 newRateLimit);
    event StabolutEngineUpdated(address newEngine);
    event CircuitBreakerTriggered(uint256 amount, uint256 threshold);
    event TimelockUpdated(address newTimelock);
    event USDPriceFeedUpdated(address newPriceFeed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        uint256 _maxSupply,
        uint256 _mintingRateLimit,
        address _stabolutEngine,
        address _timelock,
        address _usdPriceFeed
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(TIMELOCK_ADMIN_ROLE, msg.sender);

        maxSupply = _maxSupply;
        mintingRateLimit = _mintingRateLimit;
        stabolutEngine = _stabolutEngine;
        timelock = Timelock(_timelock);
        usdPriceFeed = AggregatorV3Interface(_usdPriceFeed);

        // Grant minter role to Stabolut Engine
        _grantRole(MINTER_ROLE, _stabolutEngine);
    }

    /**
     * @dev Mint new USB tokens with rate limiting and circuit breaker
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) 
        external 
        onlyRole(MINTER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        require(to != address(0), "USB: mint to zero address");
        require(amount > 0, "USB: amount must be positive");
        require(totalSupply() + amount <= maxSupply, "USB: exceeds max supply");

        // Rate limiting check
        if (block.number != lastMintBlock) {
            lastMintBlock = block.number;
            currentBlockMinted = 0;
        }

        require(
            currentBlockMinted + amount <= mintingRateLimit,
            "USB: exceeds minting rate limit"
        );

        // Circuit breaker check
        if (totalSupply() > 0) {
            uint256 supplyIncreasePercentage = (amount * 10000) / totalSupply();
            if (supplyIncreasePercentage > CIRCUIT_BREAKER_THRESHOLD) {
                emit CircuitBreakerTriggered(amount, CIRCUIT_BREAKER_THRESHOLD);
                revert("USB: circuit breaker triggered");
            }
        }

        currentBlockMinted += amount;
        _mint(to, amount);
    }

    /**
     * @dev Burn tokens when user withdraws from delta neutral strategy
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) 
        public 
        override
    {
        require(msg.sender == stabolutEngine, "USB: only engine can burn");
        require(from != address(0), "USB: burn from zero address");
        require(amount > 0, "USB: amount must be positive");
        require(balanceOf(from) >= amount, "USB: insufficient balance");

        _burn(from, amount);
    }

    /**
     * @dev Set maximum supply
     * @param _maxSupply New maximum supply
     */
    function setMaxSupply(uint256 _maxSupply) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_maxSupply >= totalSupply(), "USB: max supply too low");
        maxSupply = _maxSupply;
        emit MaxSupplyUpdated(_maxSupply);
    }

    /**
     * @dev Set minting rate limit
     * @param _mintingRateLimit New minting rate limit per block
     */
    function setMintingRateLimit(uint256 _mintingRateLimit) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        mintingRateLimit = _mintingRateLimit;
        emit MintingRateLimitUpdated(_mintingRateLimit);
    }

    /**
     * @dev Update Stabolut Engine address
     * @param _stabolutEngine New engine address
     */
    function setStabolutEngine(address _stabolutEngine) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_stabolutEngine != address(0), "USB: invalid engine address");

        // Revoke role from old engine
        if (stabolutEngine != address(0)) {
            _revokeRole(MINTER_ROLE, stabolutEngine);
        }

        stabolutEngine = _stabolutEngine;
        _grantRole(MINTER_ROLE, _stabolutEngine);

        emit StabolutEngineUpdated(_stabolutEngine);
    }

    /**
     * @dev Update timelock contract
     * @param _timelock New timelock contract address
     */
    function setTimelock(address _timelock) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_timelock != address(0), "USB: invalid timelock");
        timelock = Timelock(_timelock);
        emit TimelockUpdated(_timelock);
    }

    /**
     * @dev Update USD price feed address
     * @param _usdPriceFeed New USD price feed address
     */
    function setUSDPriceFeed(address _usdPriceFeed) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_usdPriceFeed != address(0), "USB: invalid price feed");
        usdPriceFeed = AggregatorV3Interface(_usdPriceFeed);
        emit USDPriceFeedUpdated(_usdPriceFeed);
    }

    /**
     * @dev Get the latest USD price of the stablecoin
     * @return The price of the stablecoin in USD with 18 decimals
     */
    function getUSDPrice() external view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = usdPriceFeed.latestRoundData();
        require(price > 0, "USB: invalid price");
        require(block.timestamp - updatedAt <= 900, "USB: stale price"); // 15 minutes max
        return uint256(price);
    }

    /**
     * @dev Pause contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Override _beforeTokenTransfer to add pausable functionality
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
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
     * @dev Returns the number of decimals used to get its user representation
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}