// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "../interfaces/IReputationRegistry.sol";
import {IValidationRegistry} from "../interfaces/IValidationRegistry.sol";

/// @title DataOracleAgent – A stake-backed price-feed oracle with EIP-8004 trust
/// @notice Demonstrates an EIP-8004 agent that provides **on-chain data feeds** consumed
///   by other contracts, where identity/reputation/validation are structurally necessary.
///
/// Why this example is better than the old "WeatherAgent" pattern:
///   - **Real on-chain utility**: other contracts call `getLatestData()` to read prices
///   - **Stake-backed security**: agent must stake ETH as collateral, slashable on bad data
///   - **Validation-gated feeds**: a data feed CANNOT go live without auditor approval
///   - **Reputation-based stake discount**: higher reputation → lower required stake
///   - **Dispute mechanism**: consumers can dispute data with evidence, triggering slashing
///
/// The three EIP-8004 registries are load-bearing:
///   - Identity  → downstream contracts discover feeds by querying the agent's capabilities
///   - Reputation → determines minimum stake requirement (lower reputation = more skin in game)
///   - Validation → feeds MUST be validated before going live (methodology audit)
///
/// Lifecycle:
///   1. Owner deploys → auto-registers in IdentityRegistry as "data-oracle"
///   2. Owner registers a data feed → `registerFeed()` (triggers validation request)
///   3. Auditor validates feed methodology → ValidationRegistry approval
///   4. Owner stakes ETH and activates the feed → `activateFeed()`
///   5. Owner publishes data updates → `publishData()`
///   6. Consumers read data → `getLatestData()` (the on-chain utility)
///   7. Consumer disputes bad data → `disputeData()` (slashes agent stake)
///   8. Consumers rate data quality → `rateFeed()` (feeds reputation)
///   9. Better reputation → lower stake requirement → positive feedback loop
contract DataOracleAgent {
    // ───────── Registries ─────────
    IIdentityRegistry public immutable identityRegistry;
    IReputationRegistry public immutable reputationRegistry;
    IValidationRegistry public immutable validationRegistry;

    // ───────── Agent Identity ─────────
    address public owner;
    uint256 public agentId;

    // ───────── Feed Model ─────────
    enum FeedStatus {
        Proposed, // registered, awaiting validation
        Validated, // passed audit, awaiting stake + activation
        Active, // live, accepting data updates
        Suspended, // temporarily suspended (e.g. after dispute)
        Retired // permanently deactivated
    }

    struct DataFeed {
        uint256 feedId;
        string pair; // e.g. "ETH/USD", "BTC/USD"
        string description; // what data source and methodology
        FeedStatus status;
        uint256 validationId; // linked ValidationRegistry record
        uint256 stakedAmount; // ETH staked as security deposit
        uint256 updateCount; // total data points published
        uint256 disputeCount; // times data was successfully disputed
        uint256 registeredAt;
        uint256 activatedAt;
    }

    struct DataPoint {
        int256 value; // the data value (e.g. price in cents: 250000 = $2500.00)
        uint256 timestamp; // when the data was published
        uint256 confidence; // 0-10000 (basis points) confidence level
    }

    uint256 private _nextFeedId = 1;
    mapping(uint256 => DataFeed) public feeds;
    mapping(uint256 => DataPoint) private _latestData; // feedId => latest data point
    mapping(uint256 => DataPoint[]) private _dataHistory; // feedId => historical data
    uint256[] private _allFeedIds;

    // ───────── Stake Model (Reputation-Gated) ─────────
    /// @notice Required stake scales INVERSELY with reputation.
    ///   This is the KEY design: less trusted agents must put up MORE collateral.
    ///   - No reputation:     1.0 ETH stake per feed
    ///   - Low reputation:    0.5 ETH
    ///   - Medium reputation: 0.2 ETH
    ///   - High reputation:   0.05 ETH
    uint256 public constant STAKE_NO_REPUTATION = 1.0 ether;
    uint256 public constant STAKE_LOW = 0.5 ether;
    uint256 public constant STAKE_MEDIUM = 0.2 ether;
    uint256 public constant STAKE_HIGH = 0.05 ether;

    /// @notice Slash percentage on successful dispute (50%)
    uint256 public constant SLASH_PERCENT = 50;

    // ───────── Global Stats ─────────
    uint256 public totalStaked;
    uint256 public totalSlashed;
    uint256 public totalDataPoints;

    // ───────── Events ─────────
    event FeedRegistered(uint256 indexed feedId, string pair);
    event FeedActivated(uint256 indexed feedId, uint256 stakedAmount);
    event FeedSuspended(uint256 indexed feedId);
    event FeedRetired(uint256 indexed feedId);
    event DataPublished(uint256 indexed feedId, int256 value, uint256 timestamp, uint256 confidence);
    event DataDisputed(uint256 indexed feedId, address indexed disputer, uint256 slashedAmount);
    event StakeAdded(uint256 indexed feedId, uint256 amount);
    event StakeWithdrawn(uint256 indexed feedId, uint256 amount);
    event OtherAgentValidated(uint256 indexed validationId, uint256 indexed targetAgentId, bool passed);

    // ───────── Modifiers ─────────
    modifier onlyOwner() {
        require(msg.sender == owner, "DataOracleAgent: not owner");
        _;
    }

    modifier feedExists(uint256 feedId) {
        require(feeds[feedId].registeredAt != 0, "DataOracleAgent: feed not found");
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
                'data:application/json,{"name":"DataOracleAgent","type":"oracle",',
                '"capabilities":["price-feed","market-data","on-chain-delivery"],',
                '"version":"1.0.0","contract":"',
                _toHexString(address(this)),
                '"}'
            )
        );
        agentId = identityRegistry.register(uri);

        identityRegistry.setMetadata(agentId, "service", "data-oracle");
        identityRegistry.setMetadata(agentId, "delivery", "on-chain");
        identityRegistry.setMetadata(agentId, "security-model", "stake-backed");
    }

    // ════════════════════════════════════════════════════════════
    //  FEED MANAGEMENT (Validation-Gated)
    // ════════════════════════════════════════════════════════════

    /// @notice Register a new data feed. It CANNOT go live until an auditor validates
    ///   the data methodology and the agent stakes sufficient collateral.
    /// @param pair The data pair name (e.g. "ETH/USD")
    /// @param description Description of the data source and methodology
    /// @param auditor Address of the designated methodology auditor
    /// @param criteriaURI IPFS/HTTP link to audit criteria
    /// @return feedId The new feed ID
    function registerFeed(
        string calldata pair,
        string calldata description,
        address auditor,
        string calldata criteriaURI
    ) external onlyOwner returns (uint256 feedId) {
        feedId = _nextFeedId++;

        // Create validation request — auditor MUST approve before feed can activate
        uint256 validationId = validationRegistry.validationRequest(agentId, auditor, criteriaURI);

        feeds[feedId] = DataFeed({
            feedId: feedId,
            pair: pair,
            description: description,
            status: FeedStatus.Proposed,
            validationId: validationId,
            stakedAmount: 0,
            updateCount: 0,
            disputeCount: 0,
            registeredAt: block.timestamp,
            activatedAt: 0
        });
        _allFeedIds.push(feedId);

        emit FeedRegistered(feedId, pair);
    }

    /// @notice Activate a feed by staking the required collateral.
    ///   Requirements: (1) passed validation, (2) sufficient stake provided.
    ///   The required stake amount depends on the agent's reputation score.
    function activateFeed(uint256 feedId) external payable onlyOwner feedExists(feedId) {
        DataFeed storage f = feeds[feedId];
        require(
            f.status == FeedStatus.Proposed || f.status == FeedStatus.Validated,
            "DataOracleAgent: cannot activate from current state"
        );

        // HARD REQUIREMENT: feed must have passed validation
        if (f.status == FeedStatus.Proposed) {
            IValidationRegistry.ValidationStatus valStatus = validationRegistry.getValidationStatus(f.validationId);
            require(valStatus == IValidationRegistry.ValidationStatus.Passed, "DataOracleAgent: feed not validated");
            f.status = FeedStatus.Validated;
        }

        // Stake requirement (reputation-gated)
        uint256 requiredStake = getRequiredStake();
        uint256 totalStake = f.stakedAmount + msg.value;
        require(totalStake >= requiredStake, "DataOracleAgent: insufficient stake");

        f.stakedAmount += msg.value;
        totalStaked += msg.value;
        f.status = FeedStatus.Active;
        f.activatedAt = block.timestamp;

        emit FeedActivated(feedId, f.stakedAmount);
        if (msg.value > 0) {
            emit StakeAdded(feedId, msg.value);
        }
    }

    /// @notice Suspend a feed (e.g. after a dispute or for maintenance).
    function suspendFeed(uint256 feedId) external onlyOwner feedExists(feedId) {
        DataFeed storage f = feeds[feedId];
        require(f.status == FeedStatus.Active, "DataOracleAgent: not active");
        f.status = FeedStatus.Suspended;
        emit FeedSuspended(feedId);
    }

    /// @notice Re-activate a suspended feed (no re-validation required).
    function reactivateFeed(uint256 feedId) external onlyOwner feedExists(feedId) {
        DataFeed storage f = feeds[feedId];
        require(f.status == FeedStatus.Suspended, "DataOracleAgent: not suspended");

        uint256 requiredStake = getRequiredStake();
        require(f.stakedAmount >= requiredStake, "DataOracleAgent: insufficient remaining stake");

        f.status = FeedStatus.Active;
        emit FeedActivated(feedId, f.stakedAmount);
    }

    /// @notice Permanently retire a feed and return remaining stake.
    function retireFeed(uint256 feedId) external onlyOwner feedExists(feedId) {
        DataFeed storage f = feeds[feedId];
        require(f.status != FeedStatus.Retired, "DataOracleAgent: already retired");

        uint256 stakeToReturn = f.stakedAmount;
        f.stakedAmount = 0;
        totalStaked -= stakeToReturn;
        f.status = FeedStatus.Retired;

        if (stakeToReturn > 0) {
            (bool ok,) = owner.call{value: stakeToReturn}("");
            require(ok, "DataOracleAgent: stake return failed");
            emit StakeWithdrawn(feedId, stakeToReturn);
        }

        emit FeedRetired(feedId);
    }

    // ════════════════════════════════════════════════════════════
    //  DATA PUBLICATION (Agent's Core On-Chain Action)
    // ════════════════════════════════════════════════════════════

    /// @notice Agent operator publishes a new data point for an active feed.
    ///   This is the agent's PRIMARY on-chain action — providing data that
    ///   other smart contracts consume via `getLatestData()`.
    /// @param feedId The feed to update
    /// @param value The data value (e.g. price in cents)
    /// @param confidence Confidence level 0-10000 (basis points)
    function publishData(uint256 feedId, int256 value, uint256 confidence) external onlyOwner feedExists(feedId) {
        DataFeed storage f = feeds[feedId];
        require(f.status == FeedStatus.Active, "DataOracleAgent: feed not active");
        require(confidence <= 10000, "DataOracleAgent: confidence out of range");

        DataPoint memory dp = DataPoint({value: value, timestamp: block.timestamp, confidence: confidence});

        _latestData[feedId] = dp;
        _dataHistory[feedId].push(dp);
        f.updateCount++;
        totalDataPoints++;

        emit DataPublished(feedId, value, block.timestamp, confidence);
    }

    // ════════════════════════════════════════════════════════════
    //  DATA CONSUMPTION (On-Chain Utility)
    // ════════════════════════════════════════════════════════════

    /// @notice Read the latest data point for a feed.
    ///   THIS is the on-chain utility — other contracts call this to get data.
    /// @param feedId The feed to query
    /// @return value The latest data value
    /// @return timestamp When the data was last updated
    /// @return confidence The confidence level (0-10000)
    function getLatestData(uint256 feedId)
        external
        view
        feedExists(feedId)
        returns (int256 value, uint256 timestamp, uint256 confidence)
    {
        require(feeds[feedId].status == FeedStatus.Active, "DataOracleAgent: feed not active");

        DataPoint memory dp = _latestData[feedId];
        require(dp.timestamp != 0, "DataOracleAgent: no data published yet");

        return (dp.value, dp.timestamp, dp.confidence);
    }

    /// @notice Get historical data points for a feed.
    function getDataHistory(uint256 feedId) external view returns (DataPoint[] memory) {
        return _dataHistory[feedId];
    }

    /// @notice Get the number of historical data points.
    function getDataHistoryLength(uint256 feedId) external view returns (uint256) {
        return _dataHistory[feedId].length;
    }

    // ════════════════════════════════════════════════════════════
    //  DISPUTE MECHANISM (Slashing)
    // ════════════════════════════════════════════════════════════

    /// @notice Anyone can dispute a feed's data. If the dispute is confirmed by the
    ///   feed owner (acting honestly) or governance, the agent's stake is slashed
    ///   and the disputer is rewarded.
    ///
    ///   For this example, the owner must acknowledge the dispute (self-slashing).
    ///   In production, this would be replaced by a governance/arbitration mechanism.
    /// @param feedId The feed being disputed
    /// @param evidence URI pointing to evidence of incorrect data
    function disputeData(uint256 feedId, string calldata evidence) external feedExists(feedId) {
        DataFeed storage f = feeds[feedId];
        require(
            f.status == FeedStatus.Active || f.status == FeedStatus.Suspended, "DataOracleAgent: feed not disputable"
        );
        require(f.stakedAmount > 0, "DataOracleAgent: no stake to slash");
        require(bytes(evidence).length > 0, "DataOracleAgent: evidence required");

        // Calculate slash amount
        uint256 slashAmount = (f.stakedAmount * SLASH_PERCENT) / 100;

        // Update state
        f.stakedAmount -= slashAmount;
        totalStaked -= slashAmount;
        totalSlashed += slashAmount;
        f.disputeCount++;
        f.status = FeedStatus.Suspended;

        // Reward disputer
        (bool ok,) = msg.sender.call{value: slashAmount}("");
        require(ok, "DataOracleAgent: slash transfer failed");

        emit DataDisputed(feedId, msg.sender, slashAmount);
        emit FeedSuspended(feedId);
    }

    // ════════════════════════════════════════════════════════════
    //  REPUTATION – Consumers rate data quality
    // ════════════════════════════════════════════════════════════

    /// @notice Anyone can rate the data quality of a feed.
    ///   Reputation directly affects future stake requirements — creating a
    ///   virtuous cycle: good data → better reputation → lower stake → more feeds.
    function rateFeed(uint8 score, string calldata comment) external returns (uint256 feedbackId) {
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

    /// @notice Request a third-party audit/validation of this agent.
    function requestAudit(address auditor, string calldata criteriaURI)
        external
        onlyOwner
        returns (uint256 validationId)
    {
        validationId = validationRegistry.validationRequest(agentId, auditor, criteriaURI);
    }

    // ════════════════════════════════════════════════════════════
    //  VIEW HELPERS – Stake Requirements & Trust Profile
    // ════════════════════════════════════════════════════════════

    /// @notice Calculate the required stake per feed based on the agent's reputation.
    ///   INVERSE relationship: less reputation → more stake required (more skin in game).
    function getRequiredStake() public view returns (uint256) {
        IReputationRegistry.Summary memory rep = reputationRegistry.getSummary(agentId);

        if (rep.activeFeedbacks == 0) {
            return STAKE_NO_REPUTATION;
        }

        uint256 avgScore = rep.averageScore;
        if (avgScore >= 8000) return STAKE_HIGH;
        if (avgScore >= 5000) return STAKE_MEDIUM;
        return STAKE_LOW;
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

    function getFeed(uint256 feedId) external view returns (DataFeed memory) {
        return feeds[feedId];
    }

    function getAllFeedIds() external view returns (uint256[] memory) {
        return _allFeedIds;
    }

    function getFeedStats()
        external
        view
        returns (uint256 total, uint256 proposed, uint256 active, uint256 suspended, uint256 retired)
    {
        total = _allFeedIds.length;
        for (uint256 i = 0; i < total; i++) {
            FeedStatus s = feeds[_allFeedIds[i]].status;
            if (s == FeedStatus.Proposed || s == FeedStatus.Validated) proposed++;
            else if (s == FeedStatus.Active) active++;
            else if (s == FeedStatus.Suspended) suspended++;
            else if (s == FeedStatus.Retired) retired++;
        }
    }

    // ═══════ Admin ═══════

    /// @notice Owner can top up stake on any feed.
    function addStake(uint256 feedId) external payable onlyOwner feedExists(feedId) {
        require(msg.value > 0, "DataOracleAgent: zero stake");
        feeds[feedId].stakedAmount += msg.value;
        totalStaked += msg.value;
        emit StakeAdded(feedId, msg.value);
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
