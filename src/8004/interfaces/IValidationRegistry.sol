// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IValidationRegistry – EIP-8004 Validation Registry Interface
/// @notice Manages validation requests and binary (pass/fail) responses for agents.
interface IValidationRegistry {
    // ───────── Enums ─────────
    enum ValidationStatus {
        Pending,
        Passed,
        Failed
    }

    // ───────── Structs ─────────
    struct ValidationRecord {
        uint256 validationId;
        uint256 agentId;
        address requester;
        address validator;
        ValidationStatus status;
        string requestURI; // pointer to off-chain validation criteria
        string responseURI; // pointer to off-chain evidence / report
        uint256 requestedAt;
        uint256 respondedAt;
    }

    struct ValidSummary {
        uint256 total;
        uint256 passed;
        uint256 failed;
        uint256 pending;
    }

    // ───────── Events ─────────
    event ValidationRequested(
        uint256 indexed validationId, uint256 indexed agentId, address indexed requester, address validator
    );
    event ValidationResponded(uint256 indexed validationId, uint256 indexed agentId, ValidationStatus status);

    // ───────── Write ─────────

    /// @notice Create a validation request targeting a specific validator.
    function validationRequest(uint256 agentId, address validator, string calldata requestURI)
        external
        returns (uint256 validationId);

    /// @notice Validator responds with pass/fail and optional evidence URI.
    function validationResponse(uint256 validationId, bool passed, string calldata responseURI) external;

    // ───────── Read ─────────

    /// @notice Get the current status of a validation.
    function getValidationStatus(uint256 validationId) external view returns (ValidationStatus);

    /// @notice Get full record for a validation.
    function getValidation(uint256 validationId) external view returns (ValidationRecord memory);

    /// @notice Get summary counts for an agent.
    function getSummary(uint256 agentId) external view returns (ValidSummary memory);

    /// @notice Get all validation IDs associated with an agent.
    function getAgentValidations(uint256 agentId) external view returns (uint256[] memory);
}
