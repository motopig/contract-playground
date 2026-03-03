// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std-1.9.6/src/Test.sol";
import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";

import {SimpleAccount} from "../src/SimpleAccount.sol";
import {VerifyingPaymaster} from "../src/VerifyingPaymaster.sol";
import {TestHelper} from "./helpers/TestHelper.sol";
import {BaseAccount} from "account-abstraction-0.9.0/contracts/core/BaseAccount.sol";

contract VerifyingPaymasterTest is TestHelper {
    Counter public counter;

    function setUp() public override {
        super.setUp();
        counter = new Counter();
    }

    // ═══════════════════════════════════════════════════════
    //  基础属性
    // ═══════════════════════════════════════════════════════

    function test_verifyingSigner() public view {
        assertEq(paymaster.verifyingSigner(), paymasterSigner);
    }

    function test_entryPoint() public view {
        assertEq(address(paymaster.entryPoint()), address(entryPoint));
    }

    function test_deposit() public view {
        assertGe(paymaster.getDeposit(), 5 ether);
    }

    // ═══════════════════════════════════════════════════════
    //  Paymaster 赞助交易
    // ═══════════════════════════════════════════════════════

    function test_sponsoredTransaction() public {
        // 给账户很少的 ETH（不足以支付 gas），依靠 Paymaster 代付
        vm.deal(address(account), 0);

        PackedUserOperation memory userOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())))
        );

        // 添加 Paymaster 数据
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;
        _addPaymasterData(userOp, validUntil, validAfter, paymasterSignerKey);

        // 签名用户操作
        userOp.signature = _signUserOp(userOp, ownerKey);

        // 执行
        _executeUserOp(userOp);
        assertEq(counter.count(), 1);
    }

    function test_sponsoredTransaction_invalidPaymasterSig() public {
        vm.deal(address(account), 0);

        PackedUserOperation memory userOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())))
        );

        // 用错误的 key 签名 paymaster 数据
        (, uint256 wrongKey) = makeAddrAndKey("wrongPaymasterSigner");
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;
        _addPaymasterData(userOp, validUntil, validAfter, wrongKey);

        userOp.signature = _signUserOp(userOp, ownerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    // ═══════════════════════════════════════════════════════
    //  时间窗口验证
    // ═══════════════════════════════════════════════════════

    function test_sponsoredTransaction_expired() public {
        // 设置一个合理的时间戳（默认 block.timestamp=1，减1后为0会被视为"永不过期"）
        vm.warp(1_000_000);
        vm.deal(address(account), 0);

        PackedUserOperation memory userOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())))
        );

        // validUntil 已过期
        uint48 validUntil = uint48(block.timestamp - 100);
        uint48 validAfter = 0;
        _addPaymasterData(userOp, validUntil, validAfter, paymasterSignerKey);

        userOp.signature = _signUserOp(userOp, ownerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    function test_sponsoredTransaction_notYetValid() public {
        vm.deal(address(account), 0);

        PackedUserOperation memory userOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())))
        );

        // validAfter 尚未到达
        uint48 validUntil = uint48(block.timestamp + 2 hours);
        uint48 validAfter = uint48(block.timestamp + 1 hours);
        _addPaymasterData(userOp, validUntil, validAfter, paymasterSignerKey);

        userOp.signature = _signUserOp(userOp, ownerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    // ═══════════════════════════════════════════════════════
    //  Signer 管理
    // ═══════════════════════════════════════════════════════

    function test_setVerifyingSigner() public {
        address newSigner = makeAddr("newSigner");
        paymaster.setVerifyingSigner(newSigner);
        assertEq(paymaster.verifyingSigner(), newSigner);
    }

    function test_setVerifyingSigner_revertIfNotOwner() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert();
        paymaster.setVerifyingSigner(random);
    }

    // ═══════════════════════════════════════════════════════
    //  Deposit 和 Stake 管理
    // ═══════════════════════════════════════════════════════

    function test_withdrawTo() public {
        uint256 balBefore = beneficiary.balance;
        paymaster.withdrawTo(beneficiary, 1 ether);
        assertEq(beneficiary.balance, balBefore + 1 ether);
    }
}

// ─── 辅助合约 ──────────────────────────────────────────────

contract Counter {
    uint256 public count;

    function increment() external {
        count++;
    }
}
