// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IdentityRegistry} from "../../src/8004/IdentityRegistry.sol";
import {ValidationRegistry} from "../../src/8004/ValidationRegistry.sol";
import {IValidationRegistry} from "../../src/8004/interfaces/IValidationRegistry.sol";

contract ValidationTest is Test {
    IdentityRegistry public idReg;
    ValidationRegistry public valReg;

    address agentOwner = makeAddr("agentOwner");
    address requester = makeAddr("requester");
    address validator = makeAddr("validator");

    uint256 agentId;

    function setUp() public {
        idReg = new IdentityRegistry();
        valReg = new ValidationRegistry(address(idReg));

        vm.prank(agentOwner);
        agentId = idReg.register("data:application/json,{}");
    }

    // ───────── Request ─────────

    function test_validationRequest_basic() public {
        vm.prank(requester);
        uint256 vid = valReg.validationRequest(agentId, validator, "ipfs://criteria");

        assertEq(vid, 1);
        IValidationRegistry.ValidationRecord memory r = valReg.getValidation(vid);
        assertEq(r.agentId, agentId);
        assertEq(r.requester, requester);
        assertEq(r.validator, validator);
        assertTrue(r.status == IValidationRegistry.ValidationStatus.Pending);
    }

    function test_validationRequest_emitsEvent() public {
        vm.prank(requester);
        vm.expectEmit(true, true, true, true);
        emit IValidationRegistry.ValidationRequested(1, agentId, requester, validator);
        valReg.validationRequest(agentId, validator, "ipfs://criteria");
    }

    function test_validationRequest_revertZeroValidator() public {
        vm.prank(requester);
        vm.expectRevert("ValidationRegistry: zero validator");
        valReg.validationRequest(agentId, address(0), "x");
    }

    function test_validationRequest_revertUnregisteredAgent() public {
        vm.prank(requester);
        vm.expectRevert();
        valReg.validationRequest(999, validator, "x");
    }

    // ───────── Response ─────────

    function test_validationResponse_pass() public {
        vm.prank(requester);
        uint256 vid = valReg.validationRequest(agentId, validator, "ipfs://criteria");

        vm.prank(validator);
        valReg.validationResponse(vid, true, "ipfs://evidence");

        assertTrue(valReg.getValidationStatus(vid) == IValidationRegistry.ValidationStatus.Passed);

        IValidationRegistry.ValidationRecord memory r = valReg.getValidation(vid);
        assertEq(r.responseURI, "ipfs://evidence");
        assertGt(r.respondedAt, 0);
    }

    function test_validationResponse_fail() public {
        vm.prank(requester);
        uint256 vid = valReg.validationRequest(agentId, validator, "ipfs://criteria");

        vm.prank(validator);
        valReg.validationResponse(vid, false, "ipfs://fail-report");

        assertTrue(valReg.getValidationStatus(vid) == IValidationRegistry.ValidationStatus.Failed);
    }

    function test_validationResponse_revertNotValidator() public {
        vm.prank(requester);
        uint256 vid = valReg.validationRequest(agentId, validator, "ipfs://criteria");

        vm.prank(requester); // wrong caller
        vm.expectRevert("ValidationRegistry: not designated validator");
        valReg.validationResponse(vid, true, "x");
    }

    function test_validationResponse_revertAlreadyResolved() public {
        vm.prank(requester);
        uint256 vid = valReg.validationRequest(agentId, validator, "ipfs://criteria");

        vm.prank(validator);
        valReg.validationResponse(vid, true, "ipfs://evidence");

        vm.prank(validator);
        vm.expectRevert("ValidationRegistry: already resolved");
        valReg.validationResponse(vid, false, "x");
    }

    // ───────── Summary ─────────

    function test_summary() public {
        vm.startPrank(requester);
        uint256 v1 = valReg.validationRequest(agentId, validator, "a");
        uint256 v2 = valReg.validationRequest(agentId, validator, "b");
        valReg.validationRequest(agentId, validator, "c"); // v3 stays pending
        vm.stopPrank();

        vm.startPrank(validator);
        valReg.validationResponse(v1, true, "");
        valReg.validationResponse(v2, false, "");
        vm.stopPrank();

        IValidationRegistry.ValidSummary memory s = valReg.getSummary(agentId);
        assertEq(s.total, 3);
        assertEq(s.passed, 1);
        assertEq(s.failed, 1);
        assertEq(s.pending, 1);
    }

    // ───────── Agent Validations List ─────────

    function test_getAgentValidations() public {
        vm.startPrank(requester);
        valReg.validationRequest(agentId, validator, "a");
        valReg.validationRequest(agentId, validator, "b");
        vm.stopPrank();

        uint256[] memory ids = valReg.getAgentValidations(agentId);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }
}
