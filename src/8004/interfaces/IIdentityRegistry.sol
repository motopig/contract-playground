// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IIdentityRegistry – EIP-8004 Identity Registry Interface
/// @notice Manages agent registration, discovery, and metadata via ERC-721-like identity tokens.
interface IIdentityRegistry {
    // ───────── Events ─────────
    event Registered(uint256 indexed agentId, address indexed owner, string agentURI);
    event URIUpdated(uint256 indexed agentId, string newURI);
    event MetadataSet(uint256 indexed agentId, string key, string value);
    event AgentWalletSet(uint256 indexed agentId, address wallet);
    event AgentWalletUnset(uint256 indexed agentId, address wallet);

    // ───────── Write ─────────

    /// @notice Register a new agent identity; mints an NFT-like token.
    /// @param agentURI A data-URI (or IPFS/HTTP) pointing to agent metadata JSON.
    /// @return agentId The newly assigned agent ID.
    function register(string calldata agentURI) external returns (uint256 agentId);

    /// @notice Update the metadata URI associated with an agent.
    function setAgentURI(uint256 agentId, string calldata newURI) external;

    /// @notice Set a key-value metadata pair on-chain for an agent.
    function setMetadata(uint256 agentId, string calldata key, string calldata value) external;

    /// @notice Associate an additional wallet with the agent.
    function setAgentWallet(uint256 agentId, address wallet) external;

    /// @notice Remove a previously associated wallet.
    function unsetAgentWallet(uint256 agentId, address wallet) external;

    // ───────── Read ─────────

    /// @notice Returns the metadata URI for an agent.
    function agentURI(uint256 agentId) external view returns (string memory);

    /// @notice Returns the owner address of an agent.
    function ownerOf(uint256 agentId) external view returns (address);

    /// @notice Returns on-chain metadata value for a given key.
    function getMetadata(uint256 agentId, string calldata key) external view returns (string memory);

    /// @notice Returns the wallet associated with the agent (address(0) if unset).
    function getAgentWallet(uint256 agentId) external view returns (address);

    /// @notice Returns the total number of registered agents (also serves as next ID hint).
    function totalAgents() external view returns (uint256);
}
