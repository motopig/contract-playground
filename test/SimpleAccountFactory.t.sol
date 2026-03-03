// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std-1.9.6/src/Test.sol";
import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";

import {SimpleAccount} from "../src/SimpleAccount.sol";
import {SimpleAccountFactory} from "../src/SimpleAccountFactory.sol";
import {TestHelper} from "./helpers/TestHelper.sol";

contract SimpleAccountFactoryTest is TestHelper {
    // ═══════════════════════════════════════════════════════
    //  工厂基本功能
    // ═══════════════════════════════════════════════════════

    function test_createAccount() public {
        address newOwner = makeAddr("newOwner");
        SimpleAccount newAccount = factory.createAccount(newOwner, 1);
        assertEq(newAccount.owner(), newOwner);
        assertEq(address(newAccount.entryPoint()), address(entryPoint));
    }

    function test_createAccount_deterministicAddress() public {
        address newOwner = makeAddr("newOwner");
        uint256 salt = 42;

        // 计算预期地址
        address predicted = factory.getAddress(newOwner, salt);

        // 创建账户
        SimpleAccount created = factory.createAccount(newOwner, salt);

        assertEq(address(created), predicted);
    }

    function test_createAccount_returnExistingIfDeployed() public {
        address newOwner = makeAddr("newOwner");
        uint256 salt = 10;

        SimpleAccount first = factory.createAccount(newOwner, salt);
        SimpleAccount second = factory.createAccount(newOwner, salt);

        assertEq(address(first), address(second));
    }

    function test_createAccount_differentSaltDifferentAddress() public {
        SimpleAccount a1 = factory.createAccount(owner, 0);
        SimpleAccount a2 = factory.createAccount(owner, 1);

        assertTrue(address(a1) != address(a2));
    }

    function test_createAccount_differentOwnerDifferentAddress() public {
        address owner2 = makeAddr("owner2");
        SimpleAccount a1 = factory.createAccount(owner, 0);
        SimpleAccount a2 = factory.createAccount(owner2, 0);

        assertTrue(address(a1) != address(a2));
    }

    // ═══════════════════════════════════════════════════════
    //  通过 initCode 部署账户
    // ═══════════════════════════════════════════════════════

    function test_deployViaEntryPoint() public {
        address newOwner = makeAddr("deployOwner");
        uint256 salt = 99;
        address expectedAddr = factory.getAddress(newOwner, salt);
        (address newOwnerAddr, uint256 newOwnerKey) = makeAddrAndKey("deployOwner");

        // 给预期地址充值（用来支付 gas）
        vm.deal(expectedAddr, 5 ether);

        // 构建带 initCode 的 UserOp
        PackedUserOperation memory userOp = _buildUserOpWithInitCode(
            expectedAddr,
            newOwnerAddr,
            salt,
            "" // 空 callData，仅部署
        );

        // 签名
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newOwnerKey, MessageHashUtils_toEthSignedMessageHash(userOpHash));
        userOp.signature = abi.encodePacked(r, s, v);

        // 执行
        _executeUserOp(userOp);

        // 验证账户已部署
        assertTrue(expectedAddr.code.length > 0);
        SimpleAccount deployed = SimpleAccount(payable(expectedAddr));
        assertEq(deployed.owner(), newOwnerAddr);
    }
}
