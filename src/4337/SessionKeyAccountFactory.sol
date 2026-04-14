// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {SessionKeyAccount} from "./SessionKeyAccount.sol";

/**
 * @title SessionKeyAccountFactory
 * @notice 使用 CREATE2 部署 SessionKeyAccount 代理的工厂合约
 */
contract SessionKeyAccountFactory {
    SessionKeyAccount public immutable accountImplementation;
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
        accountImplementation = new SessionKeyAccount(_entryPoint);
    }

    function createAccount(address owner, uint256 salt) public returns (SessionKeyAccount account) {
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return SessionKeyAccount(payable(addr));
        }
        account = SessionKeyAccount(
            payable(new ERC1967Proxy{salt: bytes32(salt)}(
                    address(accountImplementation), abi.encodeCall(SessionKeyAccount.initialize, (owner))
                ))
        );
    }

    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(address(accountImplementation), abi.encodeCall(SessionKeyAccount.initialize, (owner)))
                )
            )
        );
    }
}
