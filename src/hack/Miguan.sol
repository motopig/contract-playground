// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.28;

contract CN_bank {
    function Deposit(uint256 _unlockTime) public payable {
        Holder storage acc = Accounts[msg.sender];
        acc.balance += msg.value;
        acc.unlockTime = _unlockTime > block.timestamp ? _unlockTime : block.timestamp;
        LogFile.AddMessage(msg.sender, msg.value, "Put");
    }

    function Collect(uint256 _am) public payable {
        Holder storage acc = Accounts[msg.sender];
        if (acc.balance > MinSum && acc.balance >= _am && block.timestamp > acc.unlockTime) {
            (bool success,) = msg.sender.call{value: _am}("");
            if (success) {
                unchecked {
                    acc.balance -= _am; // 模拟 Solidity 0.7.6 无溢出检查
                }
                LogFile.AddMessage(msg.sender, _am, "Collect");
            }
        }
    }

    struct Holder {
        uint256 unlockTime;
        uint256 balance;
    }

    mapping(address => Holder) public Accounts;

    MiguanLog LogFile;

    uint256 public MinSum = 1 ether;

    constructor(address _log) {
        LogFile = MiguanLog(_log);
    }

    fallback() external payable {
        Deposit(0);
    }

    receive() external payable {
        Deposit(0);
    }
}

contract MiguanLog {
    event Message(address indexed Sender, string Data, uint256 Val, uint256 Time);

    function AddMessage(address _adr, uint256 _val, string memory _data) external {
        emit Message(_adr, _data, _val, block.timestamp);
    }
}
