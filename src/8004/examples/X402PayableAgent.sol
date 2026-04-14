// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "../interfaces/IReputationRegistry.sol";
import {IValidationRegistry} from "../interfaces/IValidationRegistry.sol";

/// @title X402PayableAgent - x402 payment protocol + EIP-8004 trust (load-bearing)
/// @notice Demonstrates an AI translation agent where x402's per-request payment
///   pattern is integrated with EIP-8004 in a **structurally necessary** way.
///
/// Why EIP-8004 is load-bearing here (not cosmetic):
///   - **Identity**: Declares validated capabilities; clients discover what the agent can do
///   - **Validation**: Each service capability (translate, summarize, sentiment) MUST be
///     validated by a third-party auditor before it can be offered to clients.
///     No validation = no service = no revenue.
///   - **Reputation**: Directly gates which pricing tiers clients can access:
///     - basic tier:      always (with validated capability)
///     - premium tier:    requires agent reputation >= 50
///     - enterprise tier: requires agent reputation >= 80
///     Higher reputation -> higher-value clients -> more revenue
contract X402PayableAgent {
    // ───────── EIP-8004 Registries ─────────
    IIdentityRegistry public immutable identityRegistry;
    IReputationRegistry public immutable reputationRegistry;
    IValidationRegistry public immutable validationRegistry;

    // ───────── Agent Identity ─────────
    address public owner;
    uint256 public agentId;

    // ───────── x402-style Facilitator ─────────
    address public facilitator;

    // ───────── Service Capabilities (Validation-Gated) ─────────
    /// @notice Each service capability MUST be validated before it can be offered.
    struct Capability {
        string serviceType;
        uint256 validationId;
        bool validated;
        uint256 registeredAt;
    }

    mapping(string => Capability) public capabilities;
    string[] private _capabilityNames;

    // ───────── x402-style Service Tiers (Reputation-Gated) ─────────
    enum TierLevel {
        Basic,
        Premium,
        Enterprise
    }

    struct ServiceTier {
        uint256 tierId;
        string name;
        string scheme;
        uint256 priceWei;
        uint256 maxTimeout;
        TierLevel level;
        bool active;
    }

    uint256 private _nextTierId = 1;
    mapping(uint256 => ServiceTier) public tiers;
    uint256[] private _allTierIds;

    uint256 public constant PREMIUM_THRESHOLD = 5000;
    uint256 public constant ENTERPRISE_THRESHOLD = 8000;

    // ───────── Service Request Model ─────────
    enum RequestStatus {
        PendingPayment,
        Verified,
        Fulfilled,
        Settled,
        Refunded,
        Expired
    }

    struct ServiceRequest {
        uint256 requestId;
        address client;
        uint256 tierId;
        string serviceType;
        string inputData;
        RequestStatus status;
        string result;
        uint256 paymentAmount;
        uint256 requestedAt;
        uint256 verifiedAt;
        uint256 fulfilledAt;
        uint256 settledAt;
    }

    uint256 private _nextRequestId = 1;
    mapping(uint256 => ServiceRequest) private _requests;
    uint256[] private _allRequestIds;

    // ───────── Payment Escrow ─────────
    mapping(uint256 => bool) private _settled;

    // ───────── Stats ─────────
    uint256 public totalRevenue;
    uint256 public totalRefunded;
    uint256 public totalRequests;

    // ───────── Events ─────────
    event CapabilityRegistered(string serviceType, uint256 indexed validationId);
    event CapabilityValidated(string serviceType);
    event PaymentRequirementUpdated(uint256 indexed tierId, string name, uint256 priceWei, string tierLevel);
    event PaymentReceived(uint256 indexed requestId, address indexed client, uint256 amount, uint256 tierId);
    event PaymentVerified(uint256 indexed requestId, address indexed facilitator);
    event PaymentSettled(uint256 indexed requestId, uint256 amount);
    event PaymentRefunded(uint256 indexed requestId, uint256 amount);
    event ServiceFulfilled(uint256 indexed requestId, string serviceType);
    event ServiceExpired(uint256 indexed requestId);
    event DataAuditRequested(uint256 indexed validationId, address indexed auditor);
    event FacilitatorUpdated(address indexed oldFacilitator, address indexed newFacilitator);

    // ───────── Modifiers ─────────
    modifier onlyOwner() {
        require(msg.sender == owner, "X402PayableAgent: not owner");
        _;
    }

    modifier onlyFacilitator() {
        require(msg.sender == facilitator, "X402PayableAgent: not facilitator");
        _;
    }

    modifier onlyOwnerOrFacilitator() {
        require(msg.sender == owner || msg.sender == facilitator, "X402PayableAgent: not authorized");
        _;
    }

    modifier requestExists(uint256 requestId) {
        require(_requests[requestId].requestedAt != 0, "X402PayableAgent: request not found");
        _;
    }

    // ───────── Constructor ─────────
    constructor(address _idReg, address _repReg, address _valReg, address _facilitator) {
        require(_facilitator != address(0), "X402PayableAgent: zero facilitator");

        owner = msg.sender;
        facilitator = _facilitator;
        identityRegistry = IIdentityRegistry(_idReg);
        reputationRegistry = IReputationRegistry(_repReg);
        validationRegistry = IValidationRegistry(_valReg);

        // ── Auto-register in EIP-8004 Identity Registry ──
        string memory uri = string(
            abi.encodePacked(
                'data:application/json,{"name":"X402PayableAgent",',
                '"type":"service","protocol":"x402+eip8004",',
                '"capabilities":["translate","summarize","sentiment"],',
                '"paymentScheme":"exact","version":"2.0.0",',
                '"contract":"',
                _toHexString(address(this)),
                '"}'
            )
        );
        agentId = identityRegistry.register(uri);

        identityRegistry.setMetadata(agentId, "service", "ai-translation");
        identityRegistry.setMetadata(agentId, "payment-protocol", "x402-exact");
        identityRegistry.setMetadata(agentId, "settlement", "eth-escrow");
        identityRegistry.setMetadata(agentId, "facilitator", _toHexString(_facilitator));

        // Create default pricing tiers (reputation-gated)
        _createTier("basic", 0.001 ether, 1 hours, TierLevel.Basic);
        _createTier("premium", 0.005 ether, 2 hours, TierLevel.Premium);
        _createTier("enterprise", 0.02 ether, 4 hours, TierLevel.Enterprise);
    }

    // ════════════════════════════════════════════════════════════
    //  SERVICE CAPABILITIES (Validation-Gated)
    // ════════════════════════════════════════════════════════════

    /// @notice Owner registers a new service capability. It CANNOT be offered to clients
    ///   until a third-party auditor validates the quality of this service type.
    function registerCapability(string calldata serviceType, address auditor, string calldata criteriaURI)
        external
        onlyOwner
    {
        require(capabilities[serviceType].registeredAt == 0, "X402PayableAgent: capability exists");

        uint256 validationId = validationRegistry.validationRequest(agentId, auditor, criteriaURI);

        capabilities[serviceType] = Capability({
            serviceType: serviceType, validationId: validationId, validated: false, registeredAt: block.timestamp
        });
        _capabilityNames.push(serviceType);

        emit CapabilityRegistered(serviceType, validationId);
    }

    /// @notice Check if a capability's validation has passed and cache the result.
    function refreshCapabilityStatus(string calldata serviceType) external {
        Capability storage cap = capabilities[serviceType];
        require(cap.registeredAt != 0, "X402PayableAgent: capability not found");

        if (!cap.validated) {
            IValidationRegistry.ValidationStatus status = validationRegistry.getValidationStatus(cap.validationId);
            if (status == IValidationRegistry.ValidationStatus.Passed) {
                cap.validated = true;
                emit CapabilityValidated(serviceType);
            }
        }
    }

    /// @notice Check if a specific service type is validated and available.
    function isCapabilityValidated(string calldata serviceType) external view returns (bool) {
        Capability storage cap = capabilities[serviceType];
        if (cap.registeredAt == 0) return false;
        if (cap.validated) return true;

        IValidationRegistry.ValidationStatus status = validationRegistry.getValidationStatus(cap.validationId);
        return status == IValidationRegistry.ValidationStatus.Passed;
    }

    /// @notice Returns all registered capabilities and their validation status.
    function getCapabilities() external view returns (string[] memory names, bool[] memory validated) {
        names = _capabilityNames;
        validated = new bool[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            Capability storage cap = capabilities[names[i]];
            validated[i] = cap.validated
                || validationRegistry.getValidationStatus(cap.validationId)
                    == IValidationRegistry.ValidationStatus.Passed;
        }
    }

    // ════════════════════════════════════════════════════════════
    //  x402 PAYMENT REQUIREMENTS (≈ 402 Response)
    // ════════════════════════════════════════════════════════════

    /// @notice Returns payment tiers filtered by the agent's reputation.
    function getPaymentRequirements() external view returns (ServiceTier[] memory activeTiers) {
        uint256 maxLevel = _getMaxTierLevel();

        uint256 count;
        for (uint256 i = 0; i < _allTierIds.length; i++) {
            ServiceTier storage t = tiers[_allTierIds[i]];
            if (t.active && uint8(t.level) <= maxLevel) count++;
        }

        activeTiers = new ServiceTier[](count);
        uint256 idx;
        for (uint256 i = 0; i < _allTierIds.length; i++) {
            ServiceTier storage t = tiers[_allTierIds[i]];
            if (t.active && uint8(t.level) <= maxLevel) {
                activeTiers[idx++] = t;
            }
        }
    }

    /// @notice Returns ALL tiers regardless of reputation (for informational purposes).
    function getAllTiers() external view returns (ServiceTier[] memory allTiers) {
        uint256 count;
        for (uint256 i = 0; i < _allTierIds.length; i++) {
            if (tiers[_allTierIds[i]].active) count++;
        }
        allTiers = new ServiceTier[](count);
        uint256 idx;
        for (uint256 i = 0; i < _allTierIds.length; i++) {
            if (tiers[_allTierIds[i]].active) {
                allTiers[idx++] = tiers[_allTierIds[i]];
            }
        }
    }

    /// @notice Owner adds a new service tier with a reputation level requirement.
    function addServiceTier(string calldata name, uint256 priceWei, uint256 maxTimeout, TierLevel level)
        external
        onlyOwner
        returns (uint256 tierId)
    {
        tierId = _createTier(name, priceWei, maxTimeout, level);
    }

    /// @notice Owner updates a tier's price.
    function updateTierPrice(uint256 tierId, uint256 newPrice) external onlyOwner {
        require(tiers[tierId].tierId != 0, "X402PayableAgent: tier not found");
        tiers[tierId].priceWei = newPrice;
        emit PaymentRequirementUpdated(tierId, tiers[tierId].name, newPrice, _tierLevelName(tiers[tierId].level));
    }

    /// @notice Owner deactivates a tier.
    function deactivateTier(uint256 tierId) external onlyOwner {
        require(tiers[tierId].tierId != 0, "X402PayableAgent: tier not found");
        tiers[tierId].active = false;
    }

    // ════════════════════════════════════════════════════════════
    //  x402 PAYMENT + SERVICE REQUEST
    // ════════════════════════════════════════════════════════════

    /// @notice Client requests a service by paying for a selected tier.
    ///   Two gates are enforced:
    ///   1. The requested service type MUST be a validated capability
    ///   2. The selected tier MUST be accessible given the agent's reputation
    function requestService(uint256 tierId, string calldata serviceType, string calldata inputData)
        external
        payable
        returns (uint256 requestId)
    {
        // Gate 1: Capability must be validated
        require(_isCapabilityValid(serviceType), "X402PayableAgent: capability not validated");

        // Gate 2: Tier must be accessible
        ServiceTier storage tier = tiers[tierId];
        require(tier.tierId != 0 && tier.active, "X402PayableAgent: invalid tier");
        require(_isTierAccessible(tier.level), "X402PayableAgent: tier requires higher reputation");

        require(msg.value >= tier.priceWei, "X402PayableAgent: insufficient payment");

        requestId = _nextRequestId++;
        _requests[requestId] = ServiceRequest({
            requestId: requestId,
            client: msg.sender,
            tierId: tierId,
            serviceType: serviceType,
            inputData: inputData,
            status: RequestStatus.PendingPayment,
            result: "",
            paymentAmount: msg.value,
            requestedAt: block.timestamp,
            verifiedAt: 0,
            fulfilledAt: 0,
            settledAt: 0
        });
        _allRequestIds.push(requestId);
        totalRequests++;

        emit PaymentReceived(requestId, msg.sender, msg.value, tierId);
    }

    // ════════════════════════════════════════════════════════════
    //  x402 FACILITATOR: VERIFY
    // ════════════════════════════════════════════════════════════

    function verifyPayment(uint256 requestId) external onlyFacilitator requestExists(requestId) {
        ServiceRequest storage req = _requests[requestId];
        require(req.status == RequestStatus.PendingPayment, "X402PayableAgent: not pending");

        ServiceTier storage tier = tiers[req.tierId];

        require(req.paymentAmount >= tier.priceWei, "X402PayableAgent: payment amount mismatch");
        require(block.timestamp <= req.requestedAt + tier.maxTimeout, "X402PayableAgent: payment expired");

        req.status = RequestStatus.Verified;
        req.verifiedAt = block.timestamp;

        emit PaymentVerified(requestId, msg.sender);
    }

    // ════════════════════════════════════════════════════════════
    //  SERVICE FULFILLMENT
    // ════════════════════════════════════════════════════════════

    /// @notice Agent operator fulfills a verified request with a result.
    function fulfillService(uint256 requestId, string calldata result) external onlyOwner requestExists(requestId) {
        ServiceRequest storage req = _requests[requestId];
        require(req.status == RequestStatus.Verified, "X402PayableAgent: not verified");

        req.status = RequestStatus.Fulfilled;
        req.result = result;
        req.fulfilledAt = block.timestamp;

        emit ServiceFulfilled(requestId, req.serviceType);
    }

    // ════════════════════════════════════════════════════════════
    //  x402 FACILITATOR: SETTLE
    // ════════════════════════════════════════════════════════════

    function settlePayment(uint256 requestId) external onlyFacilitator requestExists(requestId) {
        ServiceRequest storage req = _requests[requestId];
        require(req.status == RequestStatus.Fulfilled, "X402PayableAgent: not fulfilled");
        require(!_settled[requestId], "X402PayableAgent: already settled");

        _settled[requestId] = true;
        req.status = RequestStatus.Settled;
        req.settledAt = block.timestamp;
        totalRevenue += req.paymentAmount;

        (bool ok,) = owner.call{value: req.paymentAmount}("");
        require(ok, "X402PayableAgent: settlement transfer failed");

        emit PaymentSettled(requestId, req.paymentAmount);
    }

    // ════════════════════════════════════════════════════════════
    //  REFUND
    // ════════════════════════════════════════════════════════════

    /// @notice Refund payment to client.
    function refundPayment(uint256 requestId) external onlyOwnerOrFacilitator requestExists(requestId) {
        ServiceRequest storage req = _requests[requestId];
        require(
            req.status == RequestStatus.PendingPayment || req.status == RequestStatus.Verified,
            "X402PayableAgent: cannot refund in current state"
        );
        require(!_settled[requestId], "X402PayableAgent: already settled");

        _settled[requestId] = true;
        req.status = RequestStatus.Refunded;
        totalRefunded += req.paymentAmount;

        (bool ok,) = req.client.call{value: req.paymentAmount}("");
        require(ok, "X402PayableAgent: refund transfer failed");

        emit PaymentRefunded(requestId, req.paymentAmount);
    }

    /// @notice Mark expired requests. Anyone can call this for requests past timeout.
    function markExpired(uint256 requestId) external requestExists(requestId) {
        ServiceRequest storage req = _requests[requestId];
        require(req.status == RequestStatus.PendingPayment, "X402PayableAgent: not pending");

        ServiceTier storage tier = tiers[req.tierId];
        require(block.timestamp > req.requestedAt + tier.maxTimeout, "X402PayableAgent: not yet expired");

        _settled[requestId] = true;
        req.status = RequestStatus.Expired;
        totalRefunded += req.paymentAmount;

        (bool ok,) = req.client.call{value: req.paymentAmount}("");
        require(ok, "X402PayableAgent: expiry refund failed");

        emit ServiceExpired(requestId);
        emit PaymentRefunded(requestId, req.paymentAmount);
    }

    // ════════════════════════════════════════════════════════════
    //  EIP-8004: REPUTATION
    // ════════════════════════════════════════════════════════════

    /// @notice Client rates a settled service. Reputation directly affects
    ///   which tiers are available — creating a virtuous cycle.
    function rateService(uint256 requestId, uint8 score, string calldata comment)
        external
        requestExists(requestId)
        returns (uint256 feedbackId)
    {
        ServiceRequest storage req = _requests[requestId];
        require(req.client == msg.sender, "X402PayableAgent: not client");
        require(req.status == RequestStatus.Settled, "X402PayableAgent: not settled");

        feedbackId = reputationRegistry.giveFeedback(agentId, score, comment);
    }

    /// @notice Agent owner responds to feedback.
    function respondToFeedback(uint256 feedbackId, string calldata response) external onlyOwner {
        reputationRegistry.appendResponse(feedbackId, response);
    }

    // ════════════════════════════════════════════════════════════
    //  EIP-8004: VALIDATION
    // ════════════════════════════════════════════════════════════

    /// @notice Owner requests a general audit of the agent.
    function requestDataAudit(address auditor, string calldata criteriaURI)
        external
        onlyOwner
        returns (uint256 validationId)
    {
        validationId = validationRegistry.validationRequest(agentId, auditor, criteriaURI);
        emit DataAuditRequested(validationId, auditor);
    }

    // ════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ════════════════════════════════════════════════════════════

    /// @notice Returns the maximum tier level accessible given the agent's reputation.
    function getAccessibleTierLevel() external view returns (string memory) {
        uint256 level = _getMaxTierLevel();
        if (level >= 2) return "enterprise";
        if (level >= 1) return "premium";
        return "basic";
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

    function getRequest(uint256 requestId) external view returns (ServiceRequest memory) {
        return _requests[requestId];
    }

    function getAllRequestIds() external view returns (uint256[] memory) {
        return _allRequestIds;
    }

    /// @notice Aggregate service statistics.
    function getServiceStats()
        external
        view
        returns (
            uint256 total,
            uint256 pendingPayment,
            uint256 verified,
            uint256 fulfilled,
            uint256 settled,
            uint256 refunded,
            uint256 expired
        )
    {
        total = _allRequestIds.length;
        for (uint256 i = 0; i < _allRequestIds.length; i++) {
            RequestStatus s = _requests[_allRequestIds[i]].status;
            if (s == RequestStatus.PendingPayment) pendingPayment++;
            else if (s == RequestStatus.Verified) verified++;
            else if (s == RequestStatus.Fulfilled) fulfilled++;
            else if (s == RequestStatus.Settled) settled++;
            else if (s == RequestStatus.Refunded) refunded++;
            else expired++;
        }
    }

    /// @notice Revenue metrics.
    function getRevenueStats()
        external
        view
        returns (uint256 revenue, uint256 refunds, uint256 escrowBalance, uint256 requestCount)
    {
        revenue = totalRevenue;
        refunds = totalRefunded;
        escrowBalance = address(this).balance;
        requestCount = totalRequests;
    }

    // ════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════

    /// @notice Update the facilitator address.
    function setFacilitator(address newFacilitator) external onlyOwner {
        require(newFacilitator != address(0), "X402PayableAgent: zero address");
        address old = facilitator;
        facilitator = newFacilitator;
        identityRegistry.setMetadata(agentId, "facilitator", _toHexString(newFacilitator));
        emit FacilitatorUpdated(old, newFacilitator);
    }

    // ═══════ Internal ═══════

    function _createTier(string memory name, uint256 priceWei, uint256 maxTimeout, TierLevel level)
        internal
        returns (uint256 tierId)
    {
        tierId = _nextTierId++;
        tiers[tierId] = ServiceTier({
            tierId: tierId,
            name: name,
            scheme: "exact",
            priceWei: priceWei,
            maxTimeout: maxTimeout,
            level: level,
            active: true
        });
        _allTierIds.push(tierId);
        emit PaymentRequirementUpdated(tierId, name, priceWei, _tierLevelName(level));
    }

    function _isCapabilityValid(string calldata serviceType) internal view returns (bool) {
        Capability storage cap = capabilities[serviceType];
        if (cap.registeredAt == 0) return false;
        if (cap.validated) return true;

        IValidationRegistry.ValidationStatus status = validationRegistry.getValidationStatus(cap.validationId);
        return status == IValidationRegistry.ValidationStatus.Passed;
    }

    function _isTierAccessible(TierLevel level) internal view returns (bool) {
        if (level == TierLevel.Basic) return true;

        IReputationRegistry.Summary memory rep = reputationRegistry.getSummary(agentId);
        if (rep.activeFeedbacks == 0) return false;

        if (level == TierLevel.Premium) return rep.averageScore >= PREMIUM_THRESHOLD;
        if (level == TierLevel.Enterprise) return rep.averageScore >= ENTERPRISE_THRESHOLD;
        return false;
    }

    function _getMaxTierLevel() internal view returns (uint256) {
        IReputationRegistry.Summary memory rep = reputationRegistry.getSummary(agentId);
        if (rep.activeFeedbacks == 0) return 0;

        if (rep.averageScore >= ENTERPRISE_THRESHOLD) return 2;
        if (rep.averageScore >= PREMIUM_THRESHOLD) return 1;
        return 0;
    }

    function _tierLevelName(TierLevel level) internal pure returns (string memory) {
        if (level == TierLevel.Basic) return "basic";
        if (level == TierLevel.Premium) return "premium";
        return "enterprise";
    }

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
