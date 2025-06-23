// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISBLGovernanceToken {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

/**
 * @title Staking Contract
 * @dev Allows USB holders to stake tokens and receive SBL governance tokens
 * @author Stabolut Protocol
 */
contract StakingContract is 
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice USB token contract
    IERC20 public usbToken;

    /// @notice SBL governance token contract
    ISBLGovernanceToken public sblToken;

    /// @notice Staking pools information
    mapping(uint256 => PoolInfo) public poolInfo;

    /// @notice User staking information
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    /// @notice Total number of pools
    uint256 public poolLength;

    /// @notice SBL tokens per block
    uint256 public sblPerBlock;

    /// @notice Start block for rewards
    uint256 public startBlock;

    /// @notice Bonus end block
    uint256 public bonusEndBlock;

    /// @notice Bonus multiplier
    uint256 public bonusMultiplier;

    /// @notice Total allocation points
    uint256 public totalAllocPoint;

    /// @notice Minimum staking period (in blocks)
    uint256 public minimumStakingPeriod;

    /// @notice Early withdrawal penalty (in basis points)
    uint256 public earlyWithdrawalPenalty;

    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract
        uint256 allocPoint;       // Allocation points assigned to this pool
        uint256 lastRewardBlock;  // Last block number that SBLs distribution occurs
        uint256 accSblPerShare;   // Accumulated SBLs per share, times 1e12
        uint256 depositFeeBP;     // Deposit fee in basis points
        uint256 totalStaked;      // Total amount staked in this pool
        uint256 minStakeAmount;   // Minimum stake amount
        uint256 maxStakeAmount;   // Maximum stake amount per user
        bool isActive;            // Whether the pool is active
    }

    struct UserInfo {
        uint256 amount;           // How many LP tokens the user has provided
        uint256 rewardDebt;       // Reward debt
        uint256 lastStakeTime;    // Timestamp of last stake
        uint256 pendingRewards;   // Pending rewards not yet claimed
        uint256 totalRewardsClaimed; // Total rewards claimed by user
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 indexed pid, uint256 allocPoint, address lpToken, uint256 depositFeeBP);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint, uint256 depositFeeBP);
    event RewardRateUpdated(uint256 newSblPerBlock);
    event BonusParametersUpdated(uint256 bonusEndBlock, uint256 bonusMultiplier);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usbToken,
        address _sblToken,
        uint256 _sblPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        uint256 _bonusMultiplier,
        uint256 _minimumStakingPeriod,
        uint256 _earlyWithdrawalPenalty
    ) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        usbToken = IERC20(_usbToken);
        sblToken = ISBLGovernanceToken(_sblToken);
        sblPerBlock = _sblPerBlock;
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
        bonusMultiplier = _bonusMultiplier;
        minimumStakingPeriod = _minimumStakingPeriod;
        earlyWithdrawalPenalty = _earlyWithdrawalPenalty;
    }

    /**
     * @dev Add a new staking pool
     * @param _allocPoint Allocation points for this pool
     * @param _lpToken LP token contract address
     * @param _depositFeeBP Deposit fee in basis points
     * @param _minStakeAmount Minimum stake amount
     * @param _maxStakeAmount Maximum stake amount per user
     * @param _withUpdate Whether to update all pools
     */
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint256 _depositFeeBP,
        uint256 _minStakeAmount,
        uint256 _maxStakeAmount,
        bool _withUpdate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_depositFeeBP <= 400, "Staking: deposit fee too high"); // Max 4%
        require(address(_lpToken) != address(0), "Staking: invalid token address");
        require(_maxStakeAmount > _minStakeAmount, "Staking: invalid stake limits");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;

        poolInfo[poolLength] = PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accSblPerShare: 0,
            depositFeeBP: _depositFeeBP,
            totalStaked: 0,
            minStakeAmount: _minStakeAmount,
            maxStakeAmount: _maxStakeAmount,
            isActive: true
        });

        emit PoolAdded(poolLength, _allocPoint, address(_lpToken), _depositFeeBP);
        poolLength++;
    }

    /**
     * @dev Update the given pool's allocation points and deposit fee
     * @param _pid Pool ID
     * @param _allocPoint New allocation points
     * @param _depositFeeBP New deposit fee in basis points
     * @param _withUpdate Whether to update all pools
     */
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _depositFeeBP,
        bool _withUpdate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pid < poolLength, "Staking: invalid pool ID");
        require(_depositFeeBP <= 400, "Staking: deposit fee too high");

        if (_withUpdate) {
            massUpdatePools();
        }

        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        pool.allocPoint = _allocPoint;
        pool.depositFeeBP = _depositFeeBP;

        emit PoolUpdated(_pid, _allocPoint, _depositFeeBP);
    }

    /**
     * @dev Return reward multiplier over the given _from to _to block
     * @param _from From block
     * @param _to To block
     * @return Reward multiplier
     */
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return (_to - _from) * bonusMultiplier;
        } else if (_from >= bonusEndBlock) {
            return _to - _from;
        } else {
            return (bonusEndBlock - _from) * bonusMultiplier + (_to - bonusEndBlock);
        }
    }

    /**
     * @dev View function to see pending SBL tokens on frontend
     * @param _pid Pool ID
     * @param _user User address
     * @return Pending SBL tokens
     */
    function pendingSbl(uint256 _pid, address _user) external view returns (uint256) {
        require(_pid < poolLength, "Staking: invalid pool ID");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accSblPerShare = pool.accSblPerShare;
        uint256 lpSupply = pool.totalStaked;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 sblReward = (multiplier * sblPerBlock * pool.allocPoint) / totalAllocPoint;
            accSblPerShare += (sblReward * 1e12) / lpSupply;
        }

        return (user.amount * accSblPerShare) / 1e12 - user.rewardDebt + user.pendingRewards;
    }

    /**
     * @dev Update reward variables for all pools
     */
    function massUpdatePools() public {
        for (uint256 pid = 0; pid < poolLength; ++pid) {
            updatePool(pid);
        }
    }

    /**
     * @dev Update reward variables of the given pool
     * @param _pid Pool ID
     */
    function updatePool(uint256 _pid) public {
        require(_pid < poolLength, "Staking: invalid pool ID");

        PoolInfo storage pool = poolInfo[_pid];

        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint256 lpSupply = pool.totalStaked;

        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 sblReward = (multiplier * sblPerBlock * pool.allocPoint) / totalAllocPoint;

        // Mint SBL tokens for rewards
        sblToken.mint(address(this), sblReward);

        pool.accSblPerShare += (sblReward * 1e12) / lpSupply;
        pool.lastRewardBlock = block.number;
    }

    /**
     * @dev Stake LP tokens to earn SBL tokens
     * @param _pid Pool ID
     * @param _amount Amount to stake
     */
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant whenNotPaused {
        require(_pid < poolLength, "Staking: invalid pool ID");
        require(_amount > 0, "Staking: amount must be positive");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(pool.isActive, "Staking: pool not active");
        require(_amount >= pool.minStakeAmount, "Staking: amount below minimum");
        require(user.amount + _amount <= pool.maxStakeAmount, "Staking: exceeds maximum stake");

        updatePool(_pid);

        // Calculate pending rewards
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accSblPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        // Handle deposit fee
        uint256 depositAmount = _amount;
        if (pool.depositFeeBP > 0) {
            uint256 depositFee = (_amount * pool.depositFeeBP) / 10000;
            depositAmount = _amount - depositFee;
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), depositFee);
        }

        // Transfer tokens from user
        if (depositAmount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), depositAmount);
            user.amount += depositAmount;
            pool.totalStaked += depositAmount;
        }

        user.rewardDebt = (user.amount * pool.accSblPerShare) / 1e12;
        user.lastStakeTime = block.timestamp;

        emit Deposit(msg.sender, _pid, depositAmount);
    }

    /**
     * @dev Withdraw LP tokens and claim rewards
     * @param _pid Pool ID
     * @param _amount Amount to withdraw
     */
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        require(_pid < poolLength, "Staking: invalid pool ID");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "Staking: withdraw amount exceeds balance");

        updatePool(_pid);

        // Calculate pending rewards
        uint256 pending = (user.amount * pool.accSblPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        // Check for early withdrawal penalty
        uint256 withdrawAmount = _amount;
        if (block.timestamp < user.lastStakeTime + minimumStakingPeriod) {
            uint256 penalty = (_amount * earlyWithdrawalPenalty) / 10000;
            withdrawAmount = _amount - penalty;
            // Penalty tokens remain in the contract
        }

        if (withdrawAmount > 0) {
            user.amount -= _amount;
            pool.totalStaked -= _amount;
            pool.lpToken.safeTransfer(address(msg.sender), withdrawAmount);
        }

        user.rewardDebt = (user.amount * pool.accSblPerShare) / 1e12;

        emit Withdraw(msg.sender, _pid, withdrawAmount);
    }

    /**
     * @dev Claim pending rewards
     * @param _pid Pool ID
     */
    function claimRewards(uint256 _pid) external nonReentrant {
        require(_pid < poolLength, "Staking: invalid pool ID");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accSblPerShare) / 1e12 - user.rewardDebt;
        uint256 totalPending = pending + user.pendingRewards;

        if (totalPending > 0) {
            user.pendingRewards = 0;
            user.totalRewardsClaimed += totalPending;

            // Transfer SBL tokens to user
            IERC20(address(sblToken)).safeTransfer(msg.sender, totalPending);

            emit RewardsClaimed(msg.sender, _pid, totalPending);
        }

        user.rewardDebt = (user.amount * pool.accSblPerShare) / 1e12;
    }

    /**
     * @dev Withdraw without caring about rewards (emergency only)
     * @param _pid Pool ID
     */
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        require(_pid < poolLength, "Staking: invalid pool ID");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;
        pool.totalStaked -= amount;

        pool.lpToken.safeTransfer(address(msg.sender), amount);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /**
     * @dev Update SBL reward rate
     * @param _sblPerBlock New SBL tokens per block
     */
    function updateRewardRate(uint256 _sblPerBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        massUpdatePools();
        sblPerBlock = _sblPerBlock;
        emit RewardRateUpdated(_sblPerBlock);
    }

    /**
     * @dev Update bonus parameters
     * @param _bonusEndBlock New bonus end block
     * @param _bonusMultiplier New bonus multiplier
     */
    function updateBonusParameters(
        uint256 _bonusEndBlock,
        uint256 _bonusMultiplier
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bonusEndBlock = _bonusEndBlock;
        bonusMultiplier = _bonusMultiplier;
        emit BonusParametersUpdated(_bonusEndBlock, _bonusMultiplier);
    }

    /**
     * @dev Set pool active status
     * @param _pid Pool ID
     * @param _isActive Whether the pool is active
     */
    function setPoolStatus(uint256 _pid, bool _isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pid < poolLength, "Staking: invalid pool ID");
        poolInfo[_pid].isActive = _isActive;
    }

    /**
     * @dev Get user staking information
     * @param _pid Pool ID
     * @param _user User address
     * @return amount Amount staked
     * @return rewardDebt Reward debt
     * @return pendingRewards Pending rewards
     * @return lastStakeTime Last stake time
     */
    function getUserInfo(uint256 _pid, address _user) 
        external 
        view 
        returns (uint256 amount, uint256 rewardDebt, uint256 pendingRewards, uint256 lastStakeTime) 
    {
        UserInfo storage user = userInfo[_pid][_user];
        return (user.amount, user.rewardDebt, user.pendingRewards, user.lastStakeTime);
    }

    /**
     * @dev Pause contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
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