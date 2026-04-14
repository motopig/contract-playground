// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std-1.15.0/src/Script.sol";

import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {EntryPoint} from "account-abstraction-0.9.0/contracts/core/EntryPoint.sol";

import {SimpleAccount} from "../src/4337/SimpleAccount.sol";
import {SimpleAccountFactory} from "../src/4337/SimpleAccountFactory.sol";
import {VerifyingPaymaster} from "../src/4337/VerifyingPaymaster.sol";

/**
 * @title Deploy
 * @notice 部署 ERC-4337 示例合约的脚本
 *
 * 用法:
 *   # 本地测试（自动部署 EntryPoint）
 *   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 *
 * 环境变量:
 *   PRIVATE_KEY         - 部署者私钥
 *   ENTRYPOINT_ADDRESS  - EntryPoint 地址（可选，为空则自动部署）
 *   PAYMASTER_SIGNER    - Paymaster 验证签名者地址
 */
contract DeployScript is Script {
    // EntryPoint v0.9 的官方地址
    address constant CANONICAL_ENTRYPOINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);

        // 1. 确定 EntryPoint 地址
        address entryPointAddr = vm.envOr("ENTRYPOINT_ADDRESS", address(0));
        IEntryPoint entryPoint;

        vm.startBroadcast(deployerKey);

        if (entryPointAddr == address(0)) {
            // 检查规范地址是否已部署
            if (CANONICAL_ENTRYPOINT.code.length > 0) {
                entryPoint = IEntryPoint(CANONICAL_ENTRYPOINT);
                console2.log("Using canonical EntryPoint:", CANONICAL_ENTRYPOINT);
            } else {
                // 本地开发链或未部署的链 - 自行部署
                EntryPoint ep = new EntryPoint();
                entryPoint = IEntryPoint(address(ep));
                console2.log("Deployed EntryPoint:", address(ep));
            }
        } else {
            entryPoint = IEntryPoint(entryPointAddr);
            console2.log("Using EntryPoint:", entryPointAddr);
        }

        // 2. 部署 SimpleAccountFactory
        SimpleAccountFactory factory = new SimpleAccountFactory(entryPoint);
        console2.log("SimpleAccountFactory:", address(factory));
        console2.log("  -> accountImplementation:", address(factory.accountImplementation()));

        // 3. 部署 VerifyingPaymaster
        address paymasterSigner = vm.envOr("PAYMASTER_SIGNER", deployer);
        VerifyingPaymaster paymaster = new VerifyingPaymaster(
            entryPoint,
            paymasterSigner,
            deployer // owner
        );
        console2.log("VerifyingPaymaster:", address(paymaster));
        console2.log("  -> verifyingSigner:", paymasterSigner);

        // 4.（可选）为 Paymaster 充值 deposit
        if (address(deployer).balance > 0.1 ether) {
            paymaster.deposit{value: 0.05 ether}();
            console2.log("  -> deposited 0.05 ETH to paymaster");
        }

        vm.stopBroadcast();

        // 输出汇总
        console2.log("========================================");
        console2.log("Deployment Summary:");
        console2.log("  EntryPoint:     ", address(entryPoint));
        console2.log("  Factory:        ", address(factory));
        console2.log("  Paymaster:      ", address(paymaster));
        console2.log("========================================");
    }
}
