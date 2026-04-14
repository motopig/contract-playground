// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title IdentityRegistry – EIP-8004 Demo Implementation
/// @notice Minimal agent identity registry with ERC-721-like semantics (non-transferable).
contract IdentityRegistry is IIdentityRegistry {
    // ───────── State ─────────
    uint256 private _nextId = 1;

    struct Agent {
        address owner;
        string uri;
        address wallet;
    }

    mapping(uint256 => Agent) private _agents;
    mapping(uint256 => mapping(string => string)) private _metadata;

    // ───────── Modifiers ─────────
    modifier onlyAgentOwner(uint256 agentId) {
        require(_agents[agentId].owner == msg.sender, "IdentityRegistry: not owner");
        _;
    }

    modifier agentExists(uint256 agentId) {
        require(_agents[agentId].owner != address(0), "IdentityRegistry: agent does not exist");
        _;
    }

    // ───────── Write ─────────

    /// @inheritdoc IIdentityRegistry
    function register(string calldata _agentURI) external returns (uint256 agentId) {
        agentId = _nextId++;
        _agents[agentId] = Agent({owner: msg.sender, uri: _agentURI, wallet: address(0)});
        emit Registered(agentId, msg.sender, _agentURI);
    }

    /// @inheritdoc IIdentityRegistry
    function setAgentURI(uint256 agentId, string calldata newURI)
        external
        agentExists(agentId)
        onlyAgentOwner(agentId)
    {
        _agents[agentId].uri = newURI;
        emit URIUpdated(agentId, newURI);
    }

    /// @inheritdoc IIdentityRegistry
    function setMetadata(uint256 agentId, string calldata key, string calldata value)
        external
        agentExists(agentId)
        onlyAgentOwner(agentId)
    {
        _metadata[agentId][key] = value;
        emit MetadataSet(agentId, key, value);
    }

    /// @inheritdoc IIdentityRegistry
    function setAgentWallet(uint256 agentId, address wallet) external agentExists(agentId) onlyAgentOwner(agentId) {
        require(wallet != address(0), "IdentityRegistry: zero address");
        _agents[agentId].wallet = wallet;
        emit AgentWalletSet(agentId, wallet);
    }

    /// @inheritdoc IIdentityRegistry
    function unsetAgentWallet(uint256 agentId, address wallet) external agentExists(agentId) onlyAgentOwner(agentId) {
        require(_agents[agentId].wallet == wallet, "IdentityRegistry: wallet mismatch");
        _agents[agentId].wallet = address(0);
        emit AgentWalletUnset(agentId, wallet);
    }

    // ───────── Read ─────────

    /// @inheritdoc IIdentityRegistry
    function agentURI(uint256 agentId) external view agentExists(agentId) returns (string memory) {
        return _agents[agentId].uri;
    }

    /// @inheritdoc IIdentityRegistry
    function ownerOf(uint256 agentId) external view agentExists(agentId) returns (address) {
        return _agents[agentId].owner;
    }

    /// @inheritdoc IIdentityRegistry
    function getMetadata(uint256 agentId, string calldata key)
        external
        view
        agentExists(agentId)
        returns (string memory)
    {
        return _metadata[agentId][key];
    }

    /// @inheritdoc IIdentityRegistry
    function getAgentWallet(uint256 agentId) external view agentExists(agentId) returns (address) {
        return _agents[agentId].wallet;
    }

    /// @inheritdoc IIdentityRegistry
    function totalAgents() external view returns (uint256) {
        return _nextId - 1;
    }
}
