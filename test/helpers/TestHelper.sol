// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std-1.9.6/src/Test.sol";

import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction-0.9.0/contracts/core/EntryPoint.sol";

import {SimpleAccount} from "../../src/SimpleAccount.sol";
import {SimpleAccountFactory} from "../../src/SimpleAccountFactory.sol";
import {VerifyingPaymaster} from "../../src/VerifyingPaymaster.sol";

/**
 * @title TestHelper
 * @notice 所有测试的共享基类，提供:
 *   - EntryPoint、Factory、Paymaster 部署
 *   - 用户签名辅助函数
 *   - UserOp 构建辅助函数
 */
abstract contract TestHelper is Test {
    // ─── 核心合约 ─────────────────────────────────────────
    EntryPoint public entryPoint;
    SimpleAccountFactory public factory;
    SimpleAccount public account;
    VerifyingPaymaster public paymaster;

    // ─── 测试角色 ─────────────────────────────────────────
    address payable public beneficiary;
    address public bundler; // EOA bundler, 用于调用 handleOps
    uint256 public ownerKey;
    address public owner;
    uint256 public paymasterSignerKey;
    address public paymasterSigner;

    function setUp() public virtual {
        // 创建角色
        (owner, ownerKey) = makeAddrAndKey("owner");
        (paymasterSigner, paymasterSignerKey) = makeAddrAndKey("paymasterSigner");
        beneficiary = payable(makeAddr("beneficiary"));
        bundler = makeAddr("bundler");

        // 部署 EntryPoint
        entryPoint = new EntryPoint();

        // 部署 Factory
        factory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));

        // 部署账户 (salt = 0)
        account = factory.createAccount(owner, 0);

        // 给账户充值
        vm.deal(address(account), 10 ether);

        // 部署 Paymaster
        paymaster = new VerifyingPaymaster(
            IEntryPoint(address(entryPoint)),
            paymasterSigner,
            address(this) // test contract 作为 owner
        );

        // 给 Paymaster 充值 deposit
        paymaster.deposit{value: 5 ether}();

        // 为 Paymaster 添加 stake（某些 bundler 可能需要）
        paymaster.addStake{value: 1 ether}(86400);
    }

    // ─── UserOp 构建辅助 ──────────────────────────────────

    /**
     * @dev 构建一个基础的 PackedUserOperation
     */
    function _buildUserOp(address sender, uint256 nonce, bytes memory callData)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        return _buildUserOp(sender, nonce, callData, 200_000, 200_000);
    }

    /**
     * @dev 构建可配置 gas limit 的 PackedUserOperation
     */
    function _buildUserOp(
        address sender,
        uint256 nonce,
        bytes memory callData,
        uint128 verificationGasLimit,
        uint128 callGasLimit
    ) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: callData,
            accountGasLimits: _packAccountGasLimits(verificationGasLimit, callGasLimit),
            preVerificationGas: 50_000,
            gasFees: _packGasFees(1 gwei, 10 gwei),
            paymasterAndData: "",
            signature: ""
        });
    }

    /**
     * @dev 构建带 initCode 的 UserOp（用于账户首次部署）
     */
    function _buildUserOpWithInitCode(address expectedSender, address ownerAddr, uint256 salt, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeCall(SimpleAccountFactory.createAccount, (ownerAddr, salt)));

        return PackedUserOperation({
            sender: expectedSender,
            nonce: 0,
            initCode: initCode,
            callData: callData,
            accountGasLimits: _packAccountGasLimits(500_000, 200_000),
            preVerificationGas: 100_000,
            gasFees: _packGasFees(1 gwei, 10 gwei),
            paymasterAndData: "",
            signature: ""
        });
    }

    /**
     * @dev 为 UserOp 签名
     */
    function _signUserOp(PackedUserOperation memory userOp, uint256 signerKey) internal view returns (bytes memory) {
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils_toEthSignedMessageHash(userOpHash));
        return abi.encodePacked(r, s, v);
    }

    /**
     * @dev 为 UserOp 添加 Paymaster 数据和签名
     */
    function _addPaymasterData(
        PackedUserOperation memory userOp,
        uint48 validUntil,
        uint48 validAfter,
        uint256 signerKey
    ) internal view {
        // 先构建不含签名的 paymasterAndData 以计算 hash
        // paymasterAndData = paymaster(20) + verificationGasLimit(16) + postOpGasLimit(16) + paymasterData
        uint128 pmVerificationGasLimit = 100_000;
        uint128 pmPostOpGasLimit = 50_000;

        // 获取签名
        bytes32 hash = paymaster.getHash(userOp, validUntil, validAfter);
        bytes32 ethHash = MessageHashUtils_toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 组装 paymasterAndData
        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            pmVerificationGasLimit,
            pmPostOpGasLimit,
            bytes6(validUntil),
            bytes6(validAfter),
            signature
        );
    }

    // ─── 打包辅助 ─────────────────────────────────────────

    function _packAccountGasLimits(uint128 verificationGasLimit, uint128 callGasLimit) internal pure returns (bytes32) {
        return bytes32(uint256(verificationGasLimit) << 128 | uint256(callGasLimit));
    }

    function _packGasFees(uint128 maxPriorityFeePerGas, uint128 maxFeePerGas) internal pure returns (bytes32) {
        return bytes32(uint256(maxPriorityFeePerGas) << 128 | uint256(maxFeePerGas));
    }

    /**
     * @dev 手动实现 toEthSignedMessageHash 避免导入冲突
     */
    function MessageHashUtils_toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    // ─── 执行辅助 ─────────────────────────────────────────

    function _executeUserOp(PackedUserOperation memory userOp) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        // v0.9 EntryPoint 要求 tx.origin == msg.sender 且为 EOA
        // vm.prank(addr, addr) 同时设置 msg.sender 和 tx.origin
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }
}
