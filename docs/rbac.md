# OpenZeppelin 两种rbac权限管理分析

- **AccessControl**：「合约内自带的轻量RBAC」——每个合约自己管自己的角色。
- **AccessManager**：「全局统一权限中枢」——一个中心合约，管整个系统所有合约的权限。

下面从原理、用法、事件、监控要点四方面讲清楚，方便你在 DApp 和监控系统里区分对待。

---

## 一、核心定位与架构差异

### 1）AccessControl（单合约内置）
- 每个需要权限的合约都 `is AccessControl`，**自己存自己的角色表**。
- 角色用 `bytes32`（如 `keccak256("MINTER_ROLE")`）。
- 典型：`ERC20`、`ERC721`、单个业务合约内部权限。

架构示意：
```
Contract A (AccessControl) ──┐
Contract B (AccessControl) ──┼─ 各自独立权限存储
Contract C (AccessControl) ──┘
```

### 2）AccessManager（全局中心）
- 一个独立的 `AccessManager` 合约，**统一管理所有目标合约**。
- 目标合约继承 `AccessManaged`，用 `restricted` 修饰符，把权限判断委托给中心 `AccessManager`。
- 角色用 `uint64`，可配置「角色→合约+函数选择器」的细粒度映射。
- 支持**执行延迟（timelock）、守护者（guardian）取消操作、紧急暂停目标合约**。

架构示意：
```
AccessManager (中心)
  ├─ Contract1 (AccessManaged)
  ├─ Contract2 (AccessManaged)
  └─ Contract3 (AccessManaged)
```

---

## 二、关键特性对比

### 1）角色体系
- **AccessControl**
  - 角色：`bytes32`
  - 内置：`DEFAULT_ADMIN_ROLE = 0x00`
  - 每个角色有独立 `admin` 角色。
- **AccessManager**
  - 角色：`uint64`（可标签化）
  - 全局 `ADMIN_ROLE = 0`（最高权限）
  - 每个角色可设：**执行延迟、守护者**。

### 2）权限粒度
- **AccessControl**：合约级、角色级；**不能直接绑定到函数选择器**。
- **AccessManager**：**(合约 + 函数选择器) → 角色**，粒度极细。

### 3）安全机制
- **AccessControl**
  - 无内置 timelock；需自己加 `AccessControlDefaultAdminRules` 实现管理员延迟。
- **AccessManager**
  - 原生支持：
    - **执行延迟**：敏感操作先调度，过 N 秒才能执行。
    - **守护者取消**：延迟期内 guardian 可取消恶意操作。
    - **目标紧急关闭**：一键暂停某个合约所有 `restricted` 函数。

### 4）事件（监控必抓）
- **AccessControl**
  ```solidity
  event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
  event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
  ```
- **AccessManager**
  ```solidity
  event RoleGranted(uint64 indexed roleId, address indexed account, uint32 executionDelay);
  event RoleRevoked(uint64 indexed roleId, address indexed account);
  event OperationScheduled(bytes32 indexed operationId, ...);
  event OperationExecuted(bytes32 indexed operationId, ...);
  event OperationCancelled(bytes32 indexed operationId, ...);
  ```

---

## 三、适用场景（你该怎么选）

### 用 AccessControl 当：
- 合约数量少、权限简单（如单个 ERC20/721）。
- 每个合约独立部署、独立权限，不需要全局统一管控。
- 想要轻量、少依赖、易审计。

### 用 AccessManager 当：
- 你的 DApp 是**多合约系统**（Mint+质押+国库+LP+治理）。
- 需要**全局权限视图、统一审计、一键紧急关停**。
- 核心资金/治理合约，必须有 **timelock + 守护者** 双保险。
- 要防止「管理员私钥被盗，瞬间转走所有资金」——延迟+取消是关键。

---

## 四、对链下监控意味着什么

### 1）如果你的合约用 AccessControl
- 监控要点：
  - 监听所有合约的 `RoleGranted` / `RoleRevoked`。
  - 基线：记录初始 `DEFAULT_ADMIN_ROLE`、`MINTER_ROLE` 等持有者。
  - 告警：**非白名单地址被授予管理员/铸币权限**。

### 2）如果用 AccessManager（更适合你复杂经济模型 DApp）
- 监控要点（多了很多维度，更安全）：
  - 监听 `AccessManager` 全局事件：
    - `RoleGranted`：关注 `roleId=0`（ADMIN）、`executionDelay=0`（无延迟高危）。
    - `OperationScheduled`：敏感操作（如 `setFee`、`transferFunds`）调度。
    - `OperationCancelled`：守护者取消操作（异常行为）。
    - `setTargetClosed`：紧急暂停合约（正常/异常都要记录）。
  - 基线：
    - 所有角色→地址映射。
    - 每个角色的执行延迟、守护者地址。
    - 每个目标合约的「函数选择器→角色」权限表。
  - 告警规则：
    - ADMIN_ROLE 变更。
    - 关键角色（如 MINTER）执行延迟被改为 0。
    - 守护者地址变更。
    - 敏感函数（国库转出、铸币）权限被分配给新角色。

---

## 五、一句话总结（方便你记）
- **AccessControl**：**合约自己管自己，轻量独立**，适合简单场景。
- **AccessManager**：**一个中心管所有，全局统一+延迟+守护者**，适合复杂、高价值 DApp（你这种有独有经济模型、国库、多合约的项目，强烈推荐）。

