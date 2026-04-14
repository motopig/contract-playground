// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IdentityRegistry} from "../../../src/8004/IdentityRegistry.sol";
import {ReputationRegistry} from "../../../src/8004/ReputationRegistry.sol";
import {ValidationRegistry} from "../../../src/8004/ValidationRegistry.sol";
import {IIdentityRegistry} from "../../../src/8004/interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "../../../src/8004/interfaces/IReputationRegistry.sol";
import {IValidationRegistry} from "../../../src/8004/interfaces/IValidationRegistry.sol";

/// @title FlowTest – End-to-end integration: register → feedback → validate
contract FlowTest is Test {
    IdentityRegistry public idReg;
    ReputationRegistry public repReg;
    ValidationRegistry public valReg;

    address agentOwner = makeAddr("agentOwner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address auditor = makeAddr("auditor");

    string constant AGENT_URI =
        'data:application/json,{"name":"WeatherBot","capabilities":["forecast","alerts"],"version":"0.1.0"}';

    function setUp() public {
        idReg = new IdentityRegistry();
        repReg = new ReputationRegistry(address(idReg));
        valReg = new ValidationRegistry(address(idReg));
    }

    /// @notice Full lifecycle: register agent → users give feedback → auditor validates → query summaries
    function test_fullLifecycle() public {
        // ──── Step 1: Agent registers ────
        vm.prank(agentOwner);
        uint256 agentId = idReg.register(AGENT_URI);
        assertEq(agentId, 1);
        assertEq(idReg.ownerOf(agentId), agentOwner);

        // Set on-chain metadata
        vm.prank(agentOwner);
        idReg.setMetadata(agentId, "model", "gpt-4o");

        // Set agent wallet
        address wallet = makeAddr("agentWallet");
        vm.prank(agentOwner);
        idReg.setAgentWallet(agentId, wallet);
        assertEq(idReg.getAgentWallet(agentId), wallet);

        // ──── Step 2: Users provide feedback ────
        vm.prank(user1);
        uint256 fb1 = repReg.giveFeedback(agentId, 90, "accurate forecasts");

        vm.prank(user2);
        uint256 fb2 = repReg.giveFeedback(agentId, 70, "sometimes slow");

        // Agent owner responds to feedback
        vm.prank(agentOwner);
        repReg.appendResponse(fb2, "Working on latency improvements");

        // Check reputation summary
        IReputationRegistry.Summary memory repSum = repReg.getSummary(agentId);
        assertEq(repSum.activeFeedbacks, 2);
        // avg = (90+70)*100/2 = 8000
        assertEq(repSum.averageScore, 8000);

        // ──── Step 3: User1 revokes feedback, re-check summary ────
        vm.prank(user1);
        repReg.revokeFeedback(fb1);

        repSum = repReg.getSummary(agentId);
        assertEq(repSum.activeFeedbacks, 1);
        assertEq(repSum.totalFeedbacks, 2);
        // avg = 70*100/1 = 7000
        assertEq(repSum.averageScore, 7000);

        // ──── Step 4: Auditor validates the agent ────
        vm.prank(user1);
        uint256 vid = valReg.validationRequest(agentId, auditor, "ipfs://QmAuditCriteria");

        // Auditor responds: PASS
        vm.prank(auditor);
        valReg.validationResponse(vid, true, "ipfs://QmAuditReport");

        IValidationRegistry.ValidSummary memory valSum = valReg.getSummary(agentId);
        assertEq(valSum.total, 1);
        assertEq(valSum.passed, 1);
        assertEq(valSum.pending, 0);

        // ──── Step 5: Cross-registry data available ────
        // Can query identity + rep + validation for the same agentId
        assertEq(idReg.agentURI(agentId), AGENT_URI);
        assertEq(idReg.getMetadata(agentId, "model"), "gpt-4o");
        assertEq(repReg.readAllFeedback(agentId).length, 2);
        assertEq(valReg.getAgentValidations(agentId).length, 1);

        console.log("=== EIP-8004 Full Lifecycle Test Passed ===");
    }

    /// @notice Multiple agents: ensure isolation between agent data
    function test_multipleAgents_isolation() public {
        // Register two agents
        vm.prank(agentOwner);
        uint256 agent1 = idReg.register(AGENT_URI);

        vm.prank(user1);
        uint256 agent2 = idReg.register('data:application/json,{"name":"CodeBot"}');

        // Feedback only for agent1
        vm.prank(user2);
        repReg.giveFeedback(agent1, 95, "");

        // Validation only for agent2
        vm.prank(user2);
        uint256 vid = valReg.validationRequest(agent2, auditor, "https://criteria.example");

        vm.prank(auditor);
        valReg.validationResponse(vid, false, "https://report.example");

        // Assert isolation
        IReputationRegistry.Summary memory rep1 = repReg.getSummary(agent1);
        IReputationRegistry.Summary memory rep2 = repReg.getSummary(agent2);
        assertEq(rep1.activeFeedbacks, 1);
        assertEq(rep2.activeFeedbacks, 0);

        IValidationRegistry.ValidSummary memory val1 = valReg.getSummary(agent1);
        IValidationRegistry.ValidSummary memory val2 = valReg.getSummary(agent2);
        assertEq(val1.total, 0);
        assertEq(val2.total, 1);
        assertEq(val2.failed, 1);
    }
}
