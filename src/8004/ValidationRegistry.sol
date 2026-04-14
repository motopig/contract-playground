// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidationRegistry} from "./interfaces/IValidationRegistry.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title ValidationRegistry – EIP-8004 Demo Implementation
/// @notice Manages validation request/response lifecycle with binary pass/fail outcomes.
contract ValidationRegistry is IValidationRegistry {
    // ───────── State ─────────
    IIdentityRegistry public immutable identity;

    uint256 private _nextValidationId = 1;

    mapping(uint256 => ValidationRecord) private _records;
    mapping(uint256 => uint256[]) private _agentValidations;

    // agentId => summary counters
    struct Counters {
        uint256 total;
        uint256 passed;
        uint256 failed;
    }

    mapping(uint256 => Counters) private _counters;

    // ───────── Constructor ─────────
    constructor(address _identity) {
        identity = IIdentityRegistry(_identity);
    }

    // ───────── Modifiers ─────────
    modifier validAgent(uint256 agentId) {
        require(identity.ownerOf(agentId) != address(0), "ValidationRegistry: agent not registered");
        _;
    }

    // ───────── Write ─────────

    /// @inheritdoc IValidationRegistry
    function validationRequest(uint256 agentId, address validator, string calldata requestURI)
        external
        validAgent(agentId)
        returns (uint256 validationId)
    {
        require(validator != address(0), "ValidationRegistry: zero validator");

        validationId = _nextValidationId++;
        _records[validationId] = ValidationRecord({
            validationId: validationId,
            agentId: agentId,
            requester: msg.sender,
            validator: validator,
            status: ValidationStatus.Pending,
            requestURI: requestURI,
            responseURI: "",
            requestedAt: block.timestamp,
            respondedAt: 0
        });
        _agentValidations[agentId].push(validationId);
        _counters[agentId].total++;

        emit ValidationRequested(validationId, agentId, msg.sender, validator);
    }

    /// @inheritdoc IValidationRegistry
    function validationResponse(uint256 validationId, bool passed, string calldata responseURI) external {
        ValidationRecord storage r = _records[validationId];
        require(r.requestedAt != 0, "ValidationRegistry: not found");
        require(r.validator == msg.sender, "ValidationRegistry: not designated validator");
        require(r.status == ValidationStatus.Pending, "ValidationRegistry: already resolved");

        r.status = passed ? ValidationStatus.Passed : ValidationStatus.Failed;
        r.responseURI = responseURI;
        r.respondedAt = block.timestamp;

        Counters storage c = _counters[r.agentId];
        if (passed) {
            c.passed++;
        } else {
            c.failed++;
        }

        emit ValidationResponded(validationId, r.agentId, r.status);
    }

    // ───────── Read ─────────

    /// @inheritdoc IValidationRegistry
    function getValidationStatus(uint256 validationId) external view returns (ValidationStatus) {
        require(_records[validationId].requestedAt != 0, "ValidationRegistry: not found");
        return _records[validationId].status;
    }

    /// @inheritdoc IValidationRegistry
    function getValidation(uint256 validationId) external view returns (ValidationRecord memory) {
        require(_records[validationId].requestedAt != 0, "ValidationRegistry: not found");
        return _records[validationId];
    }

    /// @inheritdoc IValidationRegistry
    function getSummary(uint256 agentId) external view returns (ValidSummary memory) {
        Counters storage c = _counters[agentId];
        return
            ValidSummary({total: c.total, passed: c.passed, failed: c.failed, pending: c.total - c.passed - c.failed});
    }

    /// @inheritdoc IValidationRegistry
    function getAgentValidations(uint256 agentId) external view returns (uint256[] memory) {
        return _agentValidations[agentId];
    }
}
