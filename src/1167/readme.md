两者都是 **EIP-1167 最小代理（Minimal Proxy）** 的工厂，核心目的相同：部署一个轻量代理合约，把所有调用 `delegatecall` 到目标实现合约。区别在于字节码版本：

## 对比

|                        | MinimalProxy（经典 EIP-1167）          | Clone0Factory（PUSH0 版）                  |
| ---------------------- | -------------------------------------- | ------------------------------------------ |
| **runtime 字节码大小** | 45 bytes                               | 44 bytes                                   |
| **creation code 大小** | 55 bytes (0x37)                        | 53 bytes                                   |
| **关键操作码差异**     | 用 `RETURNDATASIZE`（`3d`）来推 0 入栈 | 用 `PUSH0`（`5f`）直接推 0 入栈            |
| **EVM 版本要求**       | 任意（兼容所有链）                     | 需要 Shanghai+（`PUSH0` 于 EIP-3855 引入） |
| **gas 消耗**           | 稍高（`RETURNDATASIZE` 是 2 gas）      | 稍低（`PUSH0` 是 2 gas，但省了一个字节）   |
| **部署方式**           | 纯 assembly 手拼 `mstore`              | `abi.encodePacked` 拼接后 `create`         |
| **错误处理**           | 无（`create` 返回 0 不 revert）        | 有 `FailedCreateClone` revert              |
| **可附带 ETH**         | 固定 0（`create(0, ...)`)              | 支持（`create(callvalue(), ...)`）         |

## 字节码逐段对比

**经典 runtime：**

```
363d3d37 3d3d3d36 3d73<addr> 5af4 3d82803e 903d9160 2b57fd5b f3
```

这里用 `3d`（`RETURNDATASIZE`）当作"推 0"的技巧——因为在调用开始时 returndata 为空，`RETURNDATASIZE` 返回 0。

**PUSH0 runtime：**

```
365f5f37 5f5f365f 73<addr> 5af4 3d5f5f3e 5f3d9160 2a57fd5b f3
```

把所有 `3d`（`RETURNDATASIZE`）替换成了 `5f`（`PUSH0`），语义更清晰，gas 相同但少 1 字节。

## 总结

`Clone0Factory` 是 `MinimalProxy` 的**现代化升级版**，利用 Shanghai 升级引入的 `PUSH0` 操作码替代了 `RETURNDATASIZE` 的 hack，省 1-2 字节部署成本，语义更直观。如果你的目标链支持 Shanghai+（以太坊主网 2023 年 4 月后），优先用 `Clone0Factory`。
