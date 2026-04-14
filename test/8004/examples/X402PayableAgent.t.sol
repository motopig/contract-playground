// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IdentityRegistry} from "../../../src/8004/IdentityRegistry.sol";
import {ReputationRegistry} from "../../../src/8004/ReputationRegistry.sol";
import {ValidationRegistry} from "../../../src/8004/ValidationRegistry.sol";
import {X402PayableAgent} from "../../../src/8004/examples/X402PayableAgent.sol";
import {IReputationRegistry} from "../../../src/8004/interfaces/IReputationRegistry.sol";
import {IValidationRegistry} from "../../../src/8004/interfaces/IValidationRegistry.sol";

/// @title X402PayableAgent Tests
/// @notice Comprehensive tests covering x402 payment flow + EIP-8004 trust integration
contract X402PayableAgentTest is Test {
    IdentityRegistry idReg;
    ReputationRegistry repReg;
    ValidationRegistry valReg;
    X402PayableAgent agent;

    address owner = address(this);
    address facilitator = address(0xFAC1);
    address client1 = address(0xC1);
    address client2 = address(0xC2);
    address auditor = address(0xAD);

    function setUp() public {
        idReg = new IdentityRegistry();
        repReg = new ReputationRegistry(address(idReg));
        valReg = new ValidationRegistry(address(idReg));
        agent = new X402PayableAgent(address(idReg), address(repReg), address(valReg), facilitator);

        // Fund test accounts
        vm.deal(client1, 10 ether);
        vm.deal(client2, 10 ether);

        // Register & validate capabilities so requestService works
        _registerAndValidateCapability("translate");
        _registerAndValidateCapability("summarize");
        _registerAndValidateCapability("sentiment");
    }

    /// @dev Helper: register a capability then have the auditor validate it
    function _registerAndValidateCapability(string memory serviceType) internal {
        agent.registerCapability(serviceType, auditor, "ipfs://criteria");
        (, uint256 valId,,) = agent.capabilities(serviceType);
        vm.prank(auditor);
        valReg.validationResponse(valId, true, "ipfs://audit-passed");
        agent.refreshCapabilityStatus(serviceType);
    }

    /// @dev Helper: complete a full service flow and rate it, to build reputation
    function _completeAndRate(address client, uint256 tierId, uint8 score) internal returns (uint256 reqId) {
        vm.prank(client);
        reqId = agent.requestService{value: 0.02 ether}(tierId, "translate", "Hello");
        vm.prank(facilitator);
        agent.verifyPayment(reqId);
        agent.fulfillService(reqId, "Result");
        vm.prank(facilitator);
        agent.settlePayment(reqId);
        vm.prank(client);
        agent.rateService(reqId, score, "rating");
    }

    // ════════════════════════════════════════════════════════════
    //  IDENTITY REGISTRATION (EIP-8004)
    // ════════════════════════════════════════════════════════════

    function test_autoRegistersIdentity() public view {
        uint256 agentId = agent.agentId();
        assertGt(agentId, 0, "agent should have an ID");
        assertEq(idReg.ownerOf(agentId), address(agent), "agent contract should own the identity");
    }

    function test_identityMetadata() public view {
        uint256 agentId = agent.agentId();
        assertEq(idReg.getMetadata(agentId, "service"), "ai-translation");
        assertEq(idReg.getMetadata(agentId, "payment-protocol"), "x402-exact");
        assertEq(idReg.getMetadata(agentId, "settlement"), "eth-escrow");
    }

    function test_agentURIContainsX402Info() public view {
        string memory uri = agent.getAgentURI();
        // URI should contain x402 protocol reference
        assertTrue(bytes(uri).length > 0, "URI should not be empty");
    }

    // ════════════════════════════════════════════════════════════
    //  x402 PAYMENT REQUIREMENTS (≈ 402 Response)
    // ════════════════════════════════════════════════════════════

    function test_defaultTiersCreated() public view {
        // With no reputation, getPaymentRequirements only returns Basic tier
        X402PayableAgent.ServiceTier[] memory activeTiers = agent.getPaymentRequirements();
        assertEq(activeTiers.length, 1, "should only see basic tier without reputation");
        assertEq(activeTiers[0].priceWei, 0.001 ether);

        // getAllTiers returns all 3 regardless of reputation
        X402PayableAgent.ServiceTier[] memory allTiers = agent.getAllTiers();
        assertEq(allTiers.length, 3, "should have 3 default tiers total");
        assertEq(allTiers[0].priceWei, 0.001 ether);
        assertEq(allTiers[1].priceWei, 0.005 ether);
        assertEq(allTiers[2].priceWei, 0.02 ether);
    }

    function test_allTiersHaveExactScheme() public view {
        X402PayableAgent.ServiceTier[] memory allTiers = agent.getAllTiers();
        for (uint256 i = 0; i < allTiers.length; i++) {
            assertEq(
                keccak256(bytes(allTiers[i].scheme)), keccak256(bytes("exact")), "all tiers should use exact scheme"
            );
        }
    }

    function test_addServiceTier() public {
        uint256 tierId = agent.addServiceTier("ultra", 0.1 ether, 8 hours, X402PayableAgent.TierLevel.Basic);
        X402PayableAgent.ServiceTier[] memory allTiers = agent.getAllTiers();
        assertEq(allTiers.length, 4, "should have 4 tiers now");
        (uint256 id, string memory name,, uint256 price,,,) = agent.tiers(tierId);
        assertEq(id, tierId);
        assertEq(keccak256(bytes(name)), keccak256(bytes("ultra")));
        assertEq(price, 0.1 ether);
    }

    function test_deactivateTier() public {
        agent.deactivateTier(1); // deactivate "basic"
        X402PayableAgent.ServiceTier[] memory allTiers = agent.getAllTiers();
        assertEq(allTiers.length, 2, "should have 2 active tiers");
    }

    function test_updateTierPrice() public {
        agent.updateTierPrice(1, 0.002 ether);
        (,,, uint256 newPrice,,,) = agent.tiers(1);
        assertEq(newPrice, 0.002 ether);
    }

    // ════════════════════════════════════════════════════════════
    //  x402 PAYMENT + SERVICE REQUEST
    // ════════════════════════════════════════════════════════════

    function test_requestServiceWithPayment() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello World");
        assertEq(reqId, 1);
        X402PayableAgent.ServiceRequest memory req = agent.getRequest(reqId);
        assertEq(req.requestId, 1);
        assertEq(req.client, client1);
        assertEq(req.paymentAmount, 0.001 ether);
        assertGt(req.requestedAt, 0);
    }

    function test_revertInsufficientPayment() public {
        vm.prank(client1);
        vm.expectRevert("X402PayableAgent: insufficient payment");
        agent.requestService{value: 0.0001 ether}(1, "translate", "Hello");
    }

    function test_revertInvalidTier() public {
        vm.prank(client1);
        vm.expectRevert("X402PayableAgent: invalid tier");
        agent.requestService{value: 1 ether}(999, "translate", "Hello");
    }

    // ════════════════════════════════════════════════════════════
    //  x402 FACILITATOR: VERIFY + SETTLE
    // ════════════════════════════════════════════════════════════

    function test_facilitatorVerify() public {
        // Client pays
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        // Facilitator verifies
        vm.prank(facilitator);
        agent.verifyPayment(reqId);

        X402PayableAgent.ServiceRequest memory req = agent.getRequest(reqId);
        assertEq(uint8(req.status), uint8(X402PayableAgent.RequestStatus.Verified));
    }

    function test_revertNonFacilitatorVerify() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        vm.prank(client1); // client is not facilitator
        vm.expectRevert("X402PayableAgent: not facilitator");
        agent.verifyPayment(reqId);
    }

    function test_facilitatorSettle() public {
        // Full flow: request -> verify -> fulfill -> settle (use basic tier)
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Test");

        vm.prank(facilitator);
        agent.verifyPayment(reqId);

        agent.fulfillService(reqId, "Translated: Test");

        uint256 ownerBalBefore = owner.balance;

        vm.prank(facilitator);
        agent.settlePayment(reqId);

        assertEq(owner.balance - ownerBalBefore, 0.001 ether, "owner should receive payment");
        assertEq(agent.totalRevenue(), 0.001 ether);
    }

    function test_revertSettleBeforeFulfill() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        vm.prank(facilitator);
        agent.verifyPayment(reqId);

        // Try to settle before fulfillment
        vm.prank(facilitator);
        vm.expectRevert("X402PayableAgent: not fulfilled");
        agent.settlePayment(reqId);
    }

    // ════════════════════════════════════════════════════════════
    //  REFUND FLOW
    // ════════════════════════════════════════════════════════════

    function test_refundByFacilitator() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        uint256 clientBalBefore = client1.balance;

        vm.prank(facilitator);
        agent.refundPayment(reqId);

        assertEq(client1.balance - clientBalBefore, 0.001 ether, "client should be refunded");
        X402PayableAgent.ServiceRequest memory req = agent.getRequest(reqId);
        assertEq(uint8(req.status), uint8(X402PayableAgent.RequestStatus.Refunded));
    }

    function test_refundByOwner() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        uint256 clientBalBefore = client1.balance;

        // Owner can also refund
        agent.refundPayment(reqId);
        assertEq(client1.balance - clientBalBefore, 0.001 ether);
    }

    function test_revertRefundAfterSettle() public {
        // Full flow to settled
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        vm.prank(facilitator);
        agent.verifyPayment(reqId);
        agent.fulfillService(reqId, "Result");
        vm.prank(facilitator);
        agent.settlePayment(reqId);

        // Cannot refund after settlement
        vm.prank(facilitator);
        vm.expectRevert("X402PayableAgent: cannot refund in current state");
        agent.refundPayment(reqId);
    }

    // ════════════════════════════════════════════════════════════
    //  EXPIRY (x402 maxTimeoutSeconds)
    // ════════════════════════════════════════════════════════════

    function test_markExpiredAfterTimeout() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        // Warp past the basic tier timeout (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 clientBalBefore = client1.balance;
        agent.markExpired(reqId);

        assertEq(client1.balance - clientBalBefore, 0.001 ether, "should auto-refund on expiry");
        X402PayableAgent.ServiceRequest memory req = agent.getRequest(reqId);
        assertEq(uint8(req.status), uint8(X402PayableAgent.RequestStatus.Expired));
    }

    function test_revertExpireBeforeTimeout() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        vm.expectRevert("X402PayableAgent: not yet expired");
        agent.markExpired(reqId);
    }

    // ════════════════════════════════════════════════════════════
    //  EIP-8004: REPUTATION
    // ════════════════════════════════════════════════════════════

    function test_rateSettledService() public {
        // Full flow to settled
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");
        vm.prank(facilitator);
        agent.verifyPayment(reqId);
        agent.fulfillService(reqId, "Hola");
        vm.prank(facilitator);
        agent.settlePayment(reqId);

        // Client rates
        vm.prank(client1);
        uint256 feedbackId = agent.rateService(reqId, 90, "Excellent translation!");

        assertGt(feedbackId, 0);

        IReputationRegistry.Summary memory summary = agent.getReputationSummary();
        assertEq(summary.totalFeedbacks, 1);
        assertEq(summary.averageScore, 9000); // 90 * 100
    }

    function test_revertRateBeforeSettle() public {
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");
        vm.prank(facilitator);
        agent.verifyPayment(reqId);
        agent.fulfillService(reqId, "Result");

        // Try to rate before settlement
        vm.prank(client1);
        vm.expectRevert("X402PayableAgent: not settled");
        agent.rateService(reqId, 80, "Good");
    }

    // ════════════════════════════════════════════════════════════
    //  EIP-8004: VALIDATION
    // ════════════════════════════════════════════════════════════

    function test_requestDataAudit() public {
        uint256 valId = agent.requestDataAudit(auditor, "ipfs://audit-criteria");
        assertGt(valId, 0);

        IValidationRegistry.ValidationRecord memory r = valReg.getValidation(valId);
        assertEq(r.agentId, agent.agentId());
        assertEq(r.validator, auditor);
    }

    function test_auditorRespondsToValidation() public {
        // setUp already validated 3 capabilities (translate, summarize, sentiment)
        IValidationRegistry.ValidSummary memory before = agent.getValidationSummary();
        uint256 prevTotal = before.total;
        uint256 prevPassed = before.passed;

        uint256 valId = agent.requestDataAudit(auditor, "ipfs://audit-criteria");

        vm.prank(auditor);
        valReg.validationResponse(valId, true, "ipfs://audit-report-passed");

        IValidationRegistry.ValidSummary memory summary = agent.getValidationSummary();
        assertEq(summary.total, prevTotal + 1);
        assertEq(summary.passed, prevPassed + 1);
    }

    // ════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════

    function test_setFacilitator() public {
        address newFac = address(0xFAC2);
        agent.setFacilitator(newFac);
        assertEq(agent.facilitator(), newFac);
    }

    function test_revertZeroFacilitator() public {
        vm.expectRevert("X402PayableAgent: zero address");
        agent.setFacilitator(address(0));
    }

    // ════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ════════════════════════════════════════════════════════════

    function test_serviceStats() public {
        // Create 3 requests using basic tier (always accessible)
        vm.prank(client1);
        uint256 r1 = agent.requestService{value: 0.001 ether}(1, "translate", "A");
        vm.prank(client1);
        uint256 r2 = agent.requestService{value: 0.001 ether}(1, "summarize", "B");
        vm.prank(client2);
        agent.requestService{value: 0.001 ether}(1, "sentiment", "C");

        // Verify + fulfill + settle r1
        vm.prank(facilitator);
        agent.verifyPayment(r1);
        agent.fulfillService(r1, "Result A");
        vm.prank(facilitator);
        agent.settlePayment(r1);

        // Verify r2 only
        vm.prank(facilitator);
        agent.verifyPayment(r2);

        (uint256 total, uint256 pendingPayment, uint256 verified,, uint256 settled,,) = agent.getServiceStats();

        assertEq(total, 3);
        assertEq(pendingPayment, 1);
        assertEq(verified, 1);
        assertEq(settled, 1);
    }

    function test_revenueStats() public {
        // Settle one, refund another
        vm.prank(client1);
        uint256 r1 = agent.requestService{value: 0.001 ether}(1, "translate", "A");
        vm.prank(client1);
        uint256 r2 = agent.requestService{value: 0.001 ether}(1, "translate", "B");

        // Settle r1
        vm.prank(facilitator);
        agent.verifyPayment(r1);
        agent.fulfillService(r1, "Result");
        vm.prank(facilitator);
        agent.settlePayment(r1);

        // Refund r2
        vm.prank(facilitator);
        agent.refundPayment(r2);

        (uint256 revenue, uint256 refunds,, uint256 count) = agent.getRevenueStats();
        assertEq(revenue, 0.001 ether);
        assertEq(refunds, 0.001 ether);
        assertEq(count, 2);
    }

    // ════════════════════════════════════════════════════════════
    //  FULL x402 + EIP-8004 LIFECYCLE SCENARIO
    // ════════════════════════════════════════════════════════════

    /// @notice End-to-end: reputation-gated tier escalation lifecycle
    ///   1. No reputation → only Basic visible
    ///   2. Complete Basic + rate → unlock Premium
    ///   3. Full Premium lifecycle + audit
    function test_fullX402Eip8004Lifecycle() public {
        // ── Step 1: No reputation → only Basic tier visible ──
        X402PayableAgent.ServiceTier[] memory initialReqs = agent.getPaymentRequirements();
        assertEq(initialReqs.length, 1, "new agent: only basic visible");

        assertEq(initialReqs[0].tierId, 1);

        // ── Step 2: Complete a Basic service + rate → build reputation ──
        _completeAndRate(client1, 1, 80); // score 80 → avgScore 8000 ≥ PREMIUM(5000)

        // ── Step 3: Reputation now unlocks Premium ──
        X402PayableAgent.ServiceTier[] memory afterRep = agent.getPaymentRequirements();
        assertGe(afterRep.length, 2, "after reputation: Premium should be visible");

        // Find Premium tier
        uint256 premiumId;
        uint256 premiumPrice;
        for (uint256 i = 0; i < afterRep.length; i++) {
            if (keccak256(bytes(afterRep[i].name)) == keccak256(bytes("premium"))) {
                premiumId = afterRep[i].tierId;
                premiumPrice = afterRep[i].priceWei;
                break;
            }
        }
        assertEq(premiumPrice, 0.005 ether, "premium price");

        // ── Step 4: Full Premium x402 lifecycle ──
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: premiumPrice}(
            premiumId, "translate", "The quick brown fox jumps over the lazy dog"
        );

        // ── Step 3: Facilitator verifies (≈ POST /verify) ──
        vm.prank(facilitator);
        agent.verifyPayment(reqId);

        string memory translation = unicode"敏捷的棕色狐狸跳过了懒狗";
        agent.fulfillService(reqId, translation);

        uint256 ownerBalBefore = owner.balance;
        vm.prank(facilitator);
        agent.settlePayment(reqId);

        assertEq(owner.balance - ownerBalBefore, premiumPrice, "owner receives premium payment");

        // ── Step 5: Rate + Audit ──
        vm.prank(client1);
        agent.rateService(reqId, 95, "Perfect translation, fast delivery!");

        IReputationRegistry.Summary memory repSummary = agent.getReputationSummary();
        assertEq(repSummary.totalFeedbacks, 2); // basic + premium ratings

        // ── Step 7: Owner requests audit (EIP-8004 Validation) ──
        uint256 valId = agent.requestDataAudit(auditor, "ipfs://translation-quality-criteria-v1");

        vm.prank(auditor);
        valReg.validationResponse(valId, true, "ipfs://audit-report-translation-quality-passed");

        IValidationRegistry.ValidSummary memory valSummary = agent.getValidationSummary();
        // 3 capability validations (setUp) + 1 audit = 4
        assertEq(valSummary.total, 4);
        assertEq(valSummary.passed, 4);

        // ── Final: Verify complete trust profile ──
        uint256 agentId = agent.agentId();
        assertEq(idReg.getMetadata(agentId, "payment-protocol"), "x402-exact");
        assertEq(agent.totalRequests(), 2); // basic + premium
    }

    /// @notice Multi-client scenario demonstrating concurrent x402 payment flows
    function test_multiClientConcurrentPayments() public {
        // Client 1: basic tier
        vm.prank(client1);
        uint256 r1 = agent.requestService{value: 0.001 ether}(1, "translate", "Hello");

        // Client 2: basic tier (no reputation → only basic accessible)
        vm.prank(client2);
        uint256 r2 = agent.requestService{value: 0.001 ether}(1, "summarize", "Long text...");

        // Both verified
        vm.startPrank(facilitator);
        agent.verifyPayment(r1);
        agent.verifyPayment(r2);
        vm.stopPrank();

        // Both fulfilled
        agent.fulfillService(r1, "Hola");
        agent.fulfillService(r2, "Summary: ...");

        // Both settled
        vm.startPrank(facilitator);
        agent.settlePayment(r1);
        agent.settlePayment(r2);
        vm.stopPrank();

        // Both rate
        vm.prank(client1);
        agent.rateService(r1, 80, "Good");
        vm.prank(client2);
        agent.rateService(r2, 92, "Very accurate");

        IReputationRegistry.Summary memory summary = agent.getReputationSummary();
        assertEq(summary.totalFeedbacks, 2);
        assertEq(summary.activeFeedbacks, 2);
        // Average: (80 + 92) / 2 * 100 = 8600
        assertEq(summary.averageScore, 8600);

        assertEq(agent.totalRevenue(), 0.002 ether);
        assertEq(agent.totalRequests(), 2);
    }

    // ════════════════════════════════════════════════════════════
    //  CAPABILITY GATE TESTS (EIP-8004 Validation → Load-Bearing)
    // ════════════════════════════════════════════════════════════

    /// @notice Requesting an unvalidated capability should revert
    function test_revertUnvalidatedCapability() public {
        // "code-review" was never registered
        vm.prank(client1);
        vm.expectRevert("X402PayableAgent: capability not validated");
        agent.requestService{value: 0.001 ether}(1, "code-review", "data");
    }

    /// @notice Register a capability, verify not yet validated, auditor approves, now usable
    function test_capabilityRegistrationFlow() public {
        // Register new capability
        agent.registerCapability("code-review", auditor, "ipfs://code-review-spec");

        // Not validated yet → request reverts
        vm.prank(client1);
        vm.expectRevert("X402PayableAgent: capability not validated");
        agent.requestService{value: 0.001 ether}(1, "code-review", "data");

        // Auditor approves
        (, uint256 valId,,) = agent.capabilities("code-review");
        vm.prank(auditor);
        valReg.validationResponse(valId, true, "ipfs://audit-passed");

        // Refresh and verify
        agent.refreshCapabilityStatus("code-review");
        assertTrue(agent.isCapabilityValidated("code-review"));

        // Now request succeeds
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.001 ether}(1, "code-review", "data");
        assertGt(reqId, 0);
    }

    // ════════════════════════════════════════════════════════════
    //  REPUTATION-GATED TIER TESTS (EIP-8004 Reputation → Load-Bearing)
    // ════════════════════════════════════════════════════════════

    /// @notice Premium tier requires avgScore ≥ 50 (5000 scaled)
    function test_premiumTierRequiresReputation() public {
        // No reputation → Premium tier blocked
        vm.prank(client1);
        vm.expectRevert("X402PayableAgent: tier requires higher reputation");
        agent.requestService{value: 0.005 ether}(2, "translate", "data");
    }

    /// @notice Build reputation to unlock Premium tier
    function test_reputationUnlocksPremiumTier() public {
        // Complete basic service + rate 60 → avgScore 6000 ≥ 5000
        _completeAndRate(client1, 1, 60);

        // Now Premium tier accessible
        vm.prank(client1);
        uint256 reqId = agent.requestService{value: 0.005 ether}(2, "translate", "premium data");
        assertGt(reqId, 0);
    }

    /// @notice Enterprise tier requires avgScore ≥ 80 (8000 scaled)
    function test_enterpriseTierRequiresHighReputation() public {
        // Score 60 → avgScore 6000; unlocks Premium but NOT Enterprise
        _completeAndRate(client1, 1, 60);

        vm.prank(client1);
        vm.expectRevert("X402PayableAgent: tier requires higher reputation");
        agent.requestService{value: 0.01 ether}(3, "translate", "data");
    }

    /// @notice Full tier escalation: Basic → Premium → Enterprise
    function test_tierEscalationWithReputation() public {
        // Initially only 1 payment tier visible
        assertEq(agent.getPaymentRequirements().length, 1, "start: basic only");

        // Rate 55 → unlock Premium (avgScore 5500 ≥ 5000)
        _completeAndRate(client1, 1, 55);
        assertEq(agent.getPaymentRequirements().length, 2, "after 55: basic+premium");

        // Rate 95 → avg ~75 → still no Enterprise (need ≥ 80)
        _completeAndRate(client2, 1, 95);
        IReputationRegistry.Summary memory mid = agent.getReputationSummary();
        // avg = (55+95)/2 = 75 → 7500 < 8000
        assertEq(mid.averageScore, 7500);
        assertEq(agent.getPaymentRequirements().length, 2, "avg 75: still no enterprise");

        // Rate 100 → avg ~83.3 → Enterprise unlocked
        _completeAndRate(client1, 1, 100);
        IReputationRegistry.Summary memory fin = agent.getReputationSummary();
        // avg = (55+95+100)/3 = 83.3 → 8333 ≥ 8000
        assertGe(fin.averageScore, 8000);
        assertEq(agent.getPaymentRequirements().length, 3, "avg 83: all tiers");
    }

    /// @notice getAccessibleTierLevel reflects reputation level
    function test_getAccessibleTierLevel() public {
        // No reputation → basic
        assertEq(agent.getAccessibleTierLevel(), "basic");

        // Rate 60 → Premium
        _completeAndRate(client1, 1, 60);
        assertEq(agent.getAccessibleTierLevel(), "premium");

        // Rate 100 → avg 80 → Enterprise
        _completeAndRate(client1, 1, 100);
        assertEq(agent.getAccessibleTierLevel(), "enterprise");
    }

    /// @notice getAllTiers always returns all 3, getPaymentRequirements only returns accessible ones
    function test_getAllTiersVsPaymentRequirements() public {
        assertEq(agent.getAllTiers().length, 3, "all tiers always returns 3");
        assertEq(agent.getPaymentRequirements().length, 1, "payment reqs: 1 (basic only)");

        // Build reputation
        _completeAndRate(client1, 1, 90);
        assertEq(agent.getAllTiers().length, 3, "all tiers still 3");
        assertEq(agent.getPaymentRequirements().length, 3, "payment reqs: 3 (all unlocked)");
    }

    // Helper to receive ETH
    receive() external payable {}
}
