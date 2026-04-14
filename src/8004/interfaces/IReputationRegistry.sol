// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReputationRegistry – EIP-8004 Reputation Registry Interface
/// @notice Records feedback signals for agents and provides simple on-chain aggregation.
interface IReputationRegistry {
    // ───────── Structs ─────────
    struct Feedback {
        uint256 feedbackId;
        uint256 agentId;
        address reviewer;
        uint8 score; // 0-100
        string comment;
        uint256 timestamp;
        bool revoked;
    }

    struct Summary {
        uint256 totalFeedbacks;
        uint256 activeFeedbacks;
        uint256 averageScore; // scaled ×100 for 2-decimal precision (e.g. 8533 = 85.33)
    }

    // ───────── Events ─────────
    event FeedbackGiven(uint256 indexed feedbackId, uint256 indexed agentId, address indexed reviewer, uint8 score);
    event FeedbackRevoked(uint256 indexed feedbackId, uint256 indexed agentId, address indexed reviewer);
    event ResponseAppended(uint256 indexed feedbackId, uint256 indexed agentId, string response);

    // ───────── Write ─────────

    /// @notice Submit feedback for an agent (score 0-100).
    function giveFeedback(uint256 agentId, uint8 score, string calldata comment) external returns (uint256 feedbackId);

    /// @notice Revoke previously submitted feedback (only original reviewer).
    function revokeFeedback(uint256 feedbackId) external;

    /// @notice Agent owner appends a response to a piece of feedback.
    function appendResponse(uint256 feedbackId, string calldata response) external;

    // ───────── Read ─────────

    /// @notice Get summary statistics for an agent.
    function getSummary(uint256 agentId) external view returns (Summary memory);

    /// @notice Read a single feedback entry.
    function readFeedback(uint256 feedbackId) external view returns (Feedback memory);

    /// @notice Read all feedback IDs for an agent.
    function readAllFeedback(uint256 agentId) external view returns (uint256[] memory feedbackIds);
}
