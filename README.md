# Contract Playground

一个基于 Foundry 的智能合约实验仓库，覆盖多个常见方向：

- ERC-4337 账户抽象（账户、工厂、Paymaster、Aave 集成测试）
- EIP-1167 最小代理（经典版与 PUSH0 版）
- ERC-1271 合约签名验证（单签、多签、EIP-712 typed data）
- EIP-7702 相关实验（Gas sponsorship、SBT）
- EIP-8004 Agent 注册/信誉/验证注册表示例
- AccessManager RBAC 集成示例
- ERC20 时间加权增长代币示例
- LayerZero LZMultiCall 相关实现

仓库更偏向“学习 + 验证 + 原型”，适合按模块阅读源码和测试来理解设计。

## 技术栈

- Solidity `0.8.28`（部分模块使用 `0.8.24/0.8.20/0.8.19`）
- Foundry (forge/cast/anvil)
- OpenZeppelin Contracts `5.6.1`
- eth-infinitism account-abstraction `0.9.0`

编译配置见 `foundry.toml`：

- `evm_version = "cancun"`
- `optimizer = true`, `optimizer_runs = 200`
- `libs = ["dependencies"]`

## 快速开始

### 1) 环境要求

- 已安装 Foundry
- macOS/Linux shell/WSL（以下命令默认 zsh/bash）

### 2) 安装依赖

本仓库已包含 `dependencies/`，通常可直接编译测试。

如果你需要重新安装/更新依赖：

```bash
forge soldeer install
```

### 3) 编译

```bash
forge build
```

### 4) 运行测试

运行全部测试：

```bash
forge test -vv
```

按模块运行：

```bash
forge test --match-path "test/4337/*" -vv
forge test --match-path "test/1167/*" -vv
forge test --match-path "test/1271/*" -vv
forge test --match-path "test/7702/*" -vv
forge test --match-path "test/8004/*" -vv
forge test --match-path "test/LZMultiCall/*" -vv
forge test --match-path "test/rbac/*" -vv
forge test --match-path "test/token/*" -vv
```

Fork 测试（例如 Aave 集成）：

```bash
# 先在 .env 中配置 MAINNET_RPC_URL，再运行
forge test --match-contract AaveIntegrationTest --fork-url mainnet -vvv
```

## 模块导览

### ERC-4337 (`src/4337/`)

- `SimpleAccount.sol`
	- 基于 `BaseAccount` 的最小 4337 账户
	- 支持 owner 签名校验、execute/executeBatch、EntryPoint deposit 管理
	- 使用 UUPS + Initializable 模式
- `SimpleAccountFactory.sol`
	- 使用 CREATE2 + ERC1967Proxy 部署账户
	- 提供确定性地址预测 `getAddress`
- `VerifyingPaymaster.sol`
	- 使用链下签名白名单逻辑赞助 gas
	- 支持 `validUntil/validAfter` 时间窗

配套测试：`test/4337/`（含 `TestHelper` 与 Aave 主网 fork 集成）

### EIP-1167 (`src/1167/`)

- `MinimalProxy.sol`：经典 EIP-1167 最小代理实现
- `Clone0Factory.sol`：PUSH0 版本最小代理工厂（更现代字节码）

配套测试：`test/1167/`

### ERC-1271 (`src/1271/`)

- `ERC1271SingleOwner.sol`：单签 owner 校验
- `ERC1271MultiSig.sol`：M-of-N 多签阈值校验
- `ERC1271TypedData.sol`：EIP-712 typed data 场景签名校验

配套测试：`test/1271/`

### EIP-7702 实验 (`src/7702/`)

- `GasDaddy.sol`：通用调用转发与 gas sponsorship 实验合约
- `SimpleSBT.sol`：不可转移 SBT 示例

配套测试：`test/7702/`

### EIP-8004 示例 (`src/8004/`)

- `IdentityRegistry.sol`：Agent 身份注册与元数据
- `ReputationRegistry.sol`：反馈/评分与汇总
- `ValidationRegistry.sol`：验证请求与结果生命周期

配套测试：`test/8004/`（含 examples 与 integration）

### LayerZero MultiCall (`src/LZMultiCall/`)

- `LZMultiCall.sol`：多调用执行、签名授权、nonce 防重放
- `TransferDelegate.sol`：受控 ERC20 代理转账

配套测试：`test/LZMultiCall/`

### RBAC 示例 (`src/rbac/`)

- `MyContract.sol`：基于 OpenZeppelin `AccessManager/AccessManaged` 的角色化权限示例

配套测试：`test/rbac/`

### Token 示例 (`src/token/`)

- `TimeWeightedGrowthToken.sol`
	- 时间加权收益模型
	- 自动累计/领取收益
	- 可配置收益率与权重区间

配套测试：`test/token/`

### 其他

- `src/hack/`：攻击/对抗学习示例

## 部署脚本

仓库提供 4337 示例部署脚本：`script/Deploy.s.sol`

⚠️ 部署前建议：

- 优先在测试网（如 Sepolia）完成验证后再考虑主网
- 不要在命令行直接输入真实私钥（会进入 shell history）
- 推荐使用 `.env` 或 Foundry keystore 管理密钥

常见用法：

```bash
# 先 source .env（其中包含 PRIVATE_KEY）
# 本地链部署（自动处理 EntryPoint）
forge script script/Deploy.s.sol \
	--rpc-url http://127.0.0.1:8545 \
	--broadcast
```

使用 Foundry keystore（推荐）：

```bash
forge script script/Deploy.s.sol \
	--rpc-url sepolia \
	--account <your_keystore_account> \
	--broadcast
```

可选环境变量：

- `PRIVATE_KEY`：部署者私钥（必填）
- `ENTRYPOINT_ADDRESS`：EntryPoint 地址（不填时脚本自动检测/部署）
- `PAYMASTER_SIGNER`：Paymaster 签名者地址（可选，默认使用部署者地址）
- `MAINNET_RPC_URL` / `SEPOLIA_RPC_URL`：RPC（见 `foundry.toml`）
- `ETHERSCAN_API_KEY`：链上验证

## 文档

`docs/` 目录已包含若干专题：

- `4337-guide.md`：4337 模块快速导读
- `4337-call-flow.md`：调用流程
- `角色说明.md`：Bundler / EntryPoint / Paymaster 角色解释
- `evm-opcodes-guide.md`：EVM 指令相关内容
- `x402-protocol-explained.md`：协议说明文档

## 建议阅读顺序

如果你第一次进入仓库，建议按以下顺序：

1. `src/1167/` + `test/1167/`（理解最小代理）
2. `src/1271/` + `test/1271/`（理解合约签名验证）
3. `src/4337/` + `docs/4337-guide.md` + `test/4337/`
4. `src/8004/` + `test/8004/`
5. `src/LZMultiCall/` + `test/LZMultiCall/`

## 安全提示

- 本仓库代码来自网络主要用于学习与实验，不构成生产环境审计结论。
- 真实部署前请补充威胁建模、安全审计与上线前演练。
- 请勿在测试环境之外使用明文私钥。
