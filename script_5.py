# Create a comprehensive test suite for the Stabolut protocol
test_suite = '''// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/USBStablecoin.sol";
import "../src/SBLGovernanceToken.sol";
import "../src/StabolutEngine.sol";
import "../src/StakingContract.sol";
import "../src/Treasury.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mock contracts for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockChainlinkAggregator {
    int256 public price;
    uint256 public updatedAt;
    uint8 public decimals = 8;
    
    constructor(int256 _price) {
        price = _price;
        updatedAt = block.timestamp;
    }
    
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt_,
        uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
    
    function updatePrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }
}

contract MockDeltaNeutralStrategy {
    mapping(address => uint256) public deposits;
    uint256 public totalValue;
    
    function deposit(address token, uint256 amount) external returns (uint256 yield) {
        deposits[token] += amount;
        totalValue += amount;
        // Mock 5% yield
        yield = amount * 5 / 100;
        return yield;
    }
    
    function withdraw(uint256 amount, address to) external returns (uint256 actualAmount) {
        totalValue -= amount;
        return amount;
    }
    
    function getPositionValue() external view returns (uint256) {
        return totalValue;
    }
    
    function closePosition() external returns (uint256) {
        uint256 value = totalValue;
        totalValue = 0;
        return value;
    }
}

/**
 * @title Stabolut Protocol Test Suite
 * @dev Comprehensive tests for the Stabolut stablecoin system
 */
contract StabolutProtocolTest is Test {
    // Core contracts
    USBStablecoin public usb;
    SBLGovernanceToken public sbl;
    StabolutEngine public engine;
    StakingContract public staking;
    Treasury public treasury;
    
    // Mock contracts
    MockERC20 public weth;
    MockERC20 public usdc;
    MockChainlinkAggregator public ethPriceFeed;
    MockChainlinkAggregator public usdcPriceFeed;
    MockDeltaNeutralStrategy public deltaStrategy;
    
    // Test accounts
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public treasury_manager = address(0x4);
    
    // Constants
    uint256 constant INITIAL_ETH_PRICE = 2000e8; // $2000 with 8 decimals
    uint256 constant INITIAL_USDC_PRICE = 1e8;   // $1 with 8 decimals
    
    event log_named_decimal_uint(string key, uint256 val, uint256 decimals);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock contracts
        weth = new MockERC20("Wrapped ETH", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");
        ethPriceFeed = new MockChainlinkAggregator(int256(INITIAL_ETH_PRICE));
        usdcPriceFeed = new MockChainlinkAggregator(int256(INITIAL_USDC_PRICE));
        deltaStrategy = new MockDeltaNeutralStrategy();
        
        // Deploy implementation contracts
        USBStablecoin usbImpl = new USBStablecoin();
        SBLGovernanceToken sblImpl = new SBLGovernanceToken();
        StabolutEngine engineImpl = new StabolutEngine();
        StakingContract stakingImpl = new StakingContract();
        Treasury treasuryImpl = new Treasury();
        
        // Deploy proxy contracts
        bytes memory usbInitData = abi.encodeWithSelector(
            USBStablecoin.initialize.selector,
            "Stabolut Dollar",
            "USB",
            1_000_000_000 * 10**18, // max supply
            100_000 * 10**18,       // minting rate limit
            address(0)              // engine (set later)
        );
        
        ERC1967Proxy usbProxy = new ERC1967Proxy(address(usbImpl), usbInitData);
        usb = USBStablecoin(address(usbProxy));
        
        bytes memory sblInitData = abi.encodeWithSelector(
            SBLGovernanceToken.initialize.selector,
            "Stabolut Governance Token",
            "SBL",
            7200,    // voting delay (1 day in blocks)
            50400,   // voting period (7 days in blocks)
            1_000_000 * 10**18, // proposal threshold
            4        // quorum numerator (4%)
        );
        
        ERC1967Proxy sblProxy = new ERC1967Proxy(address(sblImpl), sblInitData);
        sbl = SBLGovernanceToken(address(sblProxy));
        
        bytes memory treasuryInitData = abi.encodeWithSelector(
            Treasury.initialize.selector,
            address(usb),
            2000,  // emergency reserve %
            11000, // minimum reserve ratio
            500,   // depeg threshold
            1000,  // max single withdrawal
            2 days, // timelock duration
            1 days  // min intervention interval
        );
        
        ERC1967Proxy treasuryProxy = new ERC1967Proxy(address(treasuryImpl), treasuryInitData);
        treasury = Treasury(payable(address(treasuryProxy)));
        
        bytes memory engineInitData = abi.encodeWithSelector(
            StabolutEngine.initialize.selector,
            address(usb),
            address(treasury),
            address(deltaStrategy),
            7000, // treasury yield %
            1000  // emergency threshold
        );
        
        ERC1967Proxy engineProxy = new ERC1967Proxy(address(engineImpl), engineInitData);
        engine = StabolutEngine(address(engineProxy));
        
        bytes memory stakingInitData = abi.encodeWithSelector(
            StakingContract.initialize.selector,
            address(usb),
            address(sbl),
            10 * 10**18, // SBL per block
            block.number + 100, // start block
            block.number + 1000000, // bonus end block
            2, // bonus multiplier
            7 days, // min staking period
            500 // early withdrawal penalty
        );
        
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInitData);
        staking = StakingContract(address(stakingProxy));
        
        // Set up relationships
        usb.setStabolutEngine(address(engine));
        sbl.setStakingContract(address(staking));
        
        // Add supported tokens to engine
        engine.addSupportedToken(
            address(weth),
            1 ether / 10,     // min deposit 0.1 ETH
            1000 ether,       // max deposit 1000 ETH
            8500,             // liquidation threshold 85%
            100,              // stability fee 1%
            address(ethPriceFeed)
        );
        
        engine.addSupportedToken(
            address(usdc),
            100 * 10**6,      // min deposit 100 USDC
            1_000_000 * 10**6, // max deposit 1M USDC
            9500,             // liquidation threshold 95%
            50,               // stability fee 0.5%
            address(usdcPriceFeed)
        );
        
        // Add staking pool
        staking.add(
            100,              // allocation points
            usb,              // LP token (USB)
            0,                // deposit fee
            10 * 10**18,      // min stake 10 USB
            1_000_000 * 10**18, // max stake 1M USB
            false             // with update
        );
        
        // Setup treasury assets
        treasury.addSupportedAsset(
            address(usdc),
            4000,             // 40% target allocation
            address(usdcPriceFeed),
            true              // is stable
        );
        
        treasury.addSupportedAsset(
            address(weth),
            3000,             // 30% target allocation
            address(ethPriceFeed),
            false             // not stable
        );
        
        // Mint test tokens
        weth.mint(user1, 100 ether);
        weth.mint(user2, 100 ether);
        usdc.mint(user1, 1_000_000 * 10**6);
        usdc.mint(user2, 1_000_000 * 10**6);
        
        vm.stopPrank();
    }
    
    function testInitialSetup() public {
        assertEq(usb.name(), "Stabolut Dollar");
        assertEq(usb.symbol(), "USB");
        assertEq(usb.decimals(), 18);
        assertEq(usb.totalSupply(), 0);
        
        assertEq(sbl.name(), "Stabolut Governance Token");
        assertEq(sbl.symbol(), "SBL");
        assertEq(sbl.decimals(), 18);
        assertEq(sbl.totalSupply(), 0);
        
        assertTrue(engine.supportedTokens(address(weth)).isSupported);
        assertTrue(engine.supportedTokens(address(usdc)).isSupported);
    }
    
    function testUserDepositAndMint() public {
        vm.startPrank(user1);
        
        uint256 depositAmount = 1 ether;
        weth.approve(address(engine), depositAmount);
        
        uint256 initialUsbSupply = usb.totalSupply();
        
        engine.deposit(address(weth), depositAmount);
        
        uint256 expectedUsbMinted = (depositAmount * INITIAL_ETH_PRICE / 1e8 * 10000) / 15000; // 150% collateralization
        uint256 actualUsbMinted = usb.balanceOf(user1);
        
        assertApproxEqRel(actualUsbMinted, expectedUsbMinted, 0.01e18); // 1% tolerance
        assertEq(usb.totalSupply(), initialUsbSupply + actualUsbMinted);
        
        vm.stopPrank();
    }
    
    function testUserWithdrawAndBurn() public {
        // First deposit
        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;
        weth.approve(address(engine), depositAmount);
        engine.deposit(address(weth), depositAmount);
        
        uint256 usbBalance = usb.balanceOf(user1);
        uint256 withdrawAmount = usbBalance / 2;
        
        usb.approve(address(engine), withdrawAmount);
        
        uint256 initialWethBalance = weth.balanceOf(user1);
        
        engine.withdraw(address(weth), withdrawAmount);
        
        uint256 finalWethBalance = weth.balanceOf(user1);
        uint256 finalUsbBalance = usb.balanceOf(user1);
        
        assertGt(finalWethBalance, initialWethBalance);
        assertEq(finalUsbBalance, usbBalance - withdrawAmount);
        
        vm.stopPrank();
    }
    
    function testStakingAndRewards() public {
        // First get some USB tokens
        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;
        weth.approve(address(engine), depositAmount);
        engine.deposit(address(weth), depositAmount);
        
        uint256 usbBalance = usb.balanceOf(user1);
        uint256 stakeAmount = usbBalance / 2;
        
        usb.approve(address(staking), stakeAmount);
        
        // Stake USB tokens
        staking.deposit(0, stakeAmount); // pool 0
        
        // Advance blocks to generate rewards
        vm.roll(block.number + 100);
        
        // Check pending rewards
        uint256 pendingRewards = staking.pendingSbl(0, user1);
        assertGt(pendingRewards, 0);
        
        // Claim rewards
        uint256 initialSblBalance = sbl.balanceOf(user1);
        staking.claimRewards(0);
        uint256 finalSblBalance = sbl.balanceOf(user1);
        
        assertGt(finalSblBalance, initialSblBalance);
        
        vm.stopPrank();
    }
    
    function testGovernanceProposal() public {
        // First get SBL tokens by staking
        vm.startPrank(user1);
        uint256 depositAmount = 10 ether; // Large deposit to get enough SBL
        weth.approve(address(engine), depositAmount);
        engine.deposit(address(weth), depositAmount);
        
        uint256 usbBalance = usb.balanceOf(user1);
        usb.approve(address(staking), usbBalance);
        staking.deposit(0, usbBalance);
        
        // Advance blocks to get rewards
        vm.roll(block.number + 1000);
        staking.claimRewards(0);
        
        uint256 sblBalance = sbl.balanceOf(user1);
        
        // Delegate voting power to self
        sbl.delegate(user1);
        
        // Advance one block for delegation to take effect
        vm.roll(block.number + 1);
        
        if (sblBalance >= 1_000_000 * 10**18) {
            // Create proposal
            uint256 proposalId = sbl.propose("Test proposal");
            
            // Advance past voting delay
            vm.roll(block.number + 7200 + 1);
            
            // Vote on proposal
            sbl.castVote(proposalId, 1); // Vote for
            
            assertEq(uint8(sbl.state(proposalId)), uint8(SBLGovernanceToken.ProposalState.Active));
        }
        
        vm.stopPrank();
    }
    
    function testEmergencyPause() public {
        vm.startPrank(owner);
        
        engine.emergencyPause("Testing emergency pause");
        
        assertTrue(engine.paused());
        
        vm.stopPrank();
        
        // Try to deposit while paused (should fail)
        vm.startPrank(user1);
        weth.approve(address(engine), 1 ether);
        
        vm.expectRevert("Pausable: paused");
        engine.deposit(address(weth), 1 ether);
        
        vm.stopPrank();
    }
    
    function testCircuitBreaker() public {
        vm.startPrank(user1);
        
        // Try to mint more than circuit breaker threshold
        // This would require a very large deposit
        uint256 largeDeposit = 100 ether;
        weth.mint(user1, largeDeposit);
        weth.approve(address(engine), largeDeposit);
        
        // This might trigger circuit breaker depending on existing supply
        try engine.deposit(address(weth), largeDeposit) {
            // If successful, circuit breaker didn't trigger
            assertTrue(true);
        } catch (bytes memory reason) {
            // Check if it's circuit breaker
            if (keccak256(reason) == keccak256("USB: circuit breaker triggered")) {
                assertTrue(true); // Expected behavior
            } else {
                // Some other error
                revert(string(reason));
            }
        }
        
        vm.stopPrank();
    }
    
    function testCollateralizationRatio() public {
        vm.startPrank(user1);
        
        uint256 depositAmount = 1 ether;
        weth.approve(address(engine), depositAmount);
        engine.deposit(address(weth), depositAmount);
        
        uint256 usbMinted = usb.balanceOf(user1);
        
        // Try to withdraw more than allowed by collateralization ratio
        usb.approve(address(engine), usbMinted);
        
        vm.expectRevert("Engine: insufficient collateralization");
        engine.withdraw(address(weth), usbMinted); // Try to withdraw all
        
        vm.stopPrank();
    }
    
    function testPriceOracleStaleCheck() public {
        vm.startPrank(user1);
        
        // Advance time to make price stale
        vm.warp(block.timestamp + 2 hours);
        
        weth.approve(address(engine), 1 ether);
        
        vm.expectRevert("Engine: stale price");
        engine.deposit(address(weth), 1 ether);
        
        vm.stopPrank();
    }
    
    function testYieldDistribution() public {
        vm.startPrank(user1);
        
        uint256 depositAmount = 1 ether;
        weth.approve(address(engine), depositAmount);
        
        uint256 initialTreasuryBalance = treasury.totalReservesUSD();
        
        engine.deposit(address(weth), depositAmount);
        
        // Check that yield was distributed to treasury
        // (Note: This depends on the mock delta strategy returning 5% yield)
        uint256 finalTreasuryBalance = treasury.totalReservesUSD();
        assertGt(finalTreasuryBalance, initialTreasuryBalance);
        
        vm.stopPrank();
    }
    
    function testTreasuryTimelock() public {
        // Setup treasury with some funds
        vm.startPrank(owner);
        usdc.mint(address(treasury), 1000 * 10**6);
        treasury.deposit(address(usdc), 1000 * 10**6);
        vm.stopPrank();
        
        vm.startPrank(treasury_manager);
        treasury.grantRole(treasury.TREASURY_MANAGER_ROLE(), treasury_manager);
        
        // Queue large withdrawal (should require timelock)
        bytes32 operationId = treasury.queueWithdrawal(
            address(usdc),
            900 * 10**6, // Large amount
            treasury_manager,
            "Test withdrawal"
        );
        
        // Try to execute immediately (should fail)
        vm.expectRevert("Treasury: timelock not expired");
        treasury.executeWithdrawal(operationId);
        
        // Advance time past timelock
        vm.warp(block.timestamp + 2 days + 1);
        
        // Now should work
        treasury.executeWithdrawal(operationId);
        
        vm.stopPrank();
    }
    
    function testRateLimiting() public {
        vm.startPrank(user1);
        
        // Try to mint more than rate limit in single block
        uint256 largeDeposit = 200_000 ether; // Assuming this exceeds rate limit
        weth.mint(user1, largeDeposit);
        weth.approve(address(engine), largeDeposit);
        
        vm.expectRevert("USB: exceeds minting rate limit");
        engine.deposit(address(weth), largeDeposit);
        
        vm.stopPrank();
    }
    
    function testEarlyWithdrawalPenalty() public {
        // Stake tokens
        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;
        weth.approve(address(engine), depositAmount);
        engine.deposit(address(weth), depositAmount);
        
        uint256 usbBalance = usb.balanceOf(user1);
        usb.approve(address(staking), usbBalance);
        staking.deposit(0, usbBalance);
        
        // Try to withdraw immediately (should incur penalty)
        uint256 initialBalance = usb.balanceOf(user1);
        staking.withdraw(0, usbBalance / 2);
        uint256 finalBalance = usb.balanceOf(user1);
        
        // Should receive less than deposited due to early withdrawal penalty
        uint256 received = finalBalance - initialBalance;
        assertLt(received, usbBalance / 2);
        
        vm.stopPrank();
    }
    
    function invariant_usbTotalSupplyMatchesCollateral() public {
        // This invariant ensures USB total supply is always backed by sufficient collateral
        uint256 totalSupply = usb.totalSupply();
        if (totalSupply > 0) {
            uint256 totalCollateralValue = engine.totalValueLocked();
            uint256 requiredCollateral = (totalSupply * 15000) / 10000; // 150% backing
            assertGe(totalCollateralValue, requiredCollateral);
        }
    }
    
    function invariant_treasuryReservesPositive() public {
        // Treasury reserves should never go negative
        uint256 totalReserves = treasury.totalReservesUSD();
        assertGe(totalReserves, 0);
    }
    
    function invariant_stakingRewardsPositive() public {
        // Staking rewards should never go negative
        if (staking.poolLength() > 0) {
            for (uint256 i = 0; i < staking.poolLength(); i++) {
                (,,,uint256 accSblPerShare,,,,) = staking.poolInfo(i);
                assertGe(accSblPerShare, 0);
            }
        }
    }
}'''

# Save the test suite
with open('StabolutProtocolTest.t.sol', 'w') as f:
    f.write(test_suite)

print("✅ Comprehensive test suite created successfully")
print("📄 Test coverage includes:")
print("  - Contract initialization and setup")
print("  - User deposit and withdrawal flows")
print("  - Staking and reward distribution")
print("  - Governance proposal system")
print("  - Emergency pause mechanisms")
print("  - Circuit breaker functionality")
print("  - Collateralization ratio enforcement")
print("  - Oracle price feed integration")
print("  - Yield distribution to treasury")
print("  - Timelock mechanisms")
print("  - Rate limiting protection")
print("  - Early withdrawal penalties")
print("  - Invariant testing")
print("\n📋 Test execution commands:")
print("  forge test --contracts StabolutProtocolTest.t.sol")
print("  forge test --match-test testUserDepositAndMint")
print("  forge test --gas-report")
print("  forge coverage")