// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {SimpleAccount} from "./SimpleAccount.sol";

/**
 * @title SimpleAccountFactory
 * @notice 使用 CREATE2 部署 SimpleAccount 代理的工厂合约
 * @dev
 *   - 每个 (owner, salt) 组合对应唯一的确定性地址
 *   - 如果账户已部署，直接返回已有地址
 *   - 在 UserOp 的 initCode 中使用
 */
contract SimpleAccountFactory {
    SimpleAccount public immutable accountImplementation;
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
        accountImplementation = new SimpleAccount(_entryPoint);
    }

    /**
     * @notice 创建账户（如果尚未部署）
     * @param owner 账户 owner
     * @param salt 随机盐值
     * @return account 部署或已存在的账户地址
     */
    function createAccount(address owner, uint256 salt) public returns (SimpleAccount account) {
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return SimpleAccount(payable(addr));
        }
        account = SimpleAccount(
            payable(new ERC1967Proxy{salt: bytes32(salt)}(
                    address(accountImplementation), abi.encodeCall(SimpleAccount.initialize, (owner))
                ))
        );
    }

    /**
     * @notice 计算账户的 counterfactual 地址
     * @param owner 账户 owner
     * @param salt 随机盐值
     * @return 预计算的账户地址
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(address(accountImplementation), abi.encodeCall(SimpleAccount.initialize, (owner)))
                )
            )
        );
    }
}
