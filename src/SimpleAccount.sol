// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseAccount} from "account-abstraction-0.9.0/contracts/core/BaseAccount.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "account-abstraction-0.9.0/contracts/core/Helpers.sol";
import {TokenCallbackHandler} from "account-abstraction-0.9.0/contracts/accounts/callback/TokenCallbackHandler.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SimpleAccount
 * @notice 一个最小化的 ERC-4337 智能合约账户实现
 * @dev 支持:
 *   - 单一 owner（ECDSA 签名）
 *   - 单笔和批量执行
 *   - UUPS 可升级
 *   - 代理模式部署（通过 Factory）
 */
contract SimpleAccount is BaseAccount, TokenCallbackHandler, UUPSUpgradeable, Initializable {
    address public owner;

    IEntryPoint private immutable _entryPoint;

    event SimpleAccountInitialized(IEntryPoint indexed entryPoint, address indexed owner);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    error NotOwner(address caller);
    error NotOwnerOrEntryPoint(address caller);

    modifier onlyOwner() {
        if (msg.sender != owner && msg.sender != address(this)) {
            revert NotOwner(msg.sender);
        }
        _;
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    receive() external payable {}

    constructor(IEntryPoint anEntryPoint) {
        _entryPoint = anEntryPoint;
        _disableInitializers();
    }

    /**
     * @notice 初始化账户（仅可调用一次）
     * @param anOwner 账户 owner 地址
     */
    function initialize(address anOwner) public virtual initializer {
        owner = anOwner;
        emit SimpleAccountInitialized(_entryPoint, anOwner);
    }

    /**
     * @notice 转移 owner
     * @param newOwner 新的 owner 地址
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "invalid owner");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnerChanged(oldOwner, newOwner);
    }

    // ─── 执行权限 ────────────────────────────────────────────

    function _requireForExecute() internal view virtual override {
        if (msg.sender != address(entryPoint()) && msg.sender != owner) {
            revert NotOwnerOrEntryPoint(msg.sender);
        }
    }

    // ─── 签名验证 ────────────────────────────────────────────

    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        virtual
        override
        returns (uint256 validationData)
    {
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        if (owner != ECDSA.recover(hash, userOp.signature)) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    // ─── Deposit 管理 ────────────────────────────────────────

    function getDeposit() public view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    function addDeposit() public payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public onlyOwner {
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    // ─── UUPS ────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != owner && msg.sender != address(this)) {
            revert NotOwner(msg.sender);
        }
    }
}
