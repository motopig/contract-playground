# ERC-4337 交易调用流程

## 1. 基础交易流程（账户自付 Gas）

```mermaid
sequenceDiagram
    participant User as 用户 (EOA)
    participant Bundler as Bundler (EOA)
    participant EP as EntryPoint
    participant SA as SimpleAccount (Proxy)
    participant Target as 目标合约

    User->>Bundler: 1. 提交签名后的 UserOp
    Note over User,Bundler: UserOp 包含: sender, nonce,<br/>callData, signature 等

    Bundler->>EP: 2. handleOps([userOp], beneficiary)
    Note over Bundler,EP: tx.origin == msg.sender (EOA 要求)

    rect rgb(240, 248, 255)
        Note over EP: === 验证阶段 ===
        EP->>SA: 3. validateUserOp(userOp, userOpHash, missingFunds)
        SA->>SA: 4. _validateSignature() — ECDSA.recover 验证 owner 签名
        SA->>SA: 5. _payPrefund() — 向 EntryPoint 转入 missingFunds
        SA-->>EP: 6. 返回 validationData (0=成功, 1=失败)
    end

    rect rgb(255, 248, 240)
        Note over EP: === 执行阶段 ===
        EP->>SA: 7. 调用 userOp.callData (execute/executeBatch)
        SA->>SA: 8. _requireForExecute() — 验证 msg.sender == EntryPoint
        SA->>Target: 9. 低级调用 target.call{value}(data)
        Target-->>SA: 10. 返回结果
        SA-->>EP: 11. 执行完成
    end

    EP->>Bundler: 12. 将剩余 gas 退还 + 手续费付给 beneficiary
    Note over EP: 触发 UserOperationEvent
```

## 2. 带 Paymaster 的交易流程（Gas 代付）

```mermaid
sequenceDiagram
    participant User as 用户 (EOA)
    participant Bundler as Bundler (EOA)
    participant EP as EntryPoint
    participant SA as SimpleAccount
    participant PM as VerifyingPaymaster
    participant Target as 目标合约

    User->>PM: 0. (链下) 请求 Paymaster 签名
    PM-->>User: 0. 返回 paymasterSignature (validUntil, validAfter, sig)

    User->>Bundler: 1. 提交带 paymasterAndData 的 UserOp
    Note over User,Bundler: paymasterAndData =<br/>paymaster(20B) | pmVerificationGasLimit(16B)<br/>| pmPostOpGasLimit(16B) | validUntil(6B)<br/>| validAfter(6B) | signature(65B)

    Bundler->>EP: 2. handleOps([userOp], beneficiary)

    rect rgb(240, 248, 255)
        Note over EP: === 验证阶段 (Account) ===
        EP->>SA: 3. validateUserOp(userOp, userOpHash, 0)
        Note over SA: missingFunds=0 (Paymaster 代付)
        SA->>SA: 4. _validateSignature() — 验证 owner 签名
        SA-->>EP: 5. 返回 validationData
    end

    rect rgb(240, 255, 240)
        Note over EP: === 验证阶段 (Paymaster) ===
        EP->>PM: 6. validatePaymasterUserOp(userOp, userOpHash, maxCost)
        PM->>PM: 7. 解析 paymasterData: validUntil, validAfter, signature
        PM->>PM: 8. getHash() → ECDSA.recover 验证 verifyingSigner
        PM-->>EP: 9. 返回 (context, validationData)
        Note over EP: 从 Paymaster 的 deposit 中<br/>预扣 maxCost
    end

    rect rgb(255, 248, 240)
        Note over EP: === 执行阶段 ===
        EP->>SA: 10. 调用 userOp.callData
        SA->>Target: 11. execute(target, value, data)
        Target-->>SA: 12. 返回结果
        SA-->>EP: 13. 执行完成
    end

    rect rgb(255, 240, 255)
        Note over EP: === PostOp 阶段 ===
        EP->>PM: 14. postOp(mode, context, actualGasCost, feePerGas)
        Note over PM: (VerifyingPaymaster 无操作)
        PM-->>EP: 15. 完成
        Note over EP: 将多扣的 deposit 退还 Paymaster
    end

    EP->>Bundler: 16. 手续费付给 beneficiary
```

## 3. 首次部署账户的交易流程（含 initCode）

```mermaid
sequenceDiagram
    participant Bundler as Bundler (EOA)
    participant EP as EntryPoint
    participant SC as SenderCreator
    participant Factory as SimpleAccountFactory
    participant SA as SimpleAccount (新部署)

    Bundler->>EP: 1. handleOps([userOp], beneficiary)
    Note over EP: 检测到 sender 无代码且 initCode 非空

    rect rgb(245, 245, 255)
        Note over EP: === 部署阶段 ===
        EP->>SC: 2. createSender(initCode)
        Note over SC: initCode = factory(20B) || factoryCalldata
        SC->>Factory: 3. createAccount(owner, salt)
        Factory->>Factory: 4. Create2 部署 ERC1967Proxy
        Note over Factory: Proxy 指向 accountImplementation
        Factory->>SA: 5. initialize(owner) — 通过 Proxy
        SA-->>Factory: 6. 部署完成
        Factory-->>SC: 7. 返回账户地址
        SC-->>EP: 8. 返回部署的 sender 地址
        Note over EP: 验证返回地址 == userOp.sender
    end

    rect rgb(240, 248, 255)
        Note over EP: === 验证阶段 ===
        EP->>SA: 9. validateUserOp(...)
        SA-->>EP: 10. 验证通过
    end

    rect rgb(255, 248, 240)
        Note over EP: === 执行阶段 ===
        EP->>SA: 11. 执行 callData (如有)
        SA-->>EP: 12. 完成
    end
```

## 4. 合约架构关系

```mermaid
graph TB
    subgraph "链上核心"
        EP["EntryPoint<br/>(单例, 所有链共享地址)"]
        SC["SenderCreator<br/>(由 EntryPoint 创建)"]
    end

    subgraph "账户相关"
        Factory["SimpleAccountFactory<br/>• accountImplementation (immutable)<br/>• createAccount(owner, salt)<br/>• getAddress(owner, salt)"]
        Impl["SimpleAccount Implementation<br/>(逻辑合约, 不可直接使用)"]
        Proxy["ERC1967Proxy<br/>(用户的实际账户地址)"]
    end

    subgraph "Paymaster"
        PM["VerifyingPaymaster<br/>• verifyingSigner<br/>• getHash()<br/>• validatePaymasterUserOp()"]
    end

    EP -->|"handleOps"| Proxy
    EP -->|"validatePaymasterUserOp"| PM
    EP -->|"createSender"| SC
    SC -->|"createAccount"| Factory
    Factory -->|"new ERC1967Proxy{salt}"| Proxy
    Proxy -->|"delegatecall"| Impl
    PM -.->|"deposit/stake"| EP

    style EP fill:#f9f,stroke:#333,stroke-width:2px
    style Proxy fill:#bbf,stroke:#333,stroke-width:2px
    style PM fill:#bfb,stroke:#333,stroke-width:2px
```

## 5. 数据编码格式

```
┌─────────────────────────────────────────────────────────────────┐
│                     PackedUserOperation                         │
├──────────────────┬──────────────────────────────────────────────┤
│ sender           │ 账户合约地址 (20 bytes)                       │
│ nonce            │ uint192(key) || uint64(sequence)             │
│ initCode         │ factory(20B) || factoryCalldata (首次部署时)  │
│ callData         │ execute(target,value,data) 的 ABI 编码       │
│ accountGasLimits │ verificationGasLimit(16B) || callGasLimit(16B)│
│ preVerificationGas│ 预验证 gas                                  │
│ gasFees          │ maxPriorityFee(16B) || maxFeePerGas(16B)     │
│ paymasterAndData │ 见下方详细格式                                │
│ signature        │ owner 对 userOpHash 的 ECDSA 签名 (65B)      │
└──────────────────┴──────────────────────────────────────────────┘

paymasterAndData 编码:
┌────────────┬────────────────────┬───────────────┬──────────────────┐
│ paymaster  │ pmVerificationGas  │ pmPostOpGas   │ paymasterData    │
│ (20 bytes) │ (16 bytes)         │ (16 bytes)    │ (动态长度)        │
└────────────┴────────────────────┴───────────────┴──────────────────┘
                                                   │
                                    ┌──────────────┴──────────────┐
                                    │ validUntil(6B) |            │
                                    │ validAfter(6B) |            │
                                    │ signature(65B)              │
                                    └─────────────────────────────┘
```
