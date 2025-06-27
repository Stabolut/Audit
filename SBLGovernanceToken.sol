// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Timelock.sol";

/**
 * @title SBL Governance Token
 * @dev Governance token for Stabolut protocol with voting capabilities
 * @author Stabolut Protocol
 */
contract SBLGovernanceToken is 
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    /// @notice Timelock contract address
    Timelock public timelock;

    /// @notice Maximum supply of SBL tokens
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1 billion tokens

    /// @notice Staking contract address
    address public stakingContract;

    /// @notice Snapshot ID for governance proposals
    uint256 public currentSnapshotId;

    /// @notice Voting delay in blocks
    uint256 public votingDelay;

    /// @notice Voting period in blocks
    uint256 public votingPeriod;

    /// @notice Proposal threshold (minimum tokens to create proposal)
    uint256 public proposalThreshold;

    /// @notice Quorum required for proposal to pass
    uint256 public quorumNumerator;

    /// @notice Mapping of proposal IDs to their details
    mapping(uint256 => ProposalCore) public proposals;

    /// @notice Mapping of proposal IDs to vote counts
    mapping(uint256 => ProposalVote) public proposalVotes;

    /// @notice Mapping of proposal IDs to voter addresses to vote receipt
    mapping(uint256 => mapping(address => Receipt)) public proposalReceipts;

    /// @notice Current proposal ID counter
    uint256 public proposalCount;

    struct ProposalCore {
        uint256 id;
        address proposer;
        uint256 eta;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
        uint256 proposerVotingPower; // Snapshot of proposer's voting power
    }

    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => Receipt) receipts;
    }

    struct Receipt {
        bool hasVoted;
        uint8 support;
        uint96 votes;
    }

    enum VoteType {
        Against,
        For,
        Abstain
    }

    event ProposalCreated(
        uint256 id,
        address proposer,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );

    event VoteCast(
        address indexed voter,
        uint256 proposalId,
        uint8 support,
        uint256 weight,
        string reason
    );

    event ProposalExecuted(uint256 proposalId);
    event ProposalCanceled(uint256 proposalId);
    event StakingContractUpdated(address newStakingContract);
    event GovernanceParametersUpdated(
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumNumerator
    );
    event TimelockUpdated(address newTimelock);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator,
        address _timelock
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __ERC20Votes_init();
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(TIMELOCK_ADMIN_ROLE, msg.sender);

        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThreshold = _proposalThreshold;
        quorumNumerator = _quorumNumerator;
        timelock = Timelock(_timelock);
    }

    /**
     * @dev Mint new SBL tokens (typically called by staking contract)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) 
        external 
        onlyRole(MINTER_ROLE) 
        whenNotPaused 
    {
        require(to != address(0), "SBL: mint to zero address");
        require(amount > 0, "SBL: amount must be positive");
        require(totalSupply() + amount <= MAX_SUPPLY, "SBL: exceeds max supply");

        _mint(to, amount);
    }

    /**
     * @dev Burn SBL tokens
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        require(amount > 0, "SBL: amount must be positive");
        _burn(msg.sender, amount);
    }

    /**
     * @dev Create a new governance proposal
     * @param description Proposal description
     * @return proposalId The ID of the newly created proposal
     */
    function propose(string memory description) 
        external 
        returns (uint256 proposalId) 
    {
        uint256 proposerVotes = getVotes(msg.sender, block.number - 1);
        require(
            proposerVotes >= proposalThreshold,
            "SBL: proposer votes below threshold"
        );

        proposalId = ++proposalCount;
        uint256 startBlock = block.number + votingDelay;
        uint256 endBlock = startBlock + votingPeriod;

        ProposalCore storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.startBlock = startBlock;
        proposal.endBlock = endBlock;
        proposal.proposerVotingPower = proposerVotes;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            startBlock,
            endBlock,
            description
        );

        return proposalId;
    }

    /**
     * @dev Cast a vote on a proposal
     * @param proposalId ID of the proposal to vote on
     * @param support Vote type (0=against, 1=for, 2=abstain)
     * @param reason Reason for the vote
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external nonReentrant returns (uint256) {
        return _castVote(proposalId, msg.sender, support, reason);
    }

    /**
     * @dev Cast a vote on a proposal
     * @param proposalId ID of the proposal to vote on
     * @param support Vote type (0=against, 1=for, 2=abstain)
     */
    function castVote(uint256 proposalId, uint8 support) external nonReentrant returns (uint256) {
        return _castVote(proposalId, msg.sender, support, "");
    }

    /**
     * @dev Internal function to cast a vote
     */
    function _castVote(
        uint256 proposalId,
        address voter,
        uint8 support,
        string memory reason
    ) internal returns (uint256) {
        require(state(proposalId) == ProposalState.Active, "SBL: voting is closed");
        require(support <= 2, "SBL: invalid vote type");

        ProposalVote storage proposalVote = proposalVotes[proposalId];
        Receipt storage receipt = proposalVote.receipts[voter];
        require(!receipt.hasVoted, "SBL: voter already voted");

        uint256 weight = getVotes(voter, proposals[proposalId].startBlock);

        if (support == 0) {
            proposalVote.againstVotes += weight;
        } else if (support == 1) {
            proposalVote.forVotes += weight;
        } else {
            proposalVote.abstainVotes += weight;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = uint96(weight);

        emit VoteCast(voter, proposalId, support, weight, reason);

        return weight;
    }

    /**
     * @dev Get the state of a proposal
     * @param proposalId ID of the proposal
     * @return ProposalState The current state of the proposal
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalId > 0 && proposalId <= proposalCount, "SBL: invalid proposal id");

        ProposalCore storage proposal = proposals[proposalId];

        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (_quorumReached(proposalId) && _voteSucceeded(proposalId)) {
            return ProposalState.Succeeded;
        } else {
            return ProposalState.Defeated;
        }
    }

    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Executed
    }

    /**
     * @dev Check if quorum is reached for a proposal
     */
    function _quorumReached(uint256 proposalId) internal view returns (bool) {
        ProposalVote storage proposalVote = proposalVotes[proposalId];
        uint256 totalVotes = proposalVote.forVotes + proposalVote.againstVotes + proposalVote.abstainVotes;
        return totalVotes >= quorum(proposals[proposalId].startBlock);
    }

    /**
     * @dev Check if a proposal has succeeded
     */
    function _voteSucceeded(uint256 proposalId) internal view returns (bool) {
        ProposalVote storage proposalVote = proposalVotes[proposalId];
        return proposalVote.forVotes > proposalVote.againstVotes;
    }

    /**
     * @dev Calculate quorum for a given block number
     */
    function quorum(uint256 blockNumber) public view returns (uint256) {
        return (totalSupplyAt(blockNumber) * quorumNumerator) / 100;
    }

    /**
     * @dev Set staking contract address
     * @param _stakingContract New staking contract address
     */
    function setStakingContract(address _stakingContract) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_stakingContract != address(0), "SBL: invalid staking contract");

        // Revoke role from old staking contract
        if (stakingContract != address(0)) {
            _revokeRole(MINTER_ROLE, stakingContract);
        }

        stakingContract = _stakingContract;
        _grantRole(MINTER_ROLE, _stakingContract);

        emit StakingContractUpdated(_stakingContract);
    }

    /**
     * @dev Update governance parameters
     */
    function updateGovernanceParameters(
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    ) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_votingDelay > 0, "SBL: invalid voting delay");
        require(_votingPeriod > 0, "SBL: invalid voting period");
        require(_quorumNumerator <= 100, "SBL: invalid quorum numerator");

        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThreshold = _proposalThreshold;
        quorumNumerator = _quorumNumerator;

        emit GovernanceParametersUpdated(
            _votingDelay,
            _votingPeriod,
            _proposalThreshold,
            _quorumNumerator
        );
    }

    /**
     * @dev Update timelock contract address
     * @param _timelock New timelock contract address
     */
    function setTimelock(address _timelock) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_timelock != address(0), "SBL: invalid timelock");
        timelock = Timelock(_timelock);
        emit TimelockUpdated(_timelock);
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
     * @dev Override _afterTokenTransfer for ERC20Votes
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._afterTokenTransfer(from, to, amount);
    }

    /**
     * @dev Override _mint for ERC20Votes
     */
    function _mint(address to, uint256 amount)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._mint(to, amount);
    }

    /**
     * @dev Override _burn for ERC20Votes
     */
    function _burn(address account, uint256 amount)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._burn(account, amount);
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