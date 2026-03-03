// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std-1.9.6/src/Test.sol";

import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {IAccountExecute} from "account-abstraction-0.9.0/contracts/interfaces/IAccountExecute.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction-0.9.0/contracts/core/EntryPoint.sol";
import {BaseAccount} from "account-abstraction-0.9.0/contracts/core/BaseAccount.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {SessionKeyAccount} from "../src/SessionKeyAccount.sol";
import {SessionKeyAccountFactory} from "../src/SessionKeyAccountFactory.sol";

// ─── 辅助合约 ─────────────────────────────────────────────

contract Counter {
    uint256 public count;

    function increment() external {
        count++;
    }

    function add(uint256 n) external {
        count += n;
    }
}

/// @dev 一个简单的 ETH 接收合约，用于测试 value 调用
contract Vault {
    receive() external payable {}

    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}

// ═══════════════════════════════════════════════════════════
//  SessionKeyAccount 测试
// ═══════════════════════════════════════════════════════════

contract SessionKeyAccountTest is Test {
    // ─── 核心合约 ─────────────────────────────────────────
    EntryPoint public entryPoint;
    SessionKeyAccountFactory public factory;
    SessionKeyAccount public account;

    // ─── 测试角色 ─────────────────────────────────────────
    address payable public beneficiary;
    address public bundler;
    uint256 public ownerKey;
    address public owner;
    uint256 public sessionKeyPrivKey;
    address public sessionKeyAddr;

    // ─── 测试目标合约 ─────────────────────────────────────
    Counter public counter;
    Vault public vault;

    // ─── 常量 ─────────────────────────────────────────────
    uint8 constant SIG_TYPE_OWNER = 0x00;
    uint8 constant SIG_TYPE_SESSION_KEY = 0x01;

    function setUp() public {
        // 避免 block.timestamp == 1 导致的边界问题
        vm.warp(1_000_000);

        // 创建角色
        (owner, ownerKey) = makeAddrAndKey("owner");
        (sessionKeyAddr, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");
        beneficiary = payable(makeAddr("beneficiary"));
        bundler = makeAddr("bundler");

        // 部署核心合约
        entryPoint = new EntryPoint();
        factory = new SessionKeyAccountFactory(IEntryPoint(address(entryPoint)));
        account = factory.createAccount(owner, 0);

        // 给账户充值
        vm.deal(address(account), 10 ether);
        vm.deal(owner, 10 ether);

        // 部署测试目标合约
        counter = new Counter();
        vault = new Vault();

        // 注册 session key: 允许调用 counter，最大值 0.1 ether，无时间限制
        address[] memory targets = new address[](1);
        targets[0] = address(counter);
        vm.prank(owner);
        account.addSessionKey(sessionKeyAddr, targets, 0.1 ether, 0, 0);
    }

    // ═══════════════════════════════════════════════════════
    //  Owner 基础操作
    // ═══════════════════════════════════════════════════════

    function test_ownerDirectExecute() public {
        // Owner 直接调用 execute（不经过 EntryPoint）
        vm.prank(owner);
        account.execute(address(counter), 0, abi.encodeCall(Counter.increment, ()));
        assertEq(counter.count(), 1);
    }

    function test_ownerDirectExecuteBatch() public {
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] =
                BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});
        }
        vm.prank(owner);
        account.executeBatch(calls);
        assertEq(counter.count(), 3);
    }

    function test_ownerViaUserOp_regularExecute() public {
        // Owner 通过 UserOp 使用普通 execute（EntryPoint 路径 B）
        bytes memory callData =
            abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())));
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsOwner(userOp);

        _executeUserOp(userOp);
        assertEq(counter.count(), 1);
    }

    function test_ownerViaUserOp_executeUserOp() public {
        // Owner 通过 UserOp 使用 executeUserOp（EntryPoint 路径 A）
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});
        calls[1] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.add, (10))});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsOwner(userOp);

        _executeUserOp(userOp);
        assertEq(counter.count(), 11); // 1 + 10
    }

    // ═══════════════════════════════════════════════════════
    //  Session Key 正常操作
    // ═══════════════════════════════════════════════════════

    function test_sessionKey_allowedAction() public {
        // Session Key 通过 executeUserOp 调用允许的目标
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsSessionKey(userOp);

        _executeUserOp(userOp);
        assertEq(counter.count(), 1);
    }

    function test_sessionKey_batchAllowedActions() public {
        // Session Key 批量调用允许的目标
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] =
                BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});
        }

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsSessionKey(userOp);

        _executeUserOp(userOp);
        assertEq(counter.count(), 3);
    }

    function test_sessionKey_withAllowedValue() public {
        // Session Key 发送允许范围内的 ETH
        // 先把 vault 加入 session key 的允许目标
        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        vm.prank(owner);
        account.addSessionKey(sessionKeyAddr, targets, 0.1 ether, 0, 0);

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(vault), value: 0.05 ether, data: ""});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsSessionKey(userOp);

        _executeUserOp(userOp);
        assertEq(vault.balance(), 0.05 ether);
    }

    // ═══════════════════════════════════════════════════════
    //  Session Key 权限拒绝
    // ═══════════════════════════════════════════════════════

    function test_sessionKey_revert_unauthorizedTarget() public {
        // Session Key 尝试调用未授权的目标 → 执行阶段 revert
        // 注意: handleOps 不会整体 revert，它会捕获执行失败并 emit UserOperationRevertReason
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(vault), value: 0, data: ""});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsSessionKey(userOp);

        // 记录 vault 初始余额
        uint256 vaultBefore = vault.balance();

        // handleOps 成功，但 UserOp 执行失败（success=false in UserOperationEvent）
        _executeUserOp(userOp);

        // 验证 vault 没有收到 ETH（操作没有生效）
        assertEq(vault.balance(), vaultBefore, "vault balance should not change");
    }

    function test_sessionKey_revert_valueExceeded() public {
        // Session Key 发送超过限额的 ETH
        // 先把 vault 加入允许目标
        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        vm.prank(owner);
        account.addSessionKey(sessionKeyAddr, targets, 0.1 ether, 0, 0);

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(vault), value: 0.5 ether, data: ""}); // 超过 0.1 ether 限额

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsSessionKey(userOp);

        // 记录初始状态
        uint256 vaultBefore = vault.balance();

        // handleOps 成功，但 UserOp 执行失败
        _executeUserOp(userOp);

        // 验证 vault 没有收到 ETH
        assertEq(vault.balance(), vaultBefore, "vault should not receive ETH");
    }

    function test_sessionKey_revert_revokedKey() public {
        // 撤销 Session Key 后操作失败
        address[] memory targets = new address[](1);
        targets[0] = address(counter);
        vm.prank(owner);
        account.revokeSessionKey(sessionKeyAddr, targets);

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);
        userOp.signature = _signAsSessionKey(userOp);

        // 验签阶段失败（session key not enabled）
        vm.prank(bundler, bundler);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_sessionKey_revert_invalidSigner() public {
        // 使用错误的私钥签名
        (, uint256 wrongKey) = makeAddrAndKey("wrongKey");

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);

        // 用 wrongKey 签名但声称是 sessionKeyAddr
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = _toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethHash);
        userOp.signature = abi.encodePacked(SIG_TYPE_SESSION_KEY, sessionKeyAddr, r, s, v);

        vm.prank(bundler, bundler);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    // ═══════════════════════════════════════════════════════
    //  Session Key 时间范围
    // ═══════════════════════════════════════════════════════

    function test_sessionKey_revert_expired() public {
        // 创建一个已过期的 session key
        (, uint256 expiredKeyPriv) = makeAddrAndKey("expiredKey");
        address expiredKeyAddr = vm.addr(expiredKeyPriv);

        address[] memory targets = new address[](1);
        targets[0] = address(counter);
        vm.prank(owner);
        // validUntil = block.timestamp - 100 (已过期)
        account.addSessionKey(
            expiredKeyAddr,
            targets,
            0.1 ether,
            0, // validAfter
            uint48(block.timestamp - 100) // validUntil — 已过期
        );

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);

        // 用该过期 key 签名
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = _toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(expiredKeyPriv, ethHash);
        userOp.signature = abi.encodePacked(SIG_TYPE_SESSION_KEY, expiredKeyAddr, r, s, v);

        vm.prank(bundler, bundler);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_sessionKey_revert_notYetValid() public {
        // 创建一个尚未生效的 session key
        (, uint256 futureKeyPriv) = makeAddrAndKey("futureKey");
        address futureKeyAddr = vm.addr(futureKeyPriv);

        address[] memory targets = new address[](1);
        targets[0] = address(counter);
        vm.prank(owner);
        // validAfter = block.timestamp + 1000 (尚未生效)
        account.addSessionKey(
            futureKeyAddr,
            targets,
            0.1 ether,
            uint48(block.timestamp + 1000), // validAfter — 未来
            0 // validUntil — 永不过期
        );

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = _toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(futureKeyPriv, ethHash);
        userOp.signature = abi.encodePacked(SIG_TYPE_SESSION_KEY, futureKeyAddr, r, s, v);

        vm.prank(bundler, bundler);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert();
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_sessionKey_validTimeRange() public {
        // 创建一个有时间范围的 session key，时间在范围内
        (, uint256 timedKeyPriv) = makeAddrAndKey("timedKey");
        address timedKeyAddr = vm.addr(timedKeyPriv);

        address[] memory targets = new address[](1);
        targets[0] = address(counter);
        vm.prank(owner);
        account.addSessionKey(
            timedKeyAddr,
            targets,
            0.1 ether,
            uint48(block.timestamp - 100), // validAfter — 已生效
            uint48(block.timestamp + 1000) // validUntil — 未过期
        );

        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});

        bytes memory callData = _encodeExecuteUserOpCallData(calls);
        PackedUserOperation memory userOp = _buildUserOp(address(account), 0, callData);

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = _toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(timedKeyPriv, ethHash);
        userOp.signature = abi.encodePacked(SIG_TYPE_SESSION_KEY, timedKeyAddr, r, s, v);

        _executeUserOp(userOp);
        assertEq(counter.count(), 1);
    }

    // ═══════════════════════════════════════════════════════
    //  Session Key 管理
    // ═══════════════════════════════════════════════════════

    function test_addSessionKey() public {
        (, uint256 newKeyPriv) = makeAddrAndKey("newKey");
        address newKeyAddr = vm.addr(newKeyPriv);

        address[] memory targets = new address[](2);
        targets[0] = address(counter);
        targets[1] = address(vault);

        vm.prank(owner);
        account.addSessionKey(newKeyAddr, targets, 1 ether, 100, 200);

        (bool enabled, uint48 validAfter, uint48 validUntil, uint256 maxVal) = account.sessionKeys(newKeyAddr);
        assertTrue(enabled);
        assertEq(validAfter, 100);
        assertEq(validUntil, 200);
        assertEq(maxVal, 1 ether);
        assertTrue(account.allowedTargets(newKeyAddr, address(counter)));
        assertTrue(account.allowedTargets(newKeyAddr, address(vault)));
    }

    function test_revokeSessionKey() public {
        address[] memory targets = new address[](1);
        targets[0] = address(counter);

        vm.prank(owner);
        account.revokeSessionKey(sessionKeyAddr, targets);

        (bool enabled,,,) = account.sessionKeys(sessionKeyAddr);
        assertFalse(enabled);
        assertFalse(account.allowedTargets(sessionKeyAddr, address(counter)));
    }

    function test_revert_nonOwnerAddSessionKey() public {
        address random = makeAddr("random");
        address[] memory targets = new address[](1);
        targets[0] = address(counter);

        vm.prank(random);
        vm.expectRevert();
        account.addSessionKey(random, targets, 1 ether, 0, 0);
    }

    // ═══════════════════════════════════════════════════════
    //  辅助函数
    // ═══════════════════════════════════════════════════════

    function _buildUserOp(address sender, uint256 nonce, bytes memory callData)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: callData,
            accountGasLimits: _packAccountGasLimits(300_000, 500_000),
            preVerificationGas: 50_000,
            gasFees: _packGasFees(1 gwei, 10 gwei),
            paymasterAndData: "",
            signature: ""
        });
    }

    /**
     * @dev 将 Call[] 编码为 executeUserOp 格式的 callData
     *   selector(4 bytes) + abi.encode(Call[])
     */
    function _encodeExecuteUserOpCallData(BaseAccount.Call[] memory calls) internal pure returns (bytes memory) {
        return abi.encodePacked(IAccountExecute.executeUserOp.selector, abi.encode(calls));
    }

    function _signAsOwner(PackedUserOperation memory userOp) internal view returns (bytes memory) {
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = _toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ethHash);
        return abi.encodePacked(SIG_TYPE_OWNER, r, s, v);
    }

    function _signAsSessionKey(PackedUserOperation memory userOp) internal view returns (bytes memory) {
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 ethHash = _toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPrivKey, ethHash);
        return abi.encodePacked(SIG_TYPE_SESSION_KEY, sessionKeyAddr, r, s, v);
    }

    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function _executeUserOp(PackedUserOperation memory userOp) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    function _packAccountGasLimits(uint128 verificationGasLimit, uint128 callGasLimit) internal pure returns (bytes32) {
        return bytes32(uint256(verificationGasLimit) << 128 | uint256(callGasLimit));
    }

    function _packGasFees(uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) internal pure returns (bytes32) {
        return bytes32(uint256(maxPriorityFeePerGas) << 128 | uint256(maxFeePerGas));
    }
}
