// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IdentityRegistry} from "../../../src/8004/IdentityRegistry.sol";
import {ReputationRegistry} from "../../../src/8004/ReputationRegistry.sol";
import {ValidationRegistry} from "../../../src/8004/ValidationRegistry.sol";
import {DataOracleAgent} from "../../../src/8004/examples/DataOracleAgent.sol";
import {DeFiYieldAgent} from "../../../src/8004/examples/DeFiYieldAgent.sol";
import {IReputationRegistry} from "../../../src/8004/interfaces/IReputationRegistry.sol";
import {IValidationRegistry} from "../../../src/8004/interfaces/IValidationRegistry.sol";

/// @title DataOracleAgentTest – Tests for the DataOracleAgent + inter-agent interaction
contract DataOracleAgentTest is Test {
    IdentityRegistry idReg;
    ReputationRegistry repReg;
    ValidationRegistry valReg;
    DataOracleAgent oracle;

    address agentOwner = makeAddr("agentOwner");
    address auditor = makeAddr("auditor");
    address consumer1 = makeAddr("consumer1");
    address consumer2 = makeAddr("consumer2");
    address disputer = makeAddr("disputer");

    function setUp() public {
        idReg = new IdentityRegistry();
        repReg = new ReputationRegistry(address(idReg));
        valReg = new ValidationRegistry(address(idReg));

        vm.prank(agentOwner);
        oracle = new DataOracleAgent(address(idReg), address(repReg), address(valReg));

        // Fund accounts
        vm.deal(agentOwner, 100 ether);
        vm.deal(consumer1, 10 ether);
        vm.deal(consumer2, 10 ether);
    }

    // ════════════════════════════════════════════════════════════
    //  IDENTITY
    // ════════════════════════════════════════════════════════════

    function test_autoRegistration() public view {
        uint256 aid = oracle.agentId();
        assertGt(aid, 0);
        assertEq(idReg.ownerOf(aid), address(oracle));
        assertEq(idReg.getMetadata(aid, "service"), "data-oracle");
        assertEq(idReg.getMetadata(aid, "delivery"), "on-chain");
        assertEq(idReg.getMetadata(aid, "security-model"), "stake-backed");
    }

    // ════════════════════════════════════════════════════════════
    //  FEED LIFECYCLE (Validation-Gated)
    // ════════════════════════════════════════════════════════════

    function test_registerFeed() public {
        vm.prank(agentOwner);
        uint256 fid = oracle.registerFeed("ETH/USD", "Aggregated from 5 CEX", auditor, "ipfs://QmCriteria");

        assertEq(fid, 1);
        DataOracleAgent.DataFeed memory f = oracle.getFeed(fid);
        assertEq(f.pair, "ETH/USD");
        assertTrue(f.status == DataOracleAgent.FeedStatus.Proposed);
        assertGt(f.validationId, 0);
    }

    function test_cannotActivateUnvalidatedFeed() public {
        vm.prank(agentOwner);
        uint256 fid = oracle.registerFeed("ETH/USD", "Test", auditor, "ipfs://QmC");

        vm.prank(agentOwner);
        vm.expectRevert("DataOracleAgent: feed not validated");
        oracle.activateFeed{value: 1 ether}(fid);
    }

    function test_activateAfterValidation() public {
        uint256 fid = _createAndValidateFeed("ETH/USD", "Aggregated from 5 CEX");

        vm.prank(agentOwner);
        oracle.activateFeed{value: 1 ether}(fid);

        DataOracleAgent.DataFeed memory f = oracle.getFeed(fid);
        assertTrue(f.status == DataOracleAgent.FeedStatus.Active);
        assertEq(f.stakedAmount, 1 ether);
        assertGt(f.activatedAt, 0);
    }

    function test_cannotActivateFailedValidation() public {
        vm.prank(agentOwner);
        uint256 fid = oracle.registerFeed("SCAM/USD", "Bad data", auditor, "ipfs://QmC");

        DataOracleAgent.DataFeed memory f = oracle.getFeed(fid);

        // Auditor FAILS the feed
        vm.prank(auditor);
        valReg.validationResponse(f.validationId, false, "ipfs://QmFailReport");

        vm.prank(agentOwner);
        vm.expectRevert("DataOracleAgent: feed not validated");
        oracle.activateFeed{value: 1 ether}(fid);
    }

    function test_cannotActivateWithInsufficientStake() public {
        uint256 fid = _createAndValidateFeed("ETH/USD", "Test");

        // No reputation → requires 1 ETH, try with 0.5
        vm.prank(agentOwner);
        vm.expectRevert("DataOracleAgent: insufficient stake");
        oracle.activateFeed{value: 0.5 ether}(fid);
    }

    function test_suspendAndReactivateFeed() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        // Suspend
        vm.prank(agentOwner);
        oracle.suspendFeed(fid);
        assertTrue(oracle.getFeed(fid).status == DataOracleAgent.FeedStatus.Suspended);

        // Reactivate
        vm.prank(agentOwner);
        oracle.reactivateFeed(fid);
        assertTrue(oracle.getFeed(fid).status == DataOracleAgent.FeedStatus.Active);
    }

    function test_retireFeedReturnsStake() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        uint256 ownerBalBefore = agentOwner.balance;

        vm.prank(agentOwner);
        oracle.retireFeed(fid);

        assertTrue(oracle.getFeed(fid).status == DataOracleAgent.FeedStatus.Retired);
        assertEq(agentOwner.balance, ownerBalBefore + 1 ether);
        assertEq(oracle.totalStaked(), 0);
    }

    // ════════════════════════════════════════════════════════════
    //  DATA PUBLICATION & CONSUMPTION
    // ════════════════════════════════════════════════════════════

    function test_publishAndReadData() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        // Publish a price: $2500.00 = 250000 cents
        vm.prank(agentOwner);
        oracle.publishData(fid, 250000, 9500);

        // Read the data (this is the on-chain utility!)
        (int256 value, uint256 timestamp, uint256 confidence) = oracle.getLatestData(fid);
        assertEq(value, 250000);
        assertGt(timestamp, 0);
        assertEq(confidence, 9500);
    }

    function test_publishMultipleUpdates() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        vm.startPrank(agentOwner);
        oracle.publishData(fid, 250000, 9500);
        vm.warp(block.timestamp + 60);
        oracle.publishData(fid, 251000, 9600);
        vm.warp(block.timestamp + 60);
        oracle.publishData(fid, 249500, 9400);
        vm.stopPrank();

        // Latest should be the last one
        (int256 value,,) = oracle.getLatestData(fid);
        assertEq(value, 249500);

        // History should have 3 entries
        assertEq(oracle.getDataHistoryLength(fid), 3);
        assertEq(oracle.totalDataPoints(), 3);

        DataOracleAgent.DataFeed memory f = oracle.getFeed(fid);
        assertEq(f.updateCount, 3);
    }

    function test_cannotPublishToInactiveFeed() public {
        vm.prank(agentOwner);
        uint256 fid = oracle.registerFeed("ETH/USD", "Test", auditor, "ipfs://QmC");

        vm.prank(agentOwner);
        vm.expectRevert("DataOracleAgent: feed not active");
        oracle.publishData(fid, 250000, 9500);
    }

    function test_cannotReadFromInactiveFeed() public {
        vm.prank(agentOwner);
        uint256 fid = oracle.registerFeed("ETH/USD", "Test", auditor, "ipfs://QmC");

        vm.expectRevert("DataOracleAgent: feed not active");
        oracle.getLatestData(fid);
    }

    function test_cannotReadWithNoData() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        vm.expectRevert("DataOracleAgent: no data published yet");
        oracle.getLatestData(fid);
    }

    // ════════════════════════════════════════════════════════════
    //  DISPUTE & SLASHING
    // ════════════════════════════════════════════════════════════

    function test_disputeSlashesStake() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        vm.prank(agentOwner);
        oracle.publishData(fid, 999999, 9500); // obviously wrong data

        uint256 disputerBalBefore = disputer.balance;

        // Dispute the data
        vm.prank(disputer);
        oracle.disputeData(fid, "ipfs://QmEvidence");

        // Disputer should receive 50% of stake
        assertEq(disputer.balance, disputerBalBefore + 0.5 ether);

        // Feed should be suspended
        DataOracleAgent.DataFeed memory f = oracle.getFeed(fid);
        assertTrue(f.status == DataOracleAgent.FeedStatus.Suspended);
        assertEq(f.stakedAmount, 0.5 ether); // remaining
        assertEq(f.disputeCount, 1);

        // Global stats
        assertEq(oracle.totalSlashed(), 0.5 ether);
    }

    function test_disputeRequiresEvidence() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        vm.prank(disputer);
        vm.expectRevert("DataOracleAgent: evidence required");
        oracle.disputeData(fid, "");
    }

    function test_cannotReactivateWithInsufficientStakeAfterSlash() public {
        uint256 fid = _activateFeed("ETH/USD", "Test");

        vm.prank(agentOwner);
        oracle.publishData(fid, 999999, 9500);

        // Dispute → slashes to 0.5 ETH
        vm.prank(disputer);
        oracle.disputeData(fid, "ipfs://QmEvidence");

        // Try to reactivate — need 1 ETH (no reputation), but only 0.5 left
        vm.prank(agentOwner);
        vm.expectRevert("DataOracleAgent: insufficient remaining stake");
        oracle.reactivateFeed(fid);

        // Top up stake, then reactivate
        vm.prank(agentOwner);
        oracle.addStake{value: 0.5 ether}(fid);

        vm.prank(agentOwner);
        oracle.reactivateFeed(fid);

        assertTrue(oracle.getFeed(fid).status == DataOracleAgent.FeedStatus.Active);
    }

    // ════════════════════════════════════════════════════════════
    //  STAKE REQUIREMENTS (Reputation-Gated)
    // ════════════════════════════════════════════════════════════

    function test_stakeNoReputation() public view {
        assertEq(oracle.getRequiredStake(), 1 ether);
    }

    function test_stakeHighReputation() public {
        // Give high reputation
        vm.prank(consumer1);
        oracle.rateFeed(90, "Excellent data");
        vm.prank(consumer2);
        oracle.rateFeed(85, "Very reliable");

        // avg = (90+85)/2 = 87.5 → HIGH tier
        assertEq(oracle.getRequiredStake(), 0.05 ether);
    }

    function test_stakeMediumReputation() public {
        vm.prank(consumer1);
        oracle.rateFeed(65, "Decent data");

        // avg = 65 → MEDIUM tier
        assertEq(oracle.getRequiredStake(), 0.2 ether);
    }

    function test_stakeLowReputation() public {
        vm.prank(consumer1);
        oracle.rateFeed(30, "Unreliable");

        // avg = 30 → LOW tier
        assertEq(oracle.getRequiredStake(), 0.5 ether);
    }

    function test_activateFeedWithReducedStakeAfterReputation() public {
        // Build reputation first
        vm.prank(consumer1);
        oracle.rateFeed(92, "Top tier oracle");
        vm.prank(consumer2);
        oracle.rateFeed(88, "Very good");

        // Now required stake is only 0.05 ETH (HIGH tier)
        uint256 fid = _createAndValidateFeed("BTC/USD", "Trust me");

        vm.prank(agentOwner);
        oracle.activateFeed{value: 0.05 ether}(fid);

        assertTrue(oracle.getFeed(fid).status == DataOracleAgent.FeedStatus.Active);
    }

    // ════════════════════════════════════════════════════════════
    //  REPUTATION
    // ════════════════════════════════════════════════════════════

    function test_rateFeed() public {
        vm.prank(consumer1);
        uint256 fid = oracle.rateFeed(85, "Good data quality");

        assertGt(fid, 0);
        IReputationRegistry.Summary memory s = oracle.getReputationSummary();
        assertEq(s.activeFeedbacks, 1);
        assertEq(s.averageScore, 8500);
    }

    function test_respondToFeedback() public {
        vm.prank(consumer1);
        uint256 fid = oracle.rateFeed(50, "Data lag issues");

        vm.prank(agentOwner);
        oracle.respondToFeedback(fid, "Improved latency in v2");
    }

    // ════════════════════════════════════════════════════════════
    //  VALIDATOR ROLE – Cross-agent interaction
    // ════════════════════════════════════════════════════════════

    function test_validateOtherAgent() public {
        // Deploy a DeFiYieldAgent that will be validated by our oracle
        address yieldOwner = makeAddr("yieldOwner");
        vm.prank(yieldOwner);
        DeFiYieldAgent yieldAgent = new DeFiYieldAgent(address(idReg), address(repReg), address(valReg));

        uint256 yieldAgentId = yieldAgent.agentId();

        // DeFiYieldAgent proposes a strategy, designating DataOracleAgent as validator
        vm.prank(yieldOwner);
        uint256 sid = yieldAgent.proposeStrategy(
            "Oracle-backed Staking", "Uses our price feeds", address(oracle), "ipfs://QmStrategyCriteria"
        );

        DeFiYieldAgent.Strategy memory strat = yieldAgent.getStrategy(sid);

        // DataOracleAgent owner validates it
        vm.prank(agentOwner);
        oracle.validateOtherAgent(strat.validationId, true, "ipfs://QmApproved");

        assertTrue(valReg.getValidationStatus(strat.validationId) == IValidationRegistry.ValidationStatus.Passed);

        IValidationRegistry.ValidSummary memory s = valReg.getSummary(yieldAgentId);
        assertEq(s.passed, 1);
    }

    function test_validateOtherAgent_fail() public {
        address yieldOwner = makeAddr("yieldOwner");
        vm.prank(yieldOwner);
        DeFiYieldAgent yieldAgent = new DeFiYieldAgent(address(idReg), address(repReg), address(valReg));

        vm.prank(yieldOwner);
        uint256 sid = yieldAgent.proposeStrategy("Bad Strategy", "Risky", address(oracle), "ipfs://QmC");

        DeFiYieldAgent.Strategy memory strat = yieldAgent.getStrategy(sid);

        vm.prank(agentOwner);
        oracle.validateOtherAgent(strat.validationId, false, "ipfs://QmRejected");

        assertTrue(valReg.getValidationStatus(strat.validationId) == IValidationRegistry.ValidationStatus.Failed);
    }

    // ════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ════════════════════════════════════════════════════════════

    function test_feedStats() public {
        _activateFeed("ETH/USD", "Test");
        _createAndValidateFeed("BTC/USD", "Test"); // stays proposed/validated
        uint256 f3 = _activateFeed("SOL/USD", "Test");

        vm.prank(agentOwner);
        oracle.suspendFeed(f3);

        (uint256 total, uint256 proposed, uint256 active, uint256 suspended, uint256 retired) = oracle.getFeedStats();
        assertEq(total, 3);
        assertEq(proposed, 1); // validated but not activated
        assertEq(active, 1);
        assertEq(suspended, 1);
        assertEq(retired, 0);
    }

    // ════════════════════════════════════════════════════════════
    //  FULL END-TO-END SCENARIO
    // ════════════════════════════════════════════════════════════

    function test_fullScenario() public {
        console.log("=== DataOracleAgent Full Scenario ===");

        // 1. Identity is registered
        console.log("Agent ID:", oracle.agentId());
        console.log("Agent URI:", oracle.getAgentURI());

        // 2. Register a price feed — auditor must validate methodology first
        vm.prank(agentOwner);
        uint256 ethFeed = oracle.registerFeed(
            "ETH/USD",
            "Aggregated from Coinbase, Binance, Kraken, Uniswap, Chainlink",
            auditor,
            "ipfs://QmMethodologyCriteria"
        );
        console.log("Feed registered, awaiting methodology audit...");

        // 3. Auditor validates the data methodology
        DataOracleAgent.DataFeed memory f = oracle.getFeed(ethFeed);
        vm.prank(auditor);
        valReg.validationResponse(f.validationId, true, "ipfs://QmMethodologyApproved");
        console.log("Feed methodology approved by auditor!");

        // 4. Stake and activate (need 1 ETH with no reputation)
        assertEq(oracle.getRequiredStake(), 1 ether);
        vm.prank(agentOwner);
        oracle.activateFeed{value: 1 ether}(ethFeed);
        console.log("Feed activated with 1 ETH stake");

        // 5. Publish price data (the core on-chain action)
        vm.prank(agentOwner);
        oracle.publishData(ethFeed, 250000, 9500); // $2500.00, 95% confidence

        vm.warp(block.timestamp + 300); // 5 minutes later

        vm.prank(agentOwner);
        oracle.publishData(ethFeed, 251200, 9600); // $2512.00, 96% confidence

        // 6. Anyone can read the data on-chain (THIS is the utility)
        (int256 price, uint256 ts, uint256 conf) = oracle.getLatestData(ethFeed);
        console.log("Latest ETH/USD price (cents):");
        console.logInt(price);
        console.log("  Confidence:", conf);
        assertEq(price, 251200);

        // 7. Consumers rate data quality
        vm.prank(consumer1);
        oracle.rateFeed(92, "Very accurate, matches CEX prices");
        vm.prank(consumer2);
        oracle.rateFeed(88, "Good accuracy, slight lag");

        // 8. Reputation improves → stake requirement decreases
        IReputationRegistry.Summary memory rep = oracle.getReputationSummary();
        console.log("Reputation - Avg score (x100):", rep.averageScore);
        assertEq(rep.averageScore, 9000); // (92+88)/2 * 100

        uint256 newStake = oracle.getRequiredStake();
        console.log("New required stake (wei):", newStake);
        assertEq(newStake, 0.05 ether); // HIGH tier: was 1 ETH, now 0.05 ETH

        // 9. Register a second feed with much lower stake requirement
        vm.prank(agentOwner);
        uint256 btcFeed = oracle.registerFeed("BTC/USD", "Same methodology as ETH/USD", auditor, "ipfs://QmBTCCriteria");
        DataOracleAgent.DataFeed memory bf = oracle.getFeed(btcFeed);
        vm.prank(auditor);
        valReg.validationResponse(bf.validationId, true, "ipfs://QmBTCApproved");

        vm.prank(agentOwner);
        oracle.activateFeed{value: 0.05 ether}(btcFeed); // only 0.05 ETH needed!
        console.log("BTC/USD feed activated with only 0.05 ETH stake (thanks to reputation)");

        // 10. Dispute scenario: bad data on BTC feed
        vm.prank(agentOwner);
        oracle.publishData(btcFeed, 99999999, 9500); // obviously wrong data

        uint256 disputerBal = disputer.balance;
        vm.prank(disputer);
        oracle.disputeData(btcFeed, "ipfs://QmWrongPrice");
        console.log("BTC feed disputed, slash amount:", disputer.balance - disputerBal);

        // Feed is now suspended
        assertTrue(oracle.getFeed(btcFeed).status == DataOracleAgent.FeedStatus.Suspended);

        // 11. Cross-agent validation: oracle validates a DeFiYieldAgent
        address yieldOwner = makeAddr("yieldOwner");
        vm.prank(yieldOwner);
        DeFiYieldAgent yieldAgent = new DeFiYieldAgent(address(idReg), address(repReg), address(valReg));

        vm.prank(yieldOwner);
        uint256 sid = yieldAgent.proposeStrategy(
            "Oracle-backed Strategy", "Uses DataOracleAgent for price data", address(oracle), "ipfs://QmStratCriteria"
        );
        DeFiYieldAgent.Strategy memory strat = yieldAgent.getStrategy(sid);

        vm.prank(agentOwner);
        oracle.validateOtherAgent(strat.validationId, true, "ipfs://QmStratApproved");
        console.log("Validated DeFiYieldAgent strategy: PASSED");

        // 12. Final stats
        (uint256 total,, uint256 active, uint256 suspended,) = oracle.getFeedStats();
        console.log("Feed stats - Total:", total, "Active:", active);
        console.log("Feed stats - Suspended:", suspended);
        console.log("Total data points published:", oracle.totalDataPoints());
        console.log("Total slashed:", oracle.totalSlashed());

        console.log("=== Scenario Complete ===");
    }

    // ═══════ Helpers ═══════

    function _createAndValidateFeed(string memory pair, string memory desc) internal returns (uint256 fid) {
        vm.prank(agentOwner);
        fid = oracle.registerFeed(pair, desc, auditor, "ipfs://QmCriteria");

        DataOracleAgent.DataFeed memory f = oracle.getFeed(fid);

        vm.prank(auditor);
        valReg.validationResponse(f.validationId, true, "ipfs://QmApproved");
    }

    function _activateFeed(string memory pair, string memory desc) internal returns (uint256 fid) {
        fid = _createAndValidateFeed(pair, desc);

        uint256 requiredStake = oracle.getRequiredStake();
        vm.prank(agentOwner);
        oracle.activateFeed{value: requiredStake}(fid);
    }
}
