// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IdentityRegistry} from "../../src/8004/IdentityRegistry.sol";
import {ReputationRegistry} from "../../src/8004/ReputationRegistry.sol";
import {IReputationRegistry} from "../../src/8004/interfaces/IReputationRegistry.sol";

contract ReputationTest is Test {
    IdentityRegistry public idReg;
    ReputationRegistry public repReg;

    address agentOwner = makeAddr("agentOwner");
    address reviewer1 = makeAddr("reviewer1");
    address reviewer2 = makeAddr("reviewer2");

    uint256 agentId;

    function setUp() public {
        idReg = new IdentityRegistry();
        repReg = new ReputationRegistry(address(idReg));

        vm.prank(agentOwner);
        agentId = idReg.register("data:application/json,{}");
    }

    // ───────── Give Feedback ─────────

    function test_giveFeedback_basic() public {
        vm.prank(reviewer1);
        uint256 fid = repReg.giveFeedback(agentId, 85, "great agent");

        assertEq(fid, 1);
        IReputationRegistry.Feedback memory fb = repReg.readFeedback(fid);
        assertEq(fb.agentId, agentId);
        assertEq(fb.reviewer, reviewer1);
        assertEq(fb.score, 85);
        assertEq(fb.revoked, false);
    }

    function test_giveFeedback_emitsEvent() public {
        vm.prank(reviewer1);
        vm.expectEmit(true, true, true, true);
        emit IReputationRegistry.FeedbackGiven(1, agentId, reviewer1, 85);
        repReg.giveFeedback(agentId, 85, "nice");
    }

    function test_giveFeedback_revertUnregisteredAgent() public {
        vm.prank(reviewer1);
        vm.expectRevert(); // ownerOf will revert
        repReg.giveFeedback(999, 50, "x");
    }

    function test_giveFeedback_revertScoreOver100() public {
        vm.prank(reviewer1);
        vm.expectRevert("ReputationRegistry: score > 100");
        repReg.giveFeedback(agentId, 101, "x");
    }

    // ───────── Revoke ─────────

    function test_revokeFeedback() public {
        vm.prank(reviewer1);
        uint256 fid = repReg.giveFeedback(agentId, 80, "ok");

        vm.prank(reviewer1);
        repReg.revokeFeedback(fid);

        IReputationRegistry.Feedback memory fb = repReg.readFeedback(fid);
        assertTrue(fb.revoked);
    }

    function test_revokeFeedback_revertNotReviewer() public {
        vm.prank(reviewer1);
        uint256 fid = repReg.giveFeedback(agentId, 80, "ok");

        vm.prank(reviewer2);
        vm.expectRevert("ReputationRegistry: not reviewer");
        repReg.revokeFeedback(fid);
    }

    function test_revokeFeedback_revertDoubleRevoke() public {
        vm.prank(reviewer1);
        uint256 fid = repReg.giveFeedback(agentId, 80, "ok");

        vm.prank(reviewer1);
        repReg.revokeFeedback(fid);

        vm.prank(reviewer1);
        vm.expectRevert("ReputationRegistry: already revoked");
        repReg.revokeFeedback(fid);
    }

    // ───────── Append Response ─────────

    function test_appendResponse() public {
        vm.prank(reviewer1);
        uint256 fid = repReg.giveFeedback(agentId, 90, "awesome");

        vm.prank(agentOwner);
        repReg.appendResponse(fid, "thanks!");

        assertEq(repReg.readResponse(fid), "thanks!");
    }

    function test_appendResponse_revertNotAgentOwner() public {
        vm.prank(reviewer1);
        uint256 fid = repReg.giveFeedback(agentId, 90, "awesome");

        vm.prank(reviewer1);
        vm.expectRevert("ReputationRegistry: not agent owner");
        repReg.appendResponse(fid, "nope");
    }

    // ───────── Summary / Aggregation ─────────

    function test_summary_singleFeedback() public {
        vm.prank(reviewer1);
        repReg.giveFeedback(agentId, 80, "");

        IReputationRegistry.Summary memory s = repReg.getSummary(agentId);
        assertEq(s.totalFeedbacks, 1);
        assertEq(s.activeFeedbacks, 1);
        // averageScore = 80 * 100 = 8000
        assertEq(s.averageScore, 8000);
    }

    function test_summary_multipleFeedbacks() public {
        vm.prank(reviewer1);
        repReg.giveFeedback(agentId, 80, "");
        vm.prank(reviewer2);
        repReg.giveFeedback(agentId, 90, "");

        IReputationRegistry.Summary memory s = repReg.getSummary(agentId);
        assertEq(s.totalFeedbacks, 2);
        assertEq(s.activeFeedbacks, 2);
        // avg = (80+90)*100/2 = 8500
        assertEq(s.averageScore, 8500);
    }

    function test_summary_afterRevoke() public {
        vm.prank(reviewer1);
        uint256 fid1 = repReg.giveFeedback(agentId, 80, "");
        vm.prank(reviewer2);
        repReg.giveFeedback(agentId, 90, "");

        vm.prank(reviewer1);
        repReg.revokeFeedback(fid1);

        IReputationRegistry.Summary memory s = repReg.getSummary(agentId);
        assertEq(s.totalFeedbacks, 2);
        assertEq(s.activeFeedbacks, 1);
        // avg = 90*100/1 = 9000
        assertEq(s.averageScore, 9000);
    }

    // ───────── Read All ─────────

    function test_readAllFeedback() public {
        vm.prank(reviewer1);
        repReg.giveFeedback(agentId, 80, "");
        vm.prank(reviewer2);
        repReg.giveFeedback(agentId, 90, "");

        uint256[] memory ids = repReg.readAllFeedback(agentId);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }
}
