// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import {AccessManaged} from "openzeppelin-contracts/contracts/access/manager/AccessManaged.sol";

/// @title MyContract - AccessManager 集成示例
/// @notice 演示如何在合约中集成 OpenZeppelin AccessManager
/// @dev 角色通过 AccessManager 配置，不是通过 modifier 参数
contract MyContract is AccessManaged {
    // ===== 角色定义 =====
    uint64 constant ADMIN_ROLE = 0;       // 管理员：最高权限，管理其他角色
    uint64 constant OPERATOR_ROLE = 1;    // 操作员：日常运营操作
    uint64 constant FINANCE_ROLE = 2;     // 财务：资金相关操作
    uint64 constant MINTER_ROLE = 3;      // 铸造员：代币铸造权限
    uint64 constant PAUSER_ROLE = 4;      // 暂停员：紧急暂停合约
    uint64 constant VIEWER_ROLE = 5;       // 观察者：只读访问

    // ===== 状态变量 =====
    uint256 public value;
    address public owner;
    address public ethSink;  // ETH 接收地址
    bool public paused;
    uint256 public totalMinted;

    /// @notice 初始化 AccessManager
    /// @param _accessManager AccessManager 合约地址
    /// @param _ethSink ETH 接收地址
    constructor(address _accessManager, address _ethSink) AccessManaged(_accessManager) {
        owner = msg.sender;
        ethSink = _ethSink;
        paused = false;
    }

    // ===== 运营操作 (OPERATOR_ROLE) =====
    /// @notice 设置值 - 需要 OPERATOR 角色
    function setValue(uint256 _value) external restricted {
        value = _value;
    }

    /// @notice 重置值 - 需要 OPERATOR 角色
    function resetValue() external restricted {
        value = 0;
    }

    // ===== 财务操作 (FINANCE_ROLE) =====
    /// @notice 提款 - 需要 FINANCE 角色
    function withdraw() external restricted {
        require(address(this).balance > 0, "no balance");
        payable(ethSink).transfer(address(this).balance);
    }

    /// @notice 转账 - 需要 FINANCE 角色
    function transferTo(address to, uint256 amount) external restricted {
        require(amount > 0, "amount is zero");
        payable(to).transfer(amount);
    }

    // ===== 铸造操作 (MINTER_ROLE) =====
    /// @notice 铸造代币 - 需要 MINTER 角色
    function mint(uint256 amount) external restricted {
        totalMinted += amount;
    }

    // ===== 暂停操作 (PAUSER_ROLE) =====
    /// @notice 暂停合约 - 需要 PAUSER 角色
    function pause() external restricted {
        paused = true;
    }

    /// @notice 恢复合约 - 需要 PAUSER 角色
    function unpause() external restricted {
        paused = false;
    }

    // ===== 观察操作 (VIEWER_ROLE) =====
    /// @notice 获取完整状态 - 需要 VIEWER 角色
    function getFullStatus() external restricted returns (
        uint256 _value,
        uint256 _balance,
        uint256 _totalMinted,
        bool _paused,
        address _owner
    ) {
        return (value, address(this).balance, totalMinted, paused, owner);
    }

    // ===== 公开函数 (无角色限制) =====
    /// @notice 读取值 - 公开函数
    function getValue() external view returns (uint256) {
        return value;
    }

    /// @notice 获取合约余额
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice 查询暂停状态
    function isPaused() external view returns (bool) {
        return paused;
    }

    /// @notice 接收 ETH
    receive() external payable {}
}