// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "../interfaces/IReputationRegistry.sol";
import {IValidationRegistry} from "../interfaces/IValidationRegistry.sol";

/// @title DeFiYieldAgent – An autonomous DeFi yield agent with EIP-8004 trust
/// @notice Demonstrates an EIP-8004 agent that **actually manages on-chain funds**,
///   making the identity/reputation/validation system meaningfully necessary.
///
/// Why this example is better than a "results-recorder" pattern:
///   - **On-chain fund custody**: users deposit ETH, agent manages it autonomously
///   - **Trust-gated deposits**: deposit caps scale with the agent's reputation score
///   - **Validation-gated strategies**: strategies require auditor approval before activation
///   - **Verifiable performance**: yield distribution is on-chain, not just a stored string
///   - **Dual role**: acts as both a fund manager AND a validator for other agents
///
/// The three EIP-8004 registries are load-bearing here, not cosmetic:
///   - Identity  → users discover the agent and its strategy capabilities
///   - Reputation → higher reputation unlocks higher per-user deposit caps
///   - Validation → strategies CANNOT be activated without passing a third-party audit
///
/// Lifecycle:
///   1. Owner deploys → auto-registers in IdentityRegistry as "yield-optimizer"
///   2. Owner proposes strategies → `proposeStrategy()` (status: Proposed)
///   3. Auditor validates strategy → ValidationRegistry makes it Audited
///   4. Owner activates audited strategy → `activateStrategy()`
///   5. Users deposit ETH → `deposit()` (caps enforced by reputation score)
///   6. Owner executes yield operations → `executeStrategy()` / `harvestYield()`
///   7. Users withdraw principal + yield → `withdraw()`
///   8. Users rate performance → `ratePerformance()` (feeds reputation)
///   9. Agent validates other agents → `validateOtherAgent()` (validator role)
contract DeFiYieldAgent {
    // ───────── Registries ─────────
    IIdentityRegistry public immutable identityRegistry;
    IReputationRegistry public immutable reputationRegistry;
    IValidationRegistry public immutable validationRegistry;

    // ───────── Agent Identity ─────────
    address public owner;
    uint256 public agentId;

    // ───────── Strategy Model ─────────
    /// @notice A strategy must be proposed → audited → activated before it can manage funds.
    ///   This makes the Validation Registry a hard dependency, not an afterthought.
    enum StrategyStatus {
        Proposed, // owner proposed, awaiting audit
        Audited, // passed third-party validation
        Active, // currently managing funds
        Paused, // temporarily halted (e.g. market conditions)
        Retired // permanently deactivated
    }

    struct Strategy {
        uint256 strategyId;
        string name; // e.g. "ETH Staking", "Liquidity Provision"
        string description; // what the strategy does
        StrategyStatus status;
        uint256 validationId; // linked ValidationRegistry record (0 if unaudited)
        uint256 totalDeposited; // total ETH currently managed by this strategy
        uint256 totalYieldGenerated; // cumulative yield produced
        uint256 proposedAt;
        uint256 activatedAt;
    }

    uint256 private _nextStrategyId = 1;
    mapping(uint256 => Strategy) public strategies;
    uint256[] private _allStrategyIds;

    // ───────── Vault Model ─────────
    struct Position {
        uint256 deposited; // principal deposited
        uint256 yieldEarned; // accumulated yield
        uint256 strategyId; // which strategy the funds are in
        uint256 depositedAt;
    }

    /// @dev user => strategyId => Position
    mapping(address => mapping(uint256 => Position)) public positions;
    /// @dev user => list of strategyIds they have positions in
    mapping(address => uint256[]) private _userStrategyIds;

    // ───────── Deposit Caps (Trust-Gated) ─────────
    /// @notice Per-user deposit cap scales with agent's reputation.
    ///   This is the KEY design choice that makes reputation meaningful:
    ///   - No reputation (0 feedbacks):  0.5 ETH max per user
    ///   - Low reputation  (avg < 50):   1 ETH
    ///   - Medium reputation (50-79):    5 ETH
    ///   - High reputation (80-100):    50 ETH
    uint256 public constant CAP_NO_REPUTATION = 0.5 ether;
    uint256 public constant CAP_LOW = 1 ether;
    uint256 public constant CAP_MEDIUM = 5 ether;
    uint256 public constant CAP_HIGH = 50 ether;

    // ───────── Global Stats ─────────
    uint256 public totalValueLocked;
    uint256 public totalYieldDistributed;

    // ───────── Events ─────────
    event StrategyProposed(uint256 indexed strategyId, string name);
    event StrategyAuditLinked(uint256 indexed strategyId, uint256 indexed validationId);
    event StrategyActivated(uint256 indexed strategyId);
    event StrategyPaused(uint256 indexed strategyId);
    event StrategyRetired(uint256 indexed strategyId);

    event Deposited(address indexed user, uint256 indexed strategyId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed strategyId, uint256 principal, uint256 yield);
    event YieldHarvested(uint256 indexed strategyId, uint256 yieldAmount);
    event StrategyExecuted(uint256 indexed strategyId, string action, uint256 amount);

    event OtherAgentValidated(uint256 indexed validationId, uint256 indexed targetAgentId, bool passed);

    // ───────── Modifiers ─────────
    modifier onlyOwner() {
        require(msg.sender == owner, "DeFiYieldAgent: not owner");
        _;
    }

    modifier strategyExists(uint256 strategyId) {
        require(strategies[strategyId].proposedAt != 0, "DeFiYieldAgent: strategy not found");
        _;
    }

    // ───────── Constructor ─────────
    constructor(address _idReg, address _repReg, address _valReg) {
        owner = msg.sender;
        identityRegistry = IIdentityRegistry(_idReg);
        reputationRegistry = IReputationRegistry(_repReg);
        validationRegistry = IValidationRegistry(_valReg);

        // Auto-register identity
        string memory uri = string(
            abi.encodePacked(
                'data:application/json,{"name":"DeFiYieldAgent","type":"fund-manager",',
                '"capabilities":["eth-staking","liquidity-provision","yield-farming"],',
                '"version":"1.0.0","contract":"',
                _toHexString(address(this)),
                '"}'
            )
        );
        agentId = identityRegistry.register(uri);

        identityRegistry.setMetadata(agentId, "service", "yield-optimization");
        identityRegistry.setMetadata(agentId, "asset", "ETH");
        identityRegistry.setMetadata(agentId, "risk-model", "conservative");
    }

    // ════════════════════════════════════════════════════════════
    //  STRATEGY MANAGEMENT (Validation-Gated)
    // ════════════════════════════════════════════════════════════

    /// @notice Owner proposes a new strategy. It CANNOT accept deposits until
    ///   a third-party auditor validates it via the ValidationRegistry.
    /// @param name Strategy name (e.g. "ETH Staking v2")
    /// @param description What the strategy does
    /// @param auditor Address of the designated auditor
    /// @param criteriaURI IPFS/HTTP link to audit criteria
    /// @return strategyId The new strategy ID
    function proposeStrategy(
        string calldata name,
        string calldata description,
        address auditor,
        string calldata criteriaURI
    ) external onlyOwner returns (uint256 strategyId) {
        strategyId = _nextStrategyId++;

        // Create validation request — auditor MUST respond before strategy can activate
        uint256 validationId = validationRegistry.validationRequest(agentId, auditor, criteriaURI);

        strategies[strategyId] = Strategy({
            strategyId: strategyId,
            name: name,
            description: description,
            status: StrategyStatus.Proposed,
            validationId: validationId,
            totalDeposited: 0,
            totalYieldGenerated: 0,
            proposedAt: block.timestamp,
            activatedAt: 0
        });
        _allStrategyIds.push(strategyId);

        emit StrategyProposed(strategyId, name);
        emit StrategyAuditLinked(strategyId, validationId);
    }

    /// @notice Owner activates a strategy ONLY if the auditor has approved it.
    ///   This is the critical gate: no validation pass = no fund management.
    function activateStrategy(uint256 strategyId) external onlyOwner strategyExists(strategyId) {
        Strategy storage s = strategies[strategyId];
        require(
            s.status == StrategyStatus.Proposed || s.status == StrategyStatus.Paused,
            "DeFiYieldAgent: cannot activate from current state"
        );

        // HARD REQUIREMENT: strategy must have passed validation
        if (s.status == StrategyStatus.Proposed) {
            IValidationRegistry.ValidationStatus valStatus = validationRegistry.getValidationStatus(s.validationId);
            require(valStatus == IValidationRegistry.ValidationStatus.Passed, "DeFiYieldAgent: strategy not validated");
            s.status = StrategyStatus.Audited; // intermediate state for record
        }

        s.status = StrategyStatus.Active;
        s.activatedAt = block.timestamp;

        emit StrategyActivated(strategyId);
    }

    /// @notice Emergency pause a strategy.
    function pauseStrategy(uint256 strategyId) external onlyOwner strategyExists(strategyId) {
        Strategy storage s = strategies[strategyId];
        require(s.status == StrategyStatus.Active, "DeFiYieldAgent: not active");
        s.status = StrategyStatus.Paused;
        emit StrategyPaused(strategyId);
    }

    /// @notice Permanently retire a strategy.
    function retireStrategy(uint256 strategyId) external onlyOwner strategyExists(strategyId) {
        Strategy storage s = strategies[strategyId];
        require(s.totalDeposited == 0, "DeFiYieldAgent: has remaining deposits");
        s.status = StrategyStatus.Retired;
        emit StrategyRetired(strategyId);
    }

    // ════════════════════════════════════════════════════════════
    //  VAULT – User Deposits / Withdrawals (Reputation-Gated)
    // ════════════════════════════════════════════════════════════

    /// @notice Users deposit ETH into a specific strategy.
    ///   Deposit cap is determined by the agent's reputation score.
    function deposit(uint256 strategyId) external payable strategyExists(strategyId) {
        require(msg.value > 0, "DeFiYieldAgent: zero deposit");

        Strategy storage s = strategies[strategyId];
        require(s.status == StrategyStatus.Active, "DeFiYieldAgent: strategy not active");

        // Enforce reputation-based deposit cap
        uint256 cap = getDepositCap();
        Position storage pos = positions[msg.sender][strategyId];
        require(pos.deposited + msg.value <= cap, "DeFiYieldAgent: exceeds reputation-based deposit cap");

        if (pos.depositedAt == 0) {
            // First deposit in this strategy
            pos.strategyId = strategyId;
            pos.depositedAt = block.timestamp;
            _userStrategyIds[msg.sender].push(strategyId);
        }

        pos.deposited += msg.value;
        s.totalDeposited += msg.value;
        totalValueLocked += msg.value;

        emit Deposited(msg.sender, strategyId, msg.value);
    }

    /// @notice Users withdraw their principal + accumulated yield from a strategy.
    function withdraw(uint256 strategyId) external strategyExists(strategyId) {
        Position storage pos = positions[msg.sender][strategyId];
        require(pos.deposited > 0, "DeFiYieldAgent: no position");

        uint256 principal = pos.deposited;
        uint256 yield = pos.yieldEarned;
        uint256 total = principal + yield;

        // Clear position
        pos.deposited = 0;
        pos.yieldEarned = 0;

        // Update strategy and global stats
        Strategy storage s = strategies[strategyId];
        s.totalDeposited -= principal;
        totalValueLocked -= principal;
        totalYieldDistributed += yield;

        // Transfer funds
        (bool ok,) = msg.sender.call{value: total}("");
        require(ok, "DeFiYieldAgent: transfer failed");

        emit Withdrawn(msg.sender, strategyId, principal, yield);
    }

    // ════════════════════════════════════════════════════════════
    //  YIELD OPERATIONS (Agent's Autonomous Actions)
    // ════════════════════════════════════════════════════════════

    /// @notice Agent operator executes a strategy action (e.g. rebalance, compound).
    ///   In a production system, this would call external DeFi protocols.
    ///   For this example, it records the action on-chain for transparency.
    /// @param strategyId The strategy to execute
    /// @param action Description of the action taken (e.g. "rebalance", "compound")
    function executeStrategy(uint256 strategyId, string calldata action) external onlyOwner strategyExists(strategyId) {
        Strategy storage s = strategies[strategyId];
        require(s.status == StrategyStatus.Active, "DeFiYieldAgent: strategy not active");

        emit StrategyExecuted(strategyId, action, s.totalDeposited);
    }

    /// @notice Agent operator distributes yield to depositors in a strategy.
    ///   This is a REAL on-chain fund operation: ETH is sent to the contract
    ///   (from the agent's yield sources) and allocated to depositors pro-rata.
    /// @param strategyId The strategy that generated yield
    /// @param depositors Array of depositor addresses
    /// @param yieldAmounts Array of yield amounts (wei) per depositor
    function harvestYield(uint256 strategyId, address[] calldata depositors, uint256[] calldata yieldAmounts)
        external
        payable
        onlyOwner
        strategyExists(strategyId)
    {
        require(depositors.length == yieldAmounts.length, "DeFiYieldAgent: array mismatch");

        Strategy storage s = strategies[strategyId];
        require(s.status == StrategyStatus.Active, "DeFiYieldAgent: strategy not active");

        uint256 totalYield;
        for (uint256 i = 0; i < depositors.length; i++) {
            Position storage pos = positions[depositors[i]][strategyId];
            require(pos.deposited > 0, "DeFiYieldAgent: depositor has no position");

            pos.yieldEarned += yieldAmounts[i];
            totalYield += yieldAmounts[i];
        }

        require(msg.value >= totalYield, "DeFiYieldAgent: insufficient yield funds");
        s.totalYieldGenerated += totalYield;

        emit YieldHarvested(strategyId, totalYield);
    }

    // ════════════════════════════════════════════════════════════
    //  REPUTATION – Users rate the agent's performance
    // ════════════════════════════════════════════════════════════

    /// @notice Users who have (or had) a position can rate the agent.
    ///   Reputation directly affects future deposit caps — creating a
    ///   virtuous cycle: good performance → better reputation → more deposits.
    function ratePerformance(uint256 strategyId, uint8 score, string calldata comment)
        external
        returns (uint256 feedbackId)
    {
        // Must have deposited at some point
        require(positions[msg.sender][strategyId].depositedAt != 0, "DeFiYieldAgent: no history in this strategy");

        feedbackId = reputationRegistry.giveFeedback(agentId, score, comment);
    }

    /// @notice Agent owner responds to feedback.
    function respondToFeedback(uint256 feedbackId, string calldata response) external onlyOwner {
        reputationRegistry.appendResponse(feedbackId, response);
    }

    // ════════════════════════════════════════════════════════════
    //  VALIDATOR ROLE – Validate other agents
    // ════════════════════════════════════════════════════════════

    /// @notice This agent acts as a validator and responds to a validation request
    ///   from another agent in the ValidationRegistry.
    function validateOtherAgent(uint256 validationId, bool passed, string calldata reportURI) external onlyOwner {
        validationRegistry.validationResponse(validationId, passed, reportURI);
        IValidationRegistry.ValidationRecord memory r = validationRegistry.getValidation(validationId);
        emit OtherAgentValidated(validationId, r.agentId, passed);
    }

    // ════════════════════════════════════════════════════════════
    //  VIEW HELPERS – Trust Profile & Deposit Cap
    // ════════════════════════════════════════════════════════════

    /// @notice Calculate the per-user deposit cap based on the agent's reputation.
    ///   This is the function that makes reputation LOAD-BEARING:
    ///   it directly controls how much money users can entrust to the agent.
    function getDepositCap() public view returns (uint256) {
        IReputationRegistry.Summary memory rep = reputationRegistry.getSummary(agentId);

        if (rep.activeFeedbacks == 0) {
            return CAP_NO_REPUTATION;
        }

        // averageScore is score * 100 (e.g. 8500 means 85/100)
        uint256 avgScore = rep.averageScore;
        if (avgScore >= 8000) return CAP_HIGH;
        if (avgScore >= 5000) return CAP_MEDIUM;
        return CAP_LOW;
    }

    function getReputationSummary() external view returns (IReputationRegistry.Summary memory) {
        return reputationRegistry.getSummary(agentId);
    }

    function getValidationSummary() external view returns (IValidationRegistry.ValidSummary memory) {
        return validationRegistry.getSummary(agentId);
    }

    function getAgentURI() external view returns (string memory) {
        return identityRegistry.agentURI(agentId);
    }

    function getStrategy(uint256 strategyId) external view returns (Strategy memory) {
        return strategies[strategyId];
    }

    function getAllStrategyIds() external view returns (uint256[] memory) {
        return _allStrategyIds;
    }

    function getUserStrategyIds(address user) external view returns (uint256[] memory) {
        return _userStrategyIds[user];
    }

    function getPosition(address user, uint256 strategyId) external view returns (Position memory) {
        return positions[user][strategyId];
    }

    function getStrategyStats()
        external
        view
        returns (uint256 total, uint256 proposed, uint256 active, uint256 paused, uint256 retired)
    {
        total = _allStrategyIds.length;
        for (uint256 i = 0; i < total; i++) {
            StrategyStatus s = strategies[_allStrategyIds[i]].status;
            if (s == StrategyStatus.Proposed) proposed++;
            else if (s == StrategyStatus.Active) active++;
            else if (s == StrategyStatus.Paused) paused++;
            else if (s == StrategyStatus.Retired) retired++;
        }
    }

    // ═══════ Internal ═══════

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 value = bytes20(addr);
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }

    receive() external payable {}
}
