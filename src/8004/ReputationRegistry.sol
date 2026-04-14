// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title ReputationRegistry – EIP-8004 Demo Implementation
/// @notice Records per-agent feedback with simple average-score aggregation.
contract ReputationRegistry is IReputationRegistry {
    // ───────── State ─────────
    IIdentityRegistry public immutable identity;

    uint256 private _nextFeedbackId = 1;

    // feedbackId => Feedback
    mapping(uint256 => Feedback) private _feedbacks;
    // feedbackId => response string (agent's reply)
    mapping(uint256 => string) private _responses;
    // agentId => feedbackId[]
    mapping(uint256 => uint256[]) private _agentFeedbacks;

    // agentId => running aggregation
    struct Agg {
        uint256 sumScores; // sum of active scores
        uint256 activeCount; // active (non-revoked) feedbacks
        uint256 totalCount; // total ever submitted
    }

    mapping(uint256 => Agg) private _agg;

    // ───────── Constructor ─────────
    constructor(address _identity) {
        identity = IIdentityRegistry(_identity);
    }

    // ───────── Modifiers ─────────
    modifier validAgent(uint256 agentId) {
        // Ensure agent is registered in the identity registry.
        require(identity.ownerOf(agentId) != address(0), "ReputationRegistry: agent not registered");
        _;
    }

    // ───────── Write ─────────

    /// @inheritdoc IReputationRegistry
    function giveFeedback(uint256 agentId, uint8 score, string calldata comment)
        external
        validAgent(agentId)
        returns (uint256 feedbackId)
    {
        require(score <= 100, "ReputationRegistry: score > 100");

        feedbackId = _nextFeedbackId++;
        _feedbacks[feedbackId] = Feedback({
            feedbackId: feedbackId,
            agentId: agentId,
            reviewer: msg.sender,
            score: score,
            comment: comment,
            timestamp: block.timestamp,
            revoked: false
        });
        _agentFeedbacks[agentId].push(feedbackId);

        Agg storage a = _agg[agentId];
        a.sumScores += score;
        a.activeCount++;
        a.totalCount++;

        emit FeedbackGiven(feedbackId, agentId, msg.sender, score);
    }

    /// @inheritdoc IReputationRegistry
    function revokeFeedback(uint256 feedbackId) external {
        Feedback storage fb = _feedbacks[feedbackId];
        require(fb.reviewer == msg.sender, "ReputationRegistry: not reviewer");
        require(!fb.revoked, "ReputationRegistry: already revoked");

        fb.revoked = true;

        Agg storage a = _agg[fb.agentId];
        a.sumScores -= fb.score;
        a.activeCount--;

        emit FeedbackRevoked(feedbackId, fb.agentId, msg.sender);
    }

    /// @inheritdoc IReputationRegistry
    function appendResponse(uint256 feedbackId, string calldata response) external {
        Feedback storage fb = _feedbacks[feedbackId];
        require(fb.agentId != 0, "ReputationRegistry: feedback does not exist");
        require(identity.ownerOf(fb.agentId) == msg.sender, "ReputationRegistry: not agent owner");

        _responses[feedbackId] = response;
        emit ResponseAppended(feedbackId, fb.agentId, response);
    }

    // ───────── Read ─────────

    /// @inheritdoc IReputationRegistry
    function getSummary(uint256 agentId) external view returns (Summary memory) {
        Agg storage a = _agg[agentId];
        uint256 avg = a.activeCount > 0 ? (a.sumScores * 100) / a.activeCount : 0;
        return Summary({totalFeedbacks: a.totalCount, activeFeedbacks: a.activeCount, averageScore: avg});
    }

    /// @inheritdoc IReputationRegistry
    function readFeedback(uint256 feedbackId) external view returns (Feedback memory) {
        require(_feedbacks[feedbackId].timestamp != 0, "ReputationRegistry: not found");
        return _feedbacks[feedbackId];
    }

    /// @inheritdoc IReputationRegistry
    function readAllFeedback(uint256 agentId) external view returns (uint256[] memory feedbackIds) {
        return _agentFeedbacks[agentId];
    }

    /// @notice Read the agent's response to a feedback.
    function readResponse(uint256 feedbackId) external view returns (string memory) {
        return _responses[feedbackId];
    }
}
