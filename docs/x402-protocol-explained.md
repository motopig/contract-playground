# x402 协议深度解析

> **协议全称**: x402 – An Open Payment Standard for the Internet  
> **发起方**: Coinbase (开源，Apache 2.0 许可)  
> **仓库**: [github.com/coinbase/x402](https://github.com/coinbase/x402)  
> **官网**: [x402.org](https://www.x402.org/)  
> **文档**: [docs.x402.org](https://docs.x402.org/)

---

## 1. 来龙去脉：为什么需要 x402？

### 1.1 互联网支付的原罪

HTTP 协议在 1997 年的 RFC 2068 中就保留了状态码 `402 Payment Required`，原意是"为将来的数字支付预留"。但近 30 年来，这个状态码从未被正式激活。互联网发展出了一套以**信用卡 + 广告 + 订阅**为核心的变现模型，带来了以下问题：

| 问题             | 现状                                                  |
| ---------------- | ----------------------------------------------------- |
| **高摩擦**       | 注册账号 → KYC → 绑定信用卡 → 购买额度 → 管理 API Key |
| **高手续费**     | 信用卡 2.9%+0.30 美元，微支付不经济                   |
| **最低消费门槛** | 无法实现 $0.001 级别的逐次付费                        |
| **不适合机器**   | AI Agent 无法自主开户、绑卡、管理订阅                 |
| **中心化依赖**   | 依赖 Stripe/PayPal 等中间商，有地域和审查限制         |

### 1.2 x402 的诞生

Coinbase 于 2025 年开源了 x402 协议，核心理念是：

> **让支付像 HTTP 请求一样简单——Client 发请求，Server 返回 402，Client 付款后重试，Server 交付资源。**

x402 激活了沉睡 30 年的 `HTTP 402` 状态码，首次让"按请求付费"成为互联网的原生能力。

---

## 2. 核心概念

### 2.1 四个角色

```
┌──────────┐     HTTP Request     ┌──────────────┐     /verify & /settle     ┌──────────────┐
│          │ ──────────────────→  │              │ ────────────────────────→ │              │
│  Client  │                      │   Resource   │                           │  Facilitator │
│ (Buyer)  │ ←────────────────── │    Server    │ ←──────────────────────── │   (Server)   │
│          │  402 / 200 + Data    │   (Seller)   │   Verify/Settle Result   │              │
└──────────┘                      └──────────────┘                           └──────────────┘
                                                                                     │
                                                                                     ▼
                                                                              ┌──────────────┐
                                                                              │  Blockchain  │
                                                                              │ (Settlement) │
                                                                              └──────────────┘
```

| 角色                         | 职责                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------- |
| **Client (Buyer)**           | 发起 HTTP 请求，收到 402 后构造支付签名，重新请求                               |
| **Resource Server (Seller)** | 提供 API/内容，声明支付要求，验证支付后交付资源                                 |
| **Facilitator**              | 可选但推荐的中间服务——帮 Server 验证签名、上链结算，Server 无需自建链上基础设施 |
| **Blockchain**               | 最终结算层（Base、Ethereum、Solana、Polygon 等）                                |

### 2.2 三个 HTTP Header

x402 v2 通过三个标准 HTTP Header 完成全部通信，无需额外的 WebSocket 或回调：

| Header              | 方向            | 内容                                                |
| ------------------- | --------------- | --------------------------------------------------- |
| `PAYMENT-REQUIRED`  | Server → Client | Base64 编码的 `PaymentRequired` 对象（支付要求）    |
| `PAYMENT-SIGNATURE` | Client → Server | Base64 编码的 `PaymentPayload` 对象（支付签名）     |
| `PAYMENT-RESPONSE`  | Server → Client | Base64 编码的 `SettlementResponse` 对象（结算确认） |

### 2.3 Scheme（支付方案）

Scheme 是"逻辑上如何移动资金"的抽象。同一个 Scheme 在不同区块链（Network）上的实现可以完全不同。

| Scheme            | 描述                                              | 典型场景                                |
| ----------------- | ------------------------------------------------- | --------------------------------------- |
| **`exact`**       | 精确金额转账：Client 签名授权转给 Server 固定金额 | 文章阅读付费 $0.01、API 单次调用 $0.001 |
| **`upto`** (理论) | 最多转账到某上限，按实际消耗结算                  | LLM Token 计费、视频流量计费            |

当前已经稳定实现的是 **`exact` on EVM**，支持两种资产转移方式：

| 方式         | 原理                                                     | 适用                    |
| ------------ | -------------------------------------------------------- | ----------------------- |
| **EIP-3009** | Token 原生 `transferWithAuthorization`，无需提前 approve | USDC（推荐）            |
| **Permit2**  | 通过 Uniswap Permit2 合约 + x402ExactPermit2Proxy        | 任何 ERC-20（通用回退） |

---

## 3. 典型交互流程（12 步）

```
 Client                   Resource Server              Facilitator              Blockchain
   │                            │                           │                       │
   │─── 1. GET /resource ──────→│                           │                       │
   │                            │                           │                       │
   │←── 2. 402 + PAYMENT-      │                           │                       │
   │       REQUIRED header ─────│                           │                       │
   │                            │                           │                       │
   │  [3. Client 选择一个                                                            │
   │   PaymentRequirement,                                                           │
   │   用钱包签名构造 Payload]                                                        │
   │                            │                           │                       │
   │─── 4. GET /resource ──────→│                           │                       │
   │   + PAYMENT-SIGNATURE      │                           │                       │
   │                            │                           │                       │
   │                            │─── 5. POST /verify ──────→│                       │
   │                            │                           │                       │
   │                            │←── 6. Verification ──────│                       │
   │                            │       Response            │                       │
   │                            │                           │                       │
   │                            │  [7. If valid, Server                              │
   │                            │   fulfills the request]                             │
   │                            │                           │                       │
   │                            │─── 8. POST /settle ──────→│                       │
   │                            │                           │                       │
   │                            │                           │── 9. Submit tx ───────→│
   │                            │                           │                       │
   │                            │                           │←─ 10. Confirmation ───│
   │                            │                           │                       │
   │                            │←── 11. Settlement ───────│                       │
   │                            │        Response           │                       │
   │                            │                           │                       │
   │←── 12. 200 OK + Data ─────│                           │                       │
   │   + PAYMENT-RESPONSE       │                           │                       │
```

### 流程精要

1. **无预注册**：Client 不需要在 Server 上有账号
2. **无 API Key**：支付签名本身就是认证
3. **无 Gas 负担**：Facilitator 代付 Gas（EIP-3009 模式下 Client 完全 gasless）
4. **Facilitator 无法篡改**：签名固定了金额和收款地址，Facilitator 仅充当广播者
5. **无状态**：每次请求独立结算，无 session / cookie

---

## 4. exact Scheme on EVM 技术深入

### 4.1 EIP-3009 方式（推荐，以 USDC 为例）

```
Client 钱包签名 transferWithAuthorization(from, to, value, validAfter, validBefore, nonce)
        │
        ▼
PAYMENT-SIGNATURE Header:
{
  "x402Version": 2,
  "accepted": { "scheme": "exact", "network": "eip155:8453", "amount": "10000", "payTo": "0x..." },
  "payload": {
    "signature": "0x...",
    "authorization": { "from": "0x...", "to": "0x...", "value": "10000", "validAfter": "...", "validBefore": "..." }
  }
}
        │
        ▼
Facilitator 调用 USDC.transferWithAuthorization(from, to, value, validAfter, validBefore, nonce, signature)
        │
        ▼
链上直接从 Client → Server 转账，Facilitator 仅付 Gas
```

**关键安全属性**：

- 签名绑定了 `to`（收款方）和 `value`（金额），Facilitator 无法修改
- `validBefore` 限制了签名有效期，防止延迟攻击
- `nonce` 防重放

### 4.2 Permit2 方式（通用回退）

```
前置：Client 需做一次 ERC20.approve(Permit2合约, MAX)  ← 一次性操作
        │
        ▼
Client 签名 permitWitnessTransferFrom（含 Witness：收款地址 + 时间窗口）
        │
        ▼
Facilitator 调用 x402ExactPermit2Proxy.settle(permit, amount, owner, witness, signature)
        │
        ▼
Proxy 合约验证 Witness 哈希 → 调用 Permit2.permitWitnessTransferFrom → 转账
```

**x402ExactPermit2Proxy** 合约部署在所有 EVM 链的相同地址（`0x4020CD856C882D5fb903D99CE35316A085Bb0001`），确保跨链一致性。

---

## 5. x402 的核心原则

| 原则                    | 说明                                                         |
| ----------------------- | ------------------------------------------------------------ |
| **开放标准**            | Apache 2.0 开源，不依赖任何单一方                            |
| **HTTP 原生**           | 不需要额外的通信协议，完全嵌入现有 HTTP 请求/响应            |
| **网络/Token/货币无关** | 支持 EVM、Solana、Stellar、Algorand 等多链，未来可扩展到法币 |
| **向后兼容**            | 不会弃用已有网络支持                                         |
| **信任最小化**          | Facilitator 和 Server 都无法在 Client 意图之外移动资金       |
| **易于使用**            | Server 端 1 行代码集成（middleware），Client 端 1 个函数调用 |

---

## 6. x402 的生态数据（截至 2026 年 2 月）

| 指标             | 数据    |
| ---------------- | ------- |
| GitHub Stars     | 5.5k    |
| Contributors     | 220+    |
| Forks            | 1.2k    |
| 被依赖项目       | 526     |
| 过去 30 天交易数 | 75.41M  |
| 过去 30 天交易额 | $24.24M |
| 买家数           | ~94K    |
| 卖家数           | ~22K    |

支持的语言 SDK：TypeScript (44.3%), Python (34.4%), Go (19.8%), Solidity, Java

---

## 7. x402 vs 传统支付 vs 其他 Web3 支付

| 维度       | 传统支付 (Stripe)    | x402               | Superfluid (流支付) |
| ---------- | -------------------- | ------------------ | ------------------- |
| 注册/KYC   | 必须                 | 无需               | 无需                |
| 最小支付额 | ~$0.50               | 任意小额           | 按秒流              |
| 结算速度   | 2-7 天               | 秒级               | 实时                |
| 手续费     | 2.9%+$0.30           | 链上 Gas（极低）   | 链上 Gas            |
| Agent 友好 | 差                   | 原生支持           | 需集成              |
| 协议层集成 | 需 SDK               | HTTP Header 原生   | 需 SDK              |
| 无托管风险 | 有（中间商持有资金） | 无（签名直接转账） | 无                  |

---

## 8. x402 对 AI Agent 经济的意义

x402 是为 **Agent 经济** 量身定制的支付层：

1. **自主支付**：AI Agent 拥有一个钱包即可按需付费调用任何 x402 服务
2. **无需预充值**：没有"先买 credits"的概念，每次请求实时结算
3. **跨服务互操作**：Agent A 可以付费调用 Agent B 的 API，无需预先建立关系
4. **微支付经济**：让每次 API 调用、每个 Token 生成都可以有精确定价
5. **可组合**：与 EIP-8004（Agent 身份/信誉/验证）组合，实现"发现 → 信任 → 支付 → 交付"完整闭环

---

## 9. x402 + EIP-8004 的组合愿景

```
┌─────────────────────────── Agent Trust & Payment Stack ───────────────────────────┐
│                                                                                    │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐              │
│  │  EIP-8004         │    │  EIP-8004         │    │  EIP-8004         │              │
│  │  Identity Registry│    │  Reputation Reg.  │    │  Validation Reg.  │              │
│  │  (Who is it?)     │    │  (How good is it?)│    │  (Is it verified?)│              │
│  └────────┬─────────┘    └────────┬──────────┘    └────────┬─────────┘              │
│           │                       │                        │                        │
│           └───────────────────────┼────────────────────────┘                        │
│                                   │                                                  │
│                          ┌────────▼────────┐                                        │
│                          │    Agent Smart   │                                        │
│                          │    Contract      │                                        │
│                          │  (Business Logic)│                                        │
│                          └────────┬────────┘                                        │
│                                   │                                                  │
│                          ┌────────▼────────┐                                        │
│                          │     x402         │                                        │
│                          │  Payment Layer   │                                        │
│                          │  (How to pay?)   │                                        │
│                          └─────────────────┘                                        │
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

**完整生命周期**:

1. **发现** (EIP-8004 Identity) → Agent 在链上注册身份和能力
2. **评估** (EIP-8004 Reputation) → 查看 Agent 的历史评价
3. **验证** (EIP-8004 Validation) → 确认 Agent 通过第三方审计
4. **支付** (x402) → Client 通过 HTTP 402 流程按次付费
5. **交付** → Agent 执行任务并返回结果
6. **反馈** (EIP-8004 Reputation) → Client 对本次服务评分

---

## 10. 总结

x402 不是一个钱包、不是一条链、也不是一个支付公司——它是一个**协议标准**。就像 HTTP 定义了网页如何传输，x402 定义了互联网上的价值如何流动。

在 AI Agent 蓬勃发展的 2025-2026 年，x402 解决了一个根本性问题：**机器如何自主地、无摩擦地为服务付费**。与 EIP-8004 的身份/信誉/验证体系结合，它构成了完整的 Agent 经济基础设施。

---

_文档生成时间: 2026-02-27 | 基于 [coinbase/x402](https://github.com/coinbase/x402) 仓库分析_
