// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseAccount} from "account-abstraction-0.9.0/contracts/core/BaseAccount.sol";
import {IAccountExecute} from "account-abstraction-0.9.0/contracts/interfaces/IAccountExecute.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {
    SIG_VALIDATION_FAILED,
    SIG_VALIDATION_SUCCESS,
    _packValidationData
} from "account-abstraction-0.9.0/contracts/core/Helpers.sol";
import {TokenCallbackHandler} from "account-abstraction-0.9.0/contracts/accounts/callback/TokenCallbackHandler.sol";
import {Exec} from "account-abstraction-0.9.0/contracts/utils/Exec.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SessionKeyAccount
 * @notice 演示 IAccountExecute.executeUserOp 的 ERC-4337 账户实现
 * @dev 核心特性:
 *   - Owner（ECDSA）拥有完整权限，可通过 execute/executeBatch 直接调用
 *   - Session Key 拥有受限权限:
 *     - 限定可调用的目标合约
 *     - 限定单笔最大 ETH 值
 *     - 时间范围限制（validAfter / validUntil）
 *   - Session Key 必须通过 executeUserOp 路径执行（EntryPoint 自动将完整 UserOp 传入，
 *     账户在执行阶段读取 signature 以识别签名者并校验权限）
 *
 * 签名格式:
 *   Owner:      0x00 || ecdsaSignature (1 + 65 = 66 bytes)
 *   SessionKey: 0x01 || sessionKeyAddr || ecdsaSignature (1 + 20 + 65 = 86 bytes)
 *
 * UserOp callData 编码（使用 executeUserOp 时）:
 *   executeUserOp.selector || abi.encode(Call[])
 */
contract SessionKeyAccount is BaseAccount, IAccountExecute, TokenCallbackHandler, UUPSUpgradeable, Initializable {
    // ─── 常量 ─────────────────────────────────────────────
    uint8 internal constant SIG_TYPE_OWNER = 0x00;
    uint8 internal constant SIG_TYPE_SESSION_KEY = 0x01;

    // ─── Session Key 数据 ─────────────────────────────────
    struct SessionKeyData {
        bool enabled;
        uint48 validAfter;
        uint48 validUntil; // 0 = 永不过期
        uint256 maxCallValue; // 单笔调用最大 ETH 值
    }

    // ─── 状态变量 ─────────────────────────────────────────
    address public owner;
    IEntryPoint private immutable _entryPoint;

    /// @dev sessionKey address => data
    mapping(address => SessionKeyData) public sessionKeys;
    /// @dev sessionKey address => target address => allowed
    mapping(address => mapping(address => bool)) public allowedTargets;

    // ─── 事件 ─────────────────────────────────────────────
    event SessionKeyAccountInitialized(IEntryPoint indexed entryPoint, address indexed owner);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event SessionKeyAdded(
        address indexed sessionKey, address[] allowedTargets, uint256 maxCallValue, uint48 validAfter, uint48 validUntil
    );
    event SessionKeyRevoked(address indexed sessionKey);

    // ─── 错误 ─────────────────────────────────────────────
    error NotOwner(address caller);
    error NotOwnerOrEntryPoint(address caller);
    error SessionKeyNotEnabled(address sessionKey);
    error SessionKeyTargetNotAllowed(address sessionKey, address target);
    error SessionKeyValueExceeded(address sessionKey, uint256 value, uint256 maxValue);
    error InvalidSignatureType(uint8 sigType);

    // ─── 修饰符 ────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner && msg.sender != address(this)) {
            revert NotOwner(msg.sender);
        }
        _;
    }

    // ─── 构造 & 初始化 ─────────────────────────────────────

    constructor(IEntryPoint anEntryPoint) {
        _entryPoint = anEntryPoint;
        _disableInitializers();
    }

    function initialize(address anOwner) public virtual initializer {
        owner = anOwner;
        emit SessionKeyAccountInitialized(_entryPoint, anOwner);
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    receive() external payable {}

    // ═══════════════════════════════════════════════════════
    //  Session Key 管理（仅 owner）
    // ═══════════════════════════════════════════════════════

    /**
     * @notice 注册一个 Session Key
     * @param sessionKey Session Key 的 EOA 地址
     * @param targets 允许调用的目标合约地址列表
     * @param maxCallValue 单笔调用最大 ETH 值
     * @param validAfter 生效时间戳
     * @param validUntil 过期时间戳（0 = 永不过期）
     */
    function addSessionKey(
        address sessionKey,
        address[] calldata targets,
        uint256 maxCallValue,
        uint48 validAfter,
        uint48 validUntil
    ) external onlyOwner {
        sessionKeys[sessionKey] = SessionKeyData({
            enabled: true, validAfter: validAfter, validUntil: validUntil, maxCallValue: maxCallValue
        });

        for (uint256 i = 0; i < targets.length; i++) {
            allowedTargets[sessionKey][targets[i]] = true;
        }

        emit SessionKeyAdded(sessionKey, targets, maxCallValue, validAfter, validUntil);
    }

    /**
     * @notice 撤销一个 Session Key
     * @param sessionKey 要撤销的 Session Key 地址
     * @param targets 需要清除的目标合约列表（由 off-chain 提供）
     */
    function revokeSessionKey(address sessionKey, address[] calldata targets) external onlyOwner {
        delete sessionKeys[sessionKey];
        for (uint256 i = 0; i < targets.length; i++) {
            allowedTargets[sessionKey][targets[i]] = false;
        }
        emit SessionKeyRevoked(sessionKey);
    }

    // ═══════════════════════════════════════════════════════
    //  IAccountExecute — Session Key 通过此路径执行
    // ═══════════════════════════════════════════════════════

    /**
     * @notice 由 EntryPoint 调用，当 UserOp.callData 以 executeUserOp selector 开头时触发
     * @dev EntryPoint 会将完整 UserOp 和 hash 传入，本函数：
     *   1. 从 userOp.callData[4:] 解码出 Call[] （跳过 selector）
     *   2. 从 userOp.signature 解析签名者类型
     *   3. 如果是 Session Key，校验每个 Call 的目标和金额权限
     *   4. 执行所有 Call
     */
    function executeUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /* userOpHash */
    )
        external
        override
    {
        _requireFromEntryPoint();

        // 解码内嵌的调用数据（跳过前 4 字节的 executeUserOp selector）
        Call[] memory calls = abi.decode(userOp.callData[4:], (Call[]));

        // 检查签名类型，如果是 Session Key 则校验权限
        uint8 sigType = uint8(userOp.signature[0]);
        if (sigType == SIG_TYPE_SESSION_KEY) {
            address sessionKey = address(bytes20(userOp.signature[1:21]));
            _checkSessionKeyPermissions(sessionKey, calls);
        }
        // sigType == SIG_TYPE_OWNER → Owner 无限制

        // 执行所有调用
        uint256 callsLength = calls.length;
        for (uint256 i = 0; i < callsLength; i++) {
            Call memory c = calls[i];
            bool ok = Exec.call(c.target, c.value, c.data, gasleft());
            if (!ok) {
                if (callsLength == 1) {
                    Exec.revertWithReturnData();
                } else {
                    revert ExecuteError(i, Exec.getReturnData(0));
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    //  权限控制
    // ═══════════════════════════════════════════════════════

    /**
     * @dev Owner 或 EntryPoint 可以直接调用 execute/executeBatch（继承自 BaseAccount）
     */
    function _requireForExecute() internal view virtual override {
        if (msg.sender != address(entryPoint()) && msg.sender != owner) {
            revert NotOwnerOrEntryPoint(msg.sender);
        }
    }

    // ═══════════════════════════════════════════════════════
    //  签名验证
    // ═══════════════════════════════════════════════════════

    /**
     * @dev 验证 UserOp 签名
     *
     * 签名格式:
     *   0x00 || ownerSig(65 bytes) — Owner 签名
     *   0x01 || sessionKeyAddr(20 bytes) || sessionKeySig(65 bytes) — Session Key 签名
     *
     * 对于 Session Key，同时返回时间范围数据供 EntryPoint 校验
     */
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        virtual
        override
        returns (uint256 validationData)
    {
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(userOpHash);

        uint8 sigType = uint8(userOp.signature[0]);

        if (sigType == SIG_TYPE_OWNER) {
            // Owner: 1 byte type + 65 bytes ECDSA
            bytes memory ownerSig = userOp.signature[1:66];
            if (owner != ECDSA.recover(hash, ownerSig)) {
                return SIG_VALIDATION_FAILED;
            }
            return SIG_VALIDATION_SUCCESS;
        }

        if (sigType == SIG_TYPE_SESSION_KEY) {
            // Session Key: 1 byte type + 20 bytes address + 65 bytes ECDSA
            address sessionKey = address(bytes20(userOp.signature[1:21]));
            bytes memory sessionSig = userOp.signature[21:86];

            // 检查 session key 是否已注册且启用
            SessionKeyData storage skData = sessionKeys[sessionKey];
            if (!skData.enabled) {
                return SIG_VALIDATION_FAILED;
            }

            // 验证签名确实来自该 session key
            if (sessionKey != ECDSA.recover(hash, sessionSig)) {
                return SIG_VALIDATION_FAILED;
            }

            // 返回时间范围，让 EntryPoint 做时间校验
            return _packValidationData(false, skData.validUntil, skData.validAfter);
        }

        // 未知签名类型
        return SIG_VALIDATION_FAILED;
    }

    // ═══════════════════════════════════════════════════════
    //  Session Key 权限校验（执行阶段）
    // ═══════════════════════════════════════════════════════

    function _checkSessionKeyPermissions(address sessionKey, Call[] memory calls) internal view {
        SessionKeyData storage perm = sessionKeys[sessionKey];

        if (!perm.enabled) {
            revert SessionKeyNotEnabled(sessionKey);
        }

        for (uint256 i = 0; i < calls.length; i++) {
            // 检查目标是否在白名单
            if (!allowedTargets[sessionKey][calls[i].target]) {
                revert SessionKeyTargetNotAllowed(sessionKey, calls[i].target);
            }
            // 检查 ETH 值
            if (calls[i].value > perm.maxCallValue) {
                revert SessionKeyValueExceeded(sessionKey, calls[i].value, perm.maxCallValue);
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    //  Owner 管理
    // ═══════════════════════════════════════════════════════

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "invalid owner");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnerChanged(oldOwner, newOwner);
    }

    // ═══════════════════════════════════════════════════════
    //  Deposit 管理
    // ═══════════════════════════════════════════════════════

    function getDeposit() public view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    function addDeposit() public payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public onlyOwner {
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    // ═══════════════════════════════════════════════════════
    //  UUPS
    // ═══════════════════════════════════════════════════════

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != owner && msg.sender != address(this)) {
            revert NotOwner(msg.sender);
        }
    }
}
