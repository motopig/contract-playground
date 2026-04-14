// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BasePaymaster} from "@account-abstraction/contracts/core/BasePaymaster.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {UserOperationLib} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title VerifyingPaymaster
 * @notice 通过链下签名验证来决定是否为用户代付 gas 的 Paymaster
 * @dev 工作流程:
 *   1. 用户将 UserOp（不含 paymasterSignature 部分）提交给链下验证者（verifyingSigner）
 *   2. 验证者检查白名单/限额等条件，签名后返回给用户
 *   3. 用户将签名附加到 paymasterAndData 的 paymasterData 部分
 *   4. EntryPoint 调用 validatePaymasterUserOp 验证签名是否有效
 *
 * paymasterData 编码:
 *   [validUntil (48 bits) | validAfter (48 bits) | signature (动态长度)]
 */
contract VerifyingPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;

    address public verifyingSigner;

    /// @dev paymasterData 中前 12 字节为 validUntil + validAfter
    uint256 private constant VALID_TIMESTAMP_OFFSET = 0;
    uint256 private constant SIGNATURE_OFFSET = 12; // 6 bytes validUntil + 6 bytes validAfter

    event SignerChanged(address indexed oldSigner, address indexed newSigner);

    error InvalidSignatureLength();

    constructor(IEntryPoint _entryPoint, address _verifyingSigner, address _owner) BasePaymaster(_entryPoint, _owner) {
        verifyingSigner = _verifyingSigner;
    }

    /**
     * @notice 更新验证签名者
     * @param _newSigner 新的签名者地址
     */
    function setVerifyingSigner(address _newSigner) external onlyOwner {
        require(_newSigner != address(0), "invalid signer");
        address old = verifyingSigner;
        verifyingSigner = _newSigner;
        emit SignerChanged(old, _newSigner);
    }

    /**
     * @notice 获取需要被签名的哈希
     * @dev 此哈希由 verifyingSigner 在链下签名
     */
    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        public
        view
        returns (bytes32)
    {
        // 使用 userOp 字段（不含 paymasterAndData 中的签名部分）来生成哈希
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                block.chainid,
                address(this),
                validUntil,
                validAfter
            )
        );
    }

    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        /*userOpHash*/
        uint256 /*maxCost*/
    )
        internal
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        // 从 paymasterAndData 中提取 paymasterData（跳过前 52 字节：20 paymaster + 16 verificationGasLimit + 16 postOpGasLimit）
        bytes calldata paymasterData = userOp.paymasterAndData[UserOperationLib.PAYMASTER_DATA_OFFSET:];

        // 至少需要 12 字节时间戳 + 65 字节签名
        if (paymasterData.length < SIGNATURE_OFFSET + 65) {
            revert InvalidSignatureLength();
        }

        // 解析时间戳
        uint48 validUntil = uint48(bytes6(paymasterData[0:6]));
        uint48 validAfter = uint48(bytes6(paymasterData[6:12]));

        // 提取签名
        bytes calldata signature = paymasterData[SIGNATURE_OFFSET:];

        // 验证签名
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));
        address recovered = ECDSA.recover(hash, signature);

        if (recovered != verifyingSigner) {
            // 签名无效，返回 sigFailed = true
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        // 签名有效
        return ("", _packValidationData(false, validUntil, validAfter));
    }

    /**
     * @dev 此 Paymaster 不需要 postOp 处理
     */
    function _postOp(PostOpMode, bytes calldata, uint256, uint256) internal pure override {
        // 无操作
    }
}
