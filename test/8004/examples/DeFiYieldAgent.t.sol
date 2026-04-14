// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IdentityRegistry} from "../../../src/8004/IdentityRegistry.sol";
import {ReputationRegistry} from "../../../src/8004/ReputationRegistry.sol";
import {ValidationRegistry} from "../../../src/8004/ValidationRegistry.sol";
import {DeFiYieldAgent} from "../../../src/8004/examples/DeFiYieldAgent.sol";
import {DataOracleAgent} from "../../../src/8004/examples/DataOracleAgent.sol";
import {IReputationRegistry} from "../../../src/8004/interfaces/IReputationRegistry.sol";
import {IValidationRegistry} from "../../../src/8004/interfaces/IValidationRegistry.sol";

/// @title DeFiYieldAgentTest – Tests for the DeFiYieldAgent + inter-agent interaction
contract DeFiYieldAgentTest is Test {
    IdentityRegistry idReg;
    ReputationRegistry repReg;
    ValidationRegistry valReg;
    DeFiYieldAgent agent;

    address agentOwner = makeAddr("agentOwner");
    address auditor = makeAddr("auditor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        idReg = new IdentityRegistry();
        repReg = new ReputationRegistry(address(idReg));
        valReg = new ValidationRegistry(address(idReg));

        vm.prank(agentOwner);
        agent = new DeFiYieldAgent(address(idReg), address(repReg), address(valReg));

        // Fund users
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(agentOwner, 100 ether);
    }

    // ════════════════════════════════════════════════════════════
    //  IDENTITY
    // ════════════════════════════════════════════════════════════

    function test_autoRegistration() public view {
        uint256 aid = agent.agentId();
        assertGt(aid, 0);
        assertEq(idReg.ownerOf(aid), address(agent));
        assertEq(idReg.getMetadata(aid, "service"), "yield-optimization");
        assertEq(idReg.getMetadata(aid, "asset"), "ETH");
        assertEq(idReg.getMetadata(aid, "risk-model"), "conservative");
    }

    // ════════════════════════════════════════════════════════════
    //  STRATEGY LIFECYCLE (Validation-Gated)
    // ════════════════════════════════════════════════════════════

    function test_proposeStrategy() public {
        vm.prank(agentOwner);
        uint256 sid = agent.proposeStrategy("ETH Staking", "Stake ETH for yield", auditor, "ipfs://QmCriteria");

        assertEq(sid, 1);
        DeFiYieldAgent.Strategy memory s = agent.getStrategy(sid);
        assertEq(s.name, "ETH Staking");
        assertTrue(s.status == DeFiYieldAgent.StrategyStatus.Proposed);
        assertGt(s.validationId, 0);
    }

    function test_cannotActivateUnvalidatedStrategy() public {
        vm.prank(agentOwner);
        uint256 sid = agent.proposeStrategy("ETH Staking", "Stake ETH", auditor, "ipfs://QmCriteria");

        // Try to activate without auditor approval → should revert
        vm.prank(agentOwner);
        vm.expectRevert("DeFiYieldAgent: strategy not validated");
        agent.activateStrategy(sid);
    }

    function test_activateAfterValidation() public {
        uint256 sid = _createAndValidateStrategy("ETH Staking", "Stake ETH");

        // Now activate should succeed
        vm.prank(agentOwner);
        agent.activateStrategy(sid);

        DeFiYieldAgent.Strategy memory s = agent.getStrategy(sid);
        assertTrue(s.status == DeFiYieldAgent.StrategyStatus.Active);
        assertGt(s.activatedAt, 0);
    }

    function test_cannotActivateFailedValidation() public {
        vm.prank(agentOwner);
        uint256 sid = agent.proposeStrategy("Risky Strategy", "Too risky", auditor, "ipfs://QmCriteria");

        DeFiYieldAgent.Strategy memory s = agent.getStrategy(sid);

        // Auditor FAILS the strategy
        vm.prank(auditor);
        valReg.validationResponse(s.validationId, false, "ipfs://QmFailReport");

        // Cannot activate
        vm.prank(agentOwner);
        vm.expectRevert("DeFiYieldAgent: strategy not validated");
        agent.activateStrategy(sid);
    }

    function test_pauseAndReactivateStrategy() public {
        uint256 sid = _createAndValidateStrategy("ETH Staking", "Stake ETH");

        vm.prank(agentOwner);
        agent.activateStrategy(sid);

        // Pause
        vm.prank(agentOwner);
        agent.pauseStrategy(sid);
        assertTrue(agent.getStrategy(sid).status == DeFiYieldAgent.StrategyStatus.Paused);

        // Reactivate from paused (doesn't require re-validation)
        vm.prank(agentOwner);
        agent.activateStrategy(sid);
        assertTrue(agent.getStrategy(sid).status == DeFiYieldAgent.StrategyStatus.Active);
    }

    function test_retireStrategy() public {
        uint256 sid = _createAndValidateStrategy("Old Strategy", "Deprecated");

        vm.prank(agentOwner);
        agent.activateStrategy(sid);

        // Must pause first, then retire (no deposits)
        vm.prank(agentOwner);
        agent.pauseStrategy(sid);

        vm.prank(agentOwner);
        agent.retireStrategy(sid);

        assertTrue(agent.getStrategy(sid).status == DeFiYieldAgent.StrategyStatus.Retired);
    }

    // ════════════════════════════════════════════════════════════
    //  DEPOSIT / WITHDRAW (Reputation-Gated)
    // ════════════════════════════════════════════════════════════

    function test_depositIntoActiveStrategy() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        vm.prank(alice);
        agent.deposit{value: 0.3 ether}(sid);

        DeFiYieldAgent.Position memory pos = agent.getPosition(alice, sid);
        assertEq(pos.deposited, 0.3 ether);
        assertEq(agent.totalValueLocked(), 0.3 ether);
    }

    function test_cannotDepositIntoInactiveStrategy() public {
        vm.prank(agentOwner);
        uint256 sid = agent.proposeStrategy("Unaudited", "Not yet", auditor, "ipfs://QmC");

        vm.prank(alice);
        vm.expectRevert("DeFiYieldAgent: strategy not active");
        agent.deposit{value: 0.1 ether}(sid);
    }

    function test_depositCapNoReputation() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        // No reputation → cap is 0.5 ETH
        assertEq(agent.getDepositCap(), 0.5 ether);

        // Deposit 0.5 ETH should succeed
        vm.prank(alice);
        agent.deposit{value: 0.5 ether}(sid);

        // Deposit 0.01 more should fail (exceeds cap)
        vm.prank(alice);
        vm.expectRevert("DeFiYieldAgent: exceeds reputation-based deposit cap");
        agent.deposit{value: 0.01 ether}(sid);
    }

    function test_depositCapIncreasesWithReputation() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        // Give the agent a good reputation (score 85)
        _depositAndRate(sid, alice, 0.1 ether, 85, "Good yield");
        _depositAndRate(sid, bob, 0.1 ether, 90, "Excellent");

        // Now cap should be HIGH (50 ETH) because avg = (85+90)/2 = 87.5 ≥ 80
        assertEq(agent.getDepositCap(), 50 ether);

        // Alice can now deposit much more (after withdrawing first position)
        vm.prank(alice);
        agent.withdraw(sid);

        vm.prank(alice);
        agent.deposit{value: 40 ether}(sid);

        assertEq(agent.getPosition(alice, sid).deposited, 40 ether);
    }

    function test_depositCapLowReputation() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        // Give bad reputation (score 30)
        _depositAndRate(sid, alice, 0.1 ether, 30, "Bad");

        // Cap should be LOW (1 ETH) because avg = 30 < 50
        assertEq(agent.getDepositCap(), 1 ether);
    }

    function test_depositCapMediumReputation() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        // Give medium reputation (score 65)
        _depositAndRate(sid, alice, 0.1 ether, 65, "Decent");

        // Cap should be MEDIUM (5 ETH) because 50 ≤ 65 < 80
        assertEq(agent.getDepositCap(), 5 ether);
    }

    function test_withdrawPrincipalAndYield() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        // Alice deposits (0.4 ETH, within no-reputation cap of 0.5 ETH)
        vm.prank(alice);
        agent.deposit{value: 0.4 ether}(sid);

        // Agent harvests yield for Alice
        address[] memory depositors = new address[](1);
        depositors[0] = alice;
        uint256[] memory yields = new uint256[](1);
        yields[0] = 0.02 ether;

        vm.prank(agentOwner);
        agent.harvestYield{value: 0.02 ether}(sid, depositors, yields);

        // Alice's position shows yield
        DeFiYieldAgent.Position memory pos = agent.getPosition(alice, sid);
        assertEq(pos.yieldEarned, 0.02 ether);

        // Alice withdraws everything
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        agent.withdraw(sid);

        // Should receive principal + yield
        assertEq(alice.balance, balBefore + 0.42 ether);
        assertEq(agent.totalYieldDistributed(), 0.02 ether);
    }

    function test_cannotWithdrawWithoutPosition() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        vm.prank(alice);
        vm.expectRevert("DeFiYieldAgent: no position");
        agent.withdraw(sid);
    }

    // ════════════════════════════════════════════════════════════
    //  YIELD OPERATIONS
    // ════════════════════════════════════════════════════════════

    function test_harvestYieldMultipleDepositors() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        // Both deposit
        vm.prank(alice);
        agent.deposit{value: 0.3 ether}(sid);
        vm.prank(bob);
        agent.deposit{value: 0.2 ether}(sid);

        // Harvest yield proportionally
        address[] memory depositors = new address[](2);
        depositors[0] = alice;
        depositors[1] = bob;
        uint256[] memory yields = new uint256[](2);
        yields[0] = 0.03 ether; // 10% of 0.3
        yields[1] = 0.02 ether; // 10% of 0.2

        vm.prank(agentOwner);
        agent.harvestYield{value: 0.05 ether}(sid, depositors, yields);

        assertEq(agent.getPosition(alice, sid).yieldEarned, 0.03 ether);
        assertEq(agent.getPosition(bob, sid).yieldEarned, 0.02 ether);

        DeFiYieldAgent.Strategy memory s = agent.getStrategy(sid);
        assertEq(s.totalYieldGenerated, 0.05 ether);
    }

    function test_executeStrategy() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        vm.prank(alice);
        agent.deposit{value: 0.3 ether}(sid);

        // Agent executes a rebalance action
        vm.prank(agentOwner);
        agent.executeStrategy(sid, "rebalance");
        // No revert means success; event is emitted
    }

    function test_cannotExecuteInactiveStrategy() public {
        vm.prank(agentOwner);
        uint256 sid = agent.proposeStrategy("Test", "Test", auditor, "ipfs://QmC");

        vm.prank(agentOwner);
        vm.expectRevert("DeFiYieldAgent: strategy not active");
        agent.executeStrategy(sid, "rebalance");
    }

    // ════════════════════════════════════════════════════════════
    //  REPUTATION
    // ════════════════════════════════════════════════════════════

    function test_ratePerformance() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        vm.prank(alice);
        agent.deposit{value: 0.1 ether}(sid);

        vm.prank(alice);
        uint256 fid = agent.ratePerformance(sid, 88, "Solid returns");

        assertGt(fid, 0);
        IReputationRegistry.Summary memory s = agent.getReputationSummary();
        assertEq(s.activeFeedbacks, 1);
        assertEq(s.averageScore, 8800);
    }

    function test_cannotRateWithoutPosition() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        vm.prank(alice);
        vm.expectRevert("DeFiYieldAgent: no history in this strategy");
        agent.ratePerformance(sid, 80, "x");
    }

    function test_respondToFeedback() public {
        uint256 sid = _activateStrategy("ETH Staking", "Stake ETH");

        vm.prank(alice);
        agent.deposit{value: 0.1 ether}(sid);

        vm.prank(alice);
        uint256 fid = agent.ratePerformance(sid, 50, "Returns were mediocre");

        vm.prank(agentOwner);
        agent.respondToFeedback(fid, "We are optimizing the strategy for better returns");
    }

    // ════════════════════════════════════════════════════════════
    //  VALIDATOR ROLE – Cross-agent interaction
    // ════════════════════════════════════════════════════════════

    function test_validateOtherAgent() public {
        // Deploy a DataOracleAgent that will be validated by the DeFiYieldAgent
        address oracleOwner = makeAddr("oracleOwner");
        vm.prank(oracleOwner);
        DataOracleAgent oracleAgent = new DataOracleAgent(address(idReg), address(repReg), address(valReg));

        uint256 oracleAgentId = oracleAgent.agentId();

        // DataOracleAgent requests validation, designating DeFiYieldAgent as validator
        vm.prank(oracleOwner);
        uint256 vid = oracleAgent.requestAudit(address(agent), "ipfs://QmAgentAuditCriteria");

        // DeFiYieldAgent operator responds as validator
        vm.prank(agentOwner);
        agent.validateOtherAgent(vid, true, "ipfs://QmOracleAgentPassed");

        // Verify validation result
        assertTrue(valReg.getValidationStatus(vid) == IValidationRegistry.ValidationStatus.Passed);

        IValidationRegistry.ValidSummary memory s = valReg.getSummary(oracleAgentId);
        assertEq(s.passed, 1);
    }

    function test_validateOtherAgent_fail() public {
        address oracleOwner = makeAddr("oracleOwner");
        vm.prank(oracleOwner);
        DataOracleAgent oracleAgent = new DataOracleAgent(address(idReg), address(repReg), address(valReg));

        vm.prank(oracleOwner);
        uint256 vid = oracleAgent.requestAudit(address(agent), "ipfs://QmCriteria");

        vm.prank(agentOwner);
        agent.validateOtherAgent(vid, false, "ipfs://QmFailReport");

        assertTrue(valReg.getValidationStatus(vid) == IValidationRegistry.ValidationStatus.Failed);
    }

    // ════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ════════════════════════════════════════════════════════════

    function test_strategyStats() public {
        uint256 s1 = _activateStrategy("Staking", "Stake ETH");
        _createAndValidateStrategy("LP", "Provide liquidity"); // stays Proposed (validated but not activated)
        uint256 s3 = _activateStrategy("Farming", "Yield farm");

        vm.prank(agentOwner);
        agent.pauseStrategy(s3);

        (uint256 total, uint256 proposed, uint256 active, uint256 paused, uint256 retired) = agent.getStrategyStats();
        assertEq(total, 3);
        // Note: s2 is Proposed (validated but activateStrategy not called)
        assertEq(proposed, 1);
        assertEq(active, 1);
        assertEq(paused, 1);
        assertEq(retired, 0);
    }

    function test_userStrategyIds() public {
        uint256 s1 = _activateStrategy("Staking", "Stake ETH");
        uint256 s2 = _activateStrategy("LP", "Provide liquidity");

        vm.prank(alice);
        agent.deposit{value: 0.1 ether}(s1);
        vm.prank(alice);
        agent.deposit{value: 0.1 ether}(s2);

        uint256[] memory ids = agent.getUserStrategyIds(alice);
        assertEq(ids.length, 2);
    }

    // ════════════════════════════════════════════════════════════
    //  FULL END-TO-END SCENARIO
    // ════════════════════════════════════════════════════════════

    function test_fullScenario() public {
        console.log("=== DeFiYieldAgent Full Scenario ===");

        // 1. Identity is registered
        console.log("Agent ID:", agent.agentId());
        console.log("Agent URI:", agent.getAgentURI());

        // 2. Owner proposes a strategy — auditor must validate first
        vm.prank(agentOwner);
        uint256 sid = agent.proposeStrategy(
            "ETH Staking v2", "Delegate ETH to validators for staking yield", auditor, "ipfs://QmStakingCriteria"
        );
        console.log("Strategy proposed, awaiting audit...");

        // 3. Auditor validates the strategy
        DeFiYieldAgent.Strategy memory strat = agent.getStrategy(sid);
        vm.prank(auditor);
        valReg.validationResponse(strat.validationId, true, "ipfs://QmAuditPassed");
        console.log("Strategy passed audit!");

        // 4. Owner activates the validated strategy
        vm.prank(agentOwner);
        agent.activateStrategy(sid);
        console.log("Strategy activated, accepting deposits");

        // 5. Initial deposit cap is low (no reputation yet)
        uint256 cap = agent.getDepositCap();
        console.log("Initial deposit cap (wei):", cap);
        assertEq(cap, 0.5 ether); // CAP_NO_REPUTATION

        // 6. Alice and Bob deposit
        vm.prank(alice);
        agent.deposit{value: 0.3 ether}(sid);
        vm.prank(bob);
        agent.deposit{value: 0.2 ether}(sid);
        console.log("TVL:", agent.totalValueLocked());

        // 7. Agent executes strategy (on-chain record of action)
        vm.prank(agentOwner);
        agent.executeStrategy(sid, "stake-to-validator");

        // 8. Agent harvests yield for depositors
        address[] memory depositors = new address[](2);
        depositors[0] = alice;
        depositors[1] = bob;
        uint256[] memory yields = new uint256[](2);
        yields[0] = 0.015 ether; // 5% yield on 0.3
        yields[1] = 0.01 ether; // 5% yield on 0.2

        vm.prank(agentOwner);
        agent.harvestYield{value: 0.025 ether}(sid, depositors, yields);
        console.log("Yield harvested");

        // 9. Alice withdraws with yield
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        agent.withdraw(sid);
        assertEq(alice.balance, aliceBalBefore + 0.315 ether);
        console.log("Alice withdrew principal + yield");

        // 10. Both users rate the agent
        // (Alice already withdrew but still has history)
        vm.prank(alice);
        agent.ratePerformance(sid, 92, "Excellent staking returns");
        vm.prank(bob);
        agent.ratePerformance(sid, 85, "Good performance, could be faster");

        // 11. Reputation improves → deposit cap increases
        IReputationRegistry.Summary memory rep = agent.getReputationSummary();
        console.log("Reputation - Active feedbacks:", rep.activeFeedbacks);
        console.log("Reputation - Avg score (x100):", rep.averageScore);
        assertEq(rep.activeFeedbacks, 2);
        // (92+85)*100/2 = 8850
        assertEq(rep.averageScore, 8850);

        cap = agent.getDepositCap();
        console.log("New deposit cap (wei):", cap);
        assertEq(cap, 50 ether); // CAP_HIGH because avg ≥ 80

        // 12. Cross-agent validation: DeFiYieldAgent validates a DataOracleAgent
        address oracleOwner = makeAddr("oracleOwner");
        vm.prank(oracleOwner);
        DataOracleAgent oracleAgent = new DataOracleAgent(address(idReg), address(repReg), address(valReg));

        vm.prank(oracleOwner);
        uint256 vid = oracleAgent.requestAudit(address(agent), "ipfs://QmAgentCodeReview");

        vm.prank(agentOwner);
        agent.validateOtherAgent(vid, true, "ipfs://QmOracleAgentApproved");
        console.log("DataOracleAgent validated by DeFiYieldAgent: PASSED");

        // 13. Strategy stats
        (uint256 total,, uint256 active,,) = agent.getStrategyStats();
        console.log("Strategy stats - Total:", total, "Active:", active);

        console.log("=== Scenario Complete ===");
    }

    // ═══════ Helpers ═══════

    /// @dev Creates a strategy, has the auditor approve it, but does NOT activate it.
    function _createAndValidateStrategy(string memory name, string memory desc) internal returns (uint256 sid) {
        vm.prank(agentOwner);
        sid = agent.proposeStrategy(name, desc, auditor, "ipfs://QmCriteria");

        DeFiYieldAgent.Strategy memory s = agent.getStrategy(sid);

        // Auditor approves
        vm.prank(auditor);
        valReg.validationResponse(s.validationId, true, "ipfs://QmApproved");
    }

    /// @dev Creates, validates, AND activates a strategy.
    function _activateStrategy(string memory name, string memory desc) internal returns (uint256 sid) {
        sid = _createAndValidateStrategy(name, desc);
        vm.prank(agentOwner);
        agent.activateStrategy(sid);
    }

    /// @dev Deposits a small amount and rates, used to build reputation.
    function _depositAndRate(uint256 sid, address user, uint256 amount, uint8 score, string memory comment) internal {
        vm.prank(user);
        agent.deposit{value: amount}(sid);
        vm.prank(user);
        agent.ratePerformance(sid, score, comment);
    }
}
