// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @title MyAccessControlContract - AccessControl 集成示例
/// @notice 演示基于 OpenZeppelin AccessControl 的角色授权与访问控制
contract MyAccessControlContract is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    error ContractPaused();
    error AlreadyPaused();
    error AlreadyUnpaused();

    event ValueUpdated(uint256 newValue);
    event Minted(uint256 amount, uint256 newTotalMinted);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    uint256 public value;
    uint256 public totalMinted;
    bool public paused;

    modifier whenNotPaused() {
        if (paused) {
            revert ContractPaused();
        }
        _;
    }

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice 更新示例数值，仅 OPERATOR_ROLE 可调用
    function setValue(uint256 newValue) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        value = newValue;
        emit ValueUpdated(newValue);
    }

    /// @notice 增加铸造总量，仅 MINTER_ROLE 可调用
    function mint(uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        totalMinted += amount;
        emit Minted(amount, totalMinted);
    }

    /// @notice 暂停开关，仅 PAUSER_ROLE 可调用
    function pause() external onlyRole(PAUSER_ROLE) {
        if (paused) {
            revert AlreadyPaused();
        }
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice 恢复开关，仅 PAUSER_ROLE 可调用
    function unpause() external onlyRole(PAUSER_ROLE) {
        if (!paused) {
            revert AlreadyUnpaused();
        }
        paused = false;
        emit Unpaused(msg.sender);
    }
}
