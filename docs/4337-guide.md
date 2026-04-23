# ERC-4337 Account Abstraction Example

基于 Foundry + OpenZeppelin 的 ERC-4337 账户抽象示例项目。

## 概述

本项目实现了 ERC-4337 的核心组件：

- **SimpleAccount** - 支持 ERC-4337 的智能合约账户，基于 OpenZeppelin 的可升级实现
- **SimpleAccountFactory** - 使用 CREATE2 部署账户的工厂合约
- **VerifyingPaymaster** - 验证型 Paymaster，由链下签名者授权代付 gas

## 项目结构

```
├── src/
│   ├── SimpleAccount.sol        # 智能合约账户
│   ├── SimpleAccountFactory.sol # 账户工厂
│   └── VerifyingPaymaster.sol   # 验证型 Paymaster
├── test/
│   ├── SimpleAccount.t.sol      # 账户测试
│   ├── SimpleAccountFactory.t.sol # 工厂测试
│   ├── VerifyingPaymaster.t.sol # Paymaster 测试
│   └── helpers/
│       └── TestHelper.sol       # 测试辅助
├── script/
│   └── Deploy.s.sol             # 部署脚本
├── foundry.toml
└── README.md
```

## 安装

```bash
# 安装依赖
forge install OpenZeppelin/openzeppelin-contracts@v5.2.0 --no-commit
forge install eth-infinitism/account-abstraction@v0.7.0 --no-commit

# 编译
forge build

# 测试
forge test -vvv
```

## 部署

```bash
# 设置环境变量
cp .env.example .env
# 编辑 .env 文件

# 部署到 Sepolia
source .env
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

## 架构

### ERC-4337 流程

1. 用户构造 `UserOperation` 并签名
2. Bundler 将 `UserOperation` 提交到 `EntryPoint`
3. `EntryPoint` 调用账户的 `validateUserOp` 验证签名
4. （可选）`EntryPoint` 调用 Paymaster 的 `validatePaymasterUserOp` 验证代付
5. `EntryPoint` 执行用户操作

### 合约说明

- **SimpleAccount**: 实现 `IAccount` 接口，支持 ECDSA 签名验证、批量执行、ETH 接收
- **SimpleAccountFactory**: 使用 `CREATE2` + 代理模式部署账户，确保地址可预测
- **VerifyingPaymaster**: 通过链下签名验证来决定是否为用户代付 gas
