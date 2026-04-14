// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std-1.15.0/src/Test.sol";
import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";

import {SimpleAccount} from "../../src/4337/SimpleAccount.sol";
import {SimpleAccountFactory} from "../../src/4337/SimpleAccountFactory.sol";
import {TestHelper} from "./helpers/TestHelper.sol";
import {BaseAccount} from "account-abstraction-0.9.0/contracts/core/BaseAccount.sol";

contract SimpleAccountTest is TestHelper {
    // ─── 用于测试的 target 合约 ───────────────────────────
    Counter public counter;

    function setUp() public override {
        super.setUp();
        counter = new Counter();
    }

    // ═══════════════════════════════════════════════════════
    //  基础属性测试
    // ═══════════════════════════════════════════════════════

    function test_owner() public view {
        assertEq(account.owner(), owner);
    }

    function test_entryPoint() public view {
        assertEq(address(account.entryPoint()), address(entryPoint));
    }

    function test_receiveETH() public {
        uint256 before = address(account).balance;
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(account).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(account).balance, before + 1 ether);
    }

    // ═══════════════════════════════════════════════════════
    //  Owner 直接调用 execute
    // ═══════════════════════════════════════════════════════

    function test_execute_byOwner() public {
        vm.prank(owner);
        account.execute(address(counter), 0, abi.encodeCall(Counter.increment, ()));
        assertEq(counter.count(), 1);
    }

    function test_execute_revertIfNotOwnerOrEntryPoint() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert();
        account.execute(address(counter), 0, abi.encodeCall(Counter.increment, ()));
    }

    // ═══════════════════════════════════════════════════════
    //  批量执行
    // ═══════════════════════════════════════════════════════

    function test_executeBatch_byOwner() public {
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] =
                BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});
        }

        vm.prank(owner);
        account.executeBatch(calls);
        assertEq(counter.count(), 3);
    }

    // ═══════════════════════════════════════════════════════
    //  通过 EntryPoint 执行 UserOp
    // ═══════════════════════════════════════════════════════

    function test_validateUserOp_validSignature() public {
        // 构建 userOp
        PackedUserOperation memory userOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())))
        );

        // 签名
        userOp.signature = _signUserOp(userOp, ownerKey);

        // 通过 EntryPoint 执行
        _executeUserOp(userOp);
        assertEq(counter.count(), 1);
    }

    function test_validateUserOp_invalidSignature() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrong");

        PackedUserOperation memory userOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())))
        );

        userOp.signature = _signUserOp(userOp, wrongKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert();
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    // ═══════════════════════════════════════════════════════
    //  ETH 转账
    // ═══════════════════════════════════════════════════════

    function test_executeETHTransfer() public {
        address recipient = makeAddr("recipient");
        uint256 sendAmount = 1 ether;

        PackedUserOperation memory userOp = _buildUserOp(
            address(account), account.getNonce(), abi.encodeCall(BaseAccount.execute, (recipient, sendAmount, ""))
        );
        userOp.signature = _signUserOp(userOp, ownerKey);

        _executeUserOp(userOp);
        assertEq(recipient.balance, sendAmount);
    }

    // ═══════════════════════════════════════════════════════
    //  Ownership 管理
    // ═══════════════════════════════════════════════════════

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        account.transferOwnership(newOwner);
        assertEq(account.owner(), newOwner);
    }

    function test_transferOwnership_revertIfNotOwner() public {
        address newOwner = makeAddr("newOwner");
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert();
        account.transferOwnership(newOwner);
    }

    // ═══════════════════════════════════════════════════════
    //  Deposit 管理
    // ═══════════════════════════════════════════════════════

    function test_addDeposit() public {
        uint256 depositBefore = account.getDeposit();
        // addDeposit 是 payable，任何人都可以调用；用 owner 调用需给 owner 充值
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        account.addDeposit{value: 1 ether}();
        assertEq(account.getDeposit(), depositBefore + 1 ether);
    }

    function test_withdrawDeposit() public {
        // 先存入
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        account.addDeposit{value: 1 ether}();

        uint256 balBefore = owner.balance;
        vm.prank(owner);
        account.withdrawDepositTo(payable(owner), 0.5 ether);
        assertEq(owner.balance, balBefore + 0.5 ether);
    }
}

// ─── 用于测试的辅助合约 ────────────────────────────────────

contract Counter {
    uint256 public count;

    function increment() external {
        count++;
    }

    function setCount(uint256 _count) external {
        count = _count;
    }
}
