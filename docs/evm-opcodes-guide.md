# EVM Opcodes 从入门到精通

> 基于 [evm.codes](https://www.evm.codes/) 整理，涵盖所有操作码的分类讲解、Gas 消耗、栈效果以及实战示例。

---

## 目录

- [第一章：EVM 基础架构](#第一章evm-基础架构)
- [第二章：操作码速查表](#第二章操作码速查表)
- [第三章：算术与比较操作](#第三章算术与比较操作)
- [第四章：位运算与移位操作](#第四章位运算与移位操作)
- [第五章：密码学操作（SHA3/Keccak）](#第五章密码学操作sha3keccak)
- [第六章：环境信息操作](#第六章环境信息操作)
- [第七章：区块信息操作](#第七章区块信息操作)
- [第八章：栈、内存与存储操作](#第八章栈内存与存储操作)
- [第九章：流程控制操作](#第九章流程控制操作)
- [第十章：PUSH / DUP / SWAP 操作](#第十章push--dup--swap-操作)
- [第十一章：日志操作（Events）](#第十一章日志操作events)
- [第十二章：系统操作（调用与创建合约）](#第十二章系统操作调用与创建合约)
- [第十三章：Gas 机制深入](#第十三章gas-机制深入)
- [第十四章：实战案例](#第十四章实战案例)
- [第十五章：Gas 优化技巧](#第十五章gas-优化技巧)
- [附录：参考资源](#附录参考资源)

---

## 第一章：EVM 基础架构

### 1.1 什么是 EVM？

EVM (Ethereum Virtual Machine) 是一台**基于栈的虚拟计算机**，负责执行智能合约中的指令。所有 EVM 指令从栈中获取参数（除了 PUSHx 指令从代码中读取参数），每条指令有明确的**栈输入**（参数）和**栈输出**（返回值）。

```
智能合约代码 (Bytecode)
         │
         ▼
┌─────────────────────────────────────┐
│              EVM                     │
│  ┌──────────┐   ┌──────────────┐    │
│  │   Stack   │   │   Memory     │    │
│  │  (栈)     │   │  (内存)      │    │
│  │  1024层   │   │  易失性/字节) │    │
│  │  32字节/层 │   │              │    │
│  └──────────┘   └──────────────┘    │
│  ┌──────────┐   ┌──────────────┐    │
│  │  Storage  │   │   Calldata   │    │
│  │  (存储)   │   │  (调用数据)   │    │
│  │  持久/映射 │   │  只读         │    │
│  └──────────┘   └──────────────┘    │
│  ┌──────────────────────────────┐   │
│  │     Program Counter (PC)      │   │
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
```

### 1.2 核心数据区域

| 数据区域                   | 持久性       | 大小                            | 读写指令                               | 特点                         |
| -------------------------- | ------------ | ------------------------------- | -------------------------------------- | ---------------------------- |
| **Stack** (栈)             | 调用上下文内 | 最多1024个元素，每个32字节      | PUSH/POP/DUP/SWAP                      | 所有计算的基础               |
| **Memory** (内存)          | 调用上下文内 | 线性字节数组，按需扩展          | MLOAD/MSTORE/MSTORE8                   | 初始化为0，扩展有额外Gas开销 |
| **Storage** (存储)         | **永久持久** | 32字节 slot → 32字节 value 映射 | SLOAD/SSTORE                           | 最昂贵的操作                 |
| **Calldata** (调用数据)    | 调用上下文内 | 只读字节数组                    | CALLDATALOAD/CALLDATASIZE/CALLDATACOPY | 不可修改                     |
| **Return Data** (返回数据) | 调用后       | 字节数组                        | RETURNDATASIZE/RETURNDATACOPY          | 上次外部调用的返回值         |
| **Code** (代码)            | 永久         | 不可变字节数组                  | CODESIZE/CODECOPY                      | 合约的字节码                 |

### 1.3 程序计数器 (Program Counter)

PC 指示 EVM 下一条要执行的指令位置。通常每执行一条指令 PC +1（除了 PUSHx 会跳过其参数字节）。JUMP 和 JUMPI 可以修改 PC 指向的位置。

### 1.4 Gas 费用概览

每笔交易的 Gas 由以下部分组成：

- **Intrinsic Gas**: 21000 gas（基础交易费）+ 32000 gas（如果创建合约）
- **Calldata**: 每个零字节 4 gas，非零字节 16 gas
- **Opcode 固定成本**: 每条指令的基础 Gas
- **Opcode 动态成本**: 根据参数计算的额外 Gas（如内存扩展、冷/热访问）

---

## 第二章：操作码速查表

> 所有操作码范围为 0x00 ~ 0xFF (0 ~ 255)

### 操作码分类概览

| 范围      | 分类         | 典型操作码                                                                              |
| --------- | ------------ | --------------------------------------------------------------------------------------- |
| 0x00-0x0B | 停止与算术   | STOP, ADD, MUL, SUB, DIV, MOD, EXP...                                                   |
| 0x10-0x1D | 比较与位运算 | LT, GT, EQ, ISZERO, AND, OR, XOR, NOT, SHL, SHR, SAR                                    |
| 0x20      | 密码学       | SHA3 (KECCAK256)                                                                        |
| 0x30-0x3F | 环境信息     | ADDRESS, BALANCE, CALLER, CALLVALUE, CALLDATALOAD...                                    |
| 0x40-0x48 | 区块信息     | BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, BASEFEE...                                      |
| 0x50-0x5F | 栈/内存/存储 | POP, MLOAD, MSTORE, SLOAD, SSTORE, JUMP, JUMPI, PC, MSIZE, GAS, JUMPDEST, PUSH0         |
| 0x60-0x7F | PUSH 操作    | PUSH1 ~ PUSH32                                                                          |
| 0x80-0x8F | DUP 操作     | DUP1 ~ DUP16                                                                            |
| 0x90-0x9F | SWAP 操作    | SWAP1 ~ SWAP16                                                                          |
| 0xA0-0xA4 | 日志操作     | LOG0 ~ LOG4                                                                             |
| 0xF0-0xFF | 系统操作     | CREATE, CALL, CALLCODE, RETURN, DELEGATECALL, CREATE2, STATICCALL, REVERT, SELFDESTRUCT |

---

## 第三章：算术与比较操作

### 3.1 算术操作码

| Opcode | 助记符     | Gas  | 栈输入  | 栈输出       | 描述                                |
| ------ | ---------- | ---- | ------- | ------------ | ----------------------------------- |
| 0x00   | STOP       | 0    | -       | -            | 停止执行                            |
| 0x01   | ADD        | 3    | a, b    | a + b        | 加法（溢出取模 2²⁵⁶）               |
| 0x02   | MUL        | 5    | a, b    | a \* b       | 乘法                                |
| 0x03   | SUB        | 3    | a, b    | a - b        | 减法                                |
| 0x04   | DIV        | 5    | a, b    | a / b        | 无符号整除（b=0时结果为0）          |
| 0x05   | SDIV       | 5    | a, b    | a / b        | 有符号整除                          |
| 0x06   | MOD        | 5    | a, b    | a % b        | 无符号取模                          |
| 0x07   | SMOD       | 5    | a, b    | a % b        | 有符号取模                          |
| 0x08   | ADDMOD     | 8    | a, b, N | (a + b) % N  | 先加后取模（中间结果不溢出）        |
| 0x09   | MULMOD     | 8    | a, b, N | (a \* b) % N | 先乘后取模（中间结果不溢出）        |
| 0x0A   | EXP        | 10\* | a, b    | a \*\* b     | 幂运算（_动态Gas: 50 _ 指数字节数） |
| 0x0B   | SIGNEXTEND | 5    | b, x    | x 符号扩展   | 将低位字节的符号位扩展到256位       |

### 3.2 比较操作码

| Opcode | 助记符 | Gas | 栈输入 | 栈输出         | 描述                     |
| ------ | ------ | --- | ------ | -------------- | ------------------------ |
| 0x10   | LT     | 3   | a, b   | a < b ? 1 : 0  | 无符号小于               |
| 0x11   | GT     | 3   | a, b   | a > b ? 1 : 0  | 无符号大于               |
| 0x12   | SLT    | 3   | a, b   | a < b ? 1 : 0  | 有符号小于               |
| 0x13   | SGT    | 3   | a, b   | a > b ? 1 : 0  | 有符号大于               |
| 0x14   | EQ     | 3   | a, b   | a == b ? 1 : 0 | 等于                     |
| 0x15   | ISZERO | 3   | a      | a == 0 ? 1 : 0 | 是否为零（常用作逻辑非） |

### 实战：Solidity 内联汇编中的算术

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract ArithmeticExamples {
    /// @notice 使用 assembly 实现安全加法（演示目的）
    function safeAdd(uint256 a, uint256 b) external pure returns (uint256 result) {
        assembly {
            result := add(a, b)
            // 检查溢出：如果 result < a，说明溢出了
            if lt(result, a) {
                // revert(0, 0)
                revert(0, 0)
            }
        }
    }

    /// @notice ADDMOD: 大数模运算，中间结果不溢出
    /// 场景：椭圆曲线计算中经常用到
    function modularAdd(uint256 a, uint256 b, uint256 modulus)
        external pure returns (uint256 result)
    {
        assembly {
            result := addmod(a, b, modulus)
        }
    }

    /// @notice MULMOD: 模乘运算
    function modularMul(uint256 a, uint256 b, uint256 modulus)
        external pure returns (uint256 result)
    {
        assembly {
            result := mulmod(a, b, modulus)
        }
    }

    /// @notice SIGNEXTEND: 将 int8 符号扩展到 int256
    function signExtendInt8(uint256 x) external pure returns (int256 result) {
        assembly {
            // signextend(0, x) 表示将第0字节（最低字节）的符号位扩展
            // 如果 x = 0xFF (即 int8 的 -1)，结果为 0xFFFF...FF (int256 的 -1)
            result := signextend(0, x)
        }
    }

    /// @notice EXP 的 Gas 消耗与指数大小有关
    function power(uint256 base, uint256 exponent) external pure returns (uint256 result) {
        assembly {
            result := exp(base, exponent)
        }
    }
}
```

---

## 第四章：位运算与移位操作

### 4.1 位运算操作码

| Opcode | 助记符 | Gas | 栈输入 | 栈输出          | 描述                               |
| ------ | ------ | --- | ------ | --------------- | ---------------------------------- |
| 0x16   | AND    | 3   | a, b   | a & b           | 按位与                             |
| 0x17   | OR     | 3   | a, b   | a \| b          | 按位或                             |
| 0x18   | XOR    | 3   | a, b   | a ^ b           | 按位异或                           |
| 0x19   | NOT    | 3   | a      | ~a              | 按位取反                           |
| 0x1A   | BYTE   | 3   | i, x   | x 的第 i 个字节 | 提取字节（大端序，i=0 是最高字节） |

### 4.2 移位操作码（Constantinople 分叉引入）

| Opcode | 助记符 | Gas | 栈输入       | 栈输出          | 描述                   |
| ------ | ------ | --- | ------------ | --------------- | ---------------------- |
| 0x1B   | SHL    | 3   | shift, value | value << shift  | 左移                   |
| 0x1C   | SHR    | 3   | shift, value | value >> shift  | 逻辑右移（零填充）     |
| 0x1D   | SAR    | 3   | shift, value | value >>> shift | 算术右移（符号位填充） |

### 实战：位运算的实际应用

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract BitwiseExamples {
    /// @notice 使用 AND 提取 uint256 中打包的多个值
    /// 将两个 uint128 打包到一个 uint256 中
    function packTwo128(uint128 a, uint128 b) external pure returns (uint256 packed) {
        assembly {
            // a 放高128位，b 放低128位
            packed := or(shl(128, a), b)
        }
    }

    function unpackTwo128(uint256 packed) external pure returns (uint128 a, uint128 b) {
        assembly {
            // 提取高128位
            a := shr(128, packed)
            // 提取低128位：用 AND 掩码
            b := and(packed, 0xffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice BYTE 操作：提取特定字节
    /// EVM 是大端序!  byte(0, x) 返回最高有效字节
    function extractByte(uint256 x, uint256 position)
        external pure returns (uint8 result)
    {
        assembly {
            result := byte(position, x)
        }
    }

    /// @notice 使用位操作判断奇偶
    function isOdd(uint256 x) external pure returns (bool result) {
        assembly {
            result := and(x, 1)
        }
    }

    /// @notice 使用位操作快速计算 2 的幂
    function powerOfTwo(uint8 n) external pure returns (uint256 result) {
        assembly {
            result := shl(n, 1)  // 1 << n
        }
    }

    /// @notice 检查 x 是否为 2 的幂
    function isPowerOfTwo(uint256 x) external pure returns (bool result) {
        assembly {
            // x > 0 && (x & (x-1)) == 0
            result := and(gt(x, 0), iszero(and(x, sub(x, 1))))
        }
    }
}
```

---

## 第五章：密码学操作（SHA3/Keccak）

### 5.1 SHA3 操作码

| Opcode | 助记符           | Gas            | 栈输入       | 栈输出 | 描述                           |
| ------ | ---------------- | -------------- | ------------ | ------ | ------------------------------ |
| 0x20   | SHA3 (KECCAK256) | 30 + 6 \* 字长 | offset, size | hash   | 计算内存区域的 Keccak-256 哈希 |

> 虽然 EVM 中叫 SHA3，但实际使用的是 **Keccak-256** 算法（不是 NIST 标准化的 SHA-3）。

### Gas 计算

```
gas = 30 + 6 * ceil(size / 32) + memory_expansion_cost
```

### 实战：底层哈希计算

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract KeccakExamples {
    /// @notice 使用 assembly 计算 keccak256
    function hashValue(uint256 value) external pure returns (bytes32 result) {
        assembly {
            // 将值存入内存的 scratch space (0x00)
            mstore(0x00, value)
            // 计算从 offset=0 开始的 32 字节的哈希
            result := keccak256(0x00, 32)
        }
    }

    /// @notice 计算两个值的哈希（类似 abi.encodePacked 的效果）
    function hashTwoValues(uint256 a, uint256 b) external pure returns (bytes32 result) {
        assembly {
            // free memory pointer
            let ptr := mload(0x40)
            mstore(ptr, a)
            mstore(add(ptr, 32), b)
            result := keccak256(ptr, 64)
        }
    }

    /// @notice 存储 slot 的计算方式：mapping
    /// mapping(address => uint256) 的 slot 计算
    /// slot = keccak256(abi.encode(key, mappingSlot))
    function computeMappingSlot(address key, uint256 mappingSlot)
        external pure returns (bytes32 slot)
    {
        assembly {
            let ptr := mload(0x40)
            // address 存为 32 字节（左边填充0）
            mstore(ptr, key)
            mstore(add(ptr, 32), mappingSlot)
            slot := keccak256(ptr, 64)
        }
    }

    /// @notice 动态数组的元素 slot 计算
    /// 动态数组 arr（声明为 slot p）：
    ///   arr.length 存在 slot p
    ///   arr[i] 存在 slot keccak256(p) + i
    function computeArrayElementSlot(uint256 arraySlot, uint256 index)
        external pure returns (bytes32 slot)
    {
        assembly {
            mstore(0x00, arraySlot)
            slot := add(keccak256(0x00, 32), index)
        }
    }
}
```

---

## 第六章：环境信息操作

### 6.1 操作码列表

| Opcode | 助记符         | Gas        | 栈输出 | 描述                         |
| ------ | -------------- | ---------- | ------ | ---------------------------- |
| 0x30   | ADDRESS        | 2          | addr   | 当前合约地址                 |
| 0x31   | BALANCE        | 100/2600\* | bal    | 指定地址的 ETH 余额（wei）   |
| 0x32   | ORIGIN         | 2          | addr   | 交易发起者（tx.origin）      |
| 0x33   | CALLER         | 2          | addr   | 直接调用者（msg.sender）     |
| 0x34   | CALLVALUE      | 2          | value  | 附带的 ETH 数量（msg.value） |
| 0x35   | CALLDATALOAD   | 3          | data   | 从 calldata 加载 32 字节     |
| 0x36   | CALLDATASIZE   | 2          | size   | calldata 大小                |
| 0x37   | CALLDATACOPY   | 3+         | -      | 复制 calldata 到内存         |
| 0x38   | CODESIZE       | 2          | size   | 当前合约代码大小             |
| 0x39   | CODECOPY       | 3+         | -      | 复制合约代码到内存           |
| 0x3A   | GASPRICE       | 2          | price  | 当前交易 gas 价格            |
| 0x3B   | EXTCODESIZE    | 100/2600\* | size   | 外部合约代码大小             |
| 0x3C   | EXTCODECOPY    | 100/2600\* | -      | 复制外部合约代码到内存       |
| 0x3D   | RETURNDATASIZE | 2          | size   | 上次调用的返回数据大小       |
| 0x3E   | RETURNDATACOPY | 3+         | -      | 复制返回数据到内存           |
| 0x3F   | EXTCODEHASH    | 100/2600\* | hash   | 外部合约代码哈希             |

> \*Gas 费用取决于地址是否已在访问列表中（warm=100, cold=2600）

### ORIGIN vs CALLER 的区别

```
用户 EOA ──tx──> 合约 A ──call──> 合约 B ──call──> 合约 C

在合约 C 中：
  ORIGIN (tx.origin) = 用户 EOA       ← 始终是原始交易发起者
  CALLER (msg.sender) = 合约 B 的地址  ← 直接调用者
```

> ⚠️ **安全提示**：永远不要使用 `tx.origin` 做权限验证！攻击者可通过中间合约发起调用。

### 实战：环境信息获取

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract EnvironmentExamples {
    /// @notice 使用 assembly 读取 calldata（函数参数的底层表示）
    function readCalldata() external pure returns (
        bytes4 selector,
        uint256 calldataLen
    ) {
        assembly {
            // 前 4 字节是函数选择器
            selector := calldataload(0)
            calldataLen := calldatasize()
        }
    }

    /// @notice RETURNDATASIZE 的经典用法 —— 在 EIP-1167 最小代理中
    /// 在任何外部调用之前，returndatasize() == 0
    /// 这比 PUSH1 0 便宜（2 gas vs 3 gas），用于将 0 推入栈中
    function returndataTrick() external pure returns (uint256 zero) {
        assembly {
            // 这在最小代理合约中是一个经典的 gas 优化技巧
            // 在没有外部调用之前，returndatasize 总是 0
            zero := returndatasize()
        }
    }

    /// @notice 检查地址是否为合约
    function isContract(address account) external view returns (bool result) {
        assembly {
            result := gt(extcodesize(account), 0)
        }
    }

    /// @notice 获取合约自身的 codehash
    function myCodeHash() external view returns (bytes32 hash) {
        assembly {
            hash := extcodehash(address())
        }
    }
}
```

---

## 第七章：区块信息操作

### 7.1 操作码列表

| Opcode | 助记符      | Gas | 栈输出 | 描述                                            |
| ------ | ----------- | --- | ------ | ----------------------------------------------- |
| 0x40   | BLOCKHASH   | 20  | hash   | 指定区块号的哈希（仅最近256个块）               |
| 0x41   | COINBASE    | 2   | addr   | 当前区块矿工/验证者地址                         |
| 0x42   | TIMESTAMP   | 2   | ts     | 当前区块时间戳                                  |
| 0x43   | NUMBER      | 2   | num    | 当前区块号                                      |
| 0x44   | PREVRANDAO  | 2   | rand   | 前一个区块的 RANDAO 值（PoS 后替代 DIFFICULTY） |
| 0x45   | GASLIMIT    | 2   | limit  | 当前区块的 gas limit                            |
| 0x46   | CHAINID     | 2   | id     | 链 ID（EIP-1344，Istanbul 引入）                |
| 0x47   | SELFBALANCE | 5   | bal    | 当前合约的 ETH 余额（比 BALANCE(ADDRESS) 便宜） |
| 0x48   | BASEFEE     | 2   | fee    | 当前区块的 base fee（EIP-1559, London 引入）    |
| 0x49   | BLOBHASH    | 3   | hash   | Blob 版本哈希（EIP-4844, Cancun 引入）          |
| 0x4A   | BLOBBASEFEE | 2   | fee    | 当前 blob base fee（EIP-7516, Cancun 引入）     |

### 实战：区块信息的使用

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract BlockInfoExamples {
    /// @notice ⚠️ 使用区块信息作为"随机源"（不安全！仅做演示）
    /// 矿工/验证者可以操纵这些值
    function unsafeRandom() external view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.prevrandao,   // PREVRANDAO
            block.timestamp,    // TIMESTAMP
            block.number,       // NUMBER
            msg.sender          // CALLER
        )));
    }

    /// @notice SELFBALANCE 比 address(this).balance 更省 Gas
    function getBalance() external view returns (uint256 bal) {
        assembly {
            bal := selfbalance()
        }
    }

    /// @notice 检查链 ID 防止跨链重放攻击
    function getChainId() external view returns (uint256 id) {
        assembly {
            id := chainid()
        }
    }

    /// @notice EIP-1559 base fee 查询
    function getBaseFee() external view returns (uint256 fee) {
        assembly {
            fee := basefee()
        }
    }

    /// @notice BLOCKHASH 仅能查询最近 256 个区块
    function getBlockHash(uint256 blockNum) external view returns (bytes32 hash) {
        assembly {
            hash := blockhash(blockNum)
            // 如果 blockNum 不在 [block.number - 256, block.number - 1] 范围内
            // 返回 0
        }
    }
}
```

---

## 第八章：栈、内存与存储操作

### 8.1 栈操作

| Opcode | 助记符 | Gas | 描述                 |
| ------ | ------ | --- | -------------------- |
| 0x50   | POP    | 2   | 弹出栈顶元素（丢弃） |

### 8.2 内存操作

| Opcode | 助记符  | Gas | 栈输入        | 栈输出 | 描述                           |
| ------ | ------- | --- | ------------- | ------ | ------------------------------ |
| 0x51   | MLOAD   | 3\* | offset        | value  | 从内存加载 32 字节             |
| 0x52   | MSTORE  | 3\* | offset, value | -      | 存储 32 字节到内存             |
| 0x53   | MSTORE8 | 3\* | offset, value | -      | 存储 1 字节到内存              |
| 0x59   | MSIZE   | 2   | -             | size   | 当前内存大小（字节，32的倍数） |

> \*可能触发内存扩展，产生额外 Gas 开销

#### 内存布局（Solidity ABI）

```
┌─────────────────────────────────────┐
│ 0x00 - 0x1F  Scratch Space          │  ← 临时存储，keccak256 等使用
│ 0x20 - 0x3F  Scratch Space          │
│ 0x40 - 0x5F  Free Memory Pointer    │  ← 指向下一个可用内存位置
│ 0x60 - 0x7F  Zero Slot              │  ← 固定为 0，用作动态数组初始值
│ 0x80+        可用内存区域             │  ← 实际数据从这里开始
└─────────────────────────────────────┘
```

#### 内存扩展成本计算

```
memory_size_word = (memory_byte_size + 31) / 32
memory_cost = (memory_size_word ** 2) / 512 + (3 * memory_size_word)
expansion_cost = new_memory_cost - old_memory_cost
```

> 内存成本**二次增长**！这意味着使用很大的偏移量会指数级增加 Gas 成本。

### 8.3 存储操作

| Opcode | 助记符 | Gas        | 栈输入     | 栈输出 | 描述       |
| ------ | ------ | ---------- | ---------- | ------ | ---------- |
| 0x54   | SLOAD  | 100/2100\* | key        | value  | 从存储读取 |
| 0x55   | SSTORE | 动态\*\*   | key, value | -      | 写入存储   |

> \*warm=100, cold=2100
>
> \*\*SSTORE 的 Gas 非常复杂，取决于原始值、当前值和新值

#### SSTORE Gas 详解（Post-Berlin）

| 场景                      | Gas                         | 退款               |
| ------------------------- | --------------------------- | ------------------ |
| 从 0 设为非 0             | 22100 (cold) / 20000 (warm) | 0                  |
| 从非 0 设为非 0（不同值） | 5000 (cold) / 2900 (warm)   | 0                  |
| 从非 0 设为 0             | 5000 (cold) / 2900 (warm)   | 4800 退款          |
| 从非 0 设回原始值         | 100 (已warm)                | 恢复之前消耗的差额 |

### 实战：内存与存储的对比使用

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract MemoryStorageExamples {
    uint256 public storedValue;

    /// @notice 演示内存操作：free memory pointer 的使用
    function memoryDemo() external pure returns (uint256 freePtr, uint256 memSize) {
        assembly {
            // 读取 free memory pointer
            freePtr := mload(0x40)  // 初始值通常是 0x80

            // 在 free memory pointer 处写入数据
            mstore(freePtr, 42)

            // 更新 free memory pointer
            mstore(0x40, add(freePtr, 32))

            // 获取内存大小
            memSize := msize()
        }
    }

    /// @notice 演示 storage 的 slot 布局
    /// Solidity 中变量按声明顺序占用 slot
    function directStorageAccess() external view returns (uint256 val) {
        assembly {
            // storedValue 是第一个状态变量，占据 slot 0
            val := sload(0)
        }
    }

    /// @notice 使用 assembly 绕过可见性修饰符直接写 storage
    function directStorageWrite(uint256 newValue) external {
        assembly {
            sstore(0, newValue)
        }
    }

    /// @notice 多个小变量的 storage packing
    /// 多个 < 32 字节的变量可能共享一个 slot
    uint128 public a; // slot 1 的低 128 位
    uint128 public b; // slot 1 的高 128 位

    function readPackedStorage() external view returns (uint128 valA, uint128 valB) {
        assembly {
            let packed := sload(1)          // slot 1
            valA := and(packed, 0xffffffffffffffffffffffffffffffff)
            valB := shr(128, packed)
        }
    }
}
```

### 8.4 临时存储操作（Cancun 引入，EIP-1153）

| Opcode | 助记符 | Gas | 栈输入     | 栈输出 | 描述           |
| ------ | ------ | --- | ---------- | ------ | -------------- |
| 0x5C   | TLOAD  | 100 | key        | value  | 从临时存储读取 |
| 0x5D   | TSTORE | 100 | key, value | -      | 写入临时存储   |

临时存储（Transient Storage）在**交易结束后自动清除**，Gas 成本远低于 SSTORE：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract TransientStorageExample {
    /// @notice 使用 transient storage 实现重入锁
    /// 比传统的 storage 重入锁便宜得多
    bytes32 constant LOCK_SLOT = keccak256("REENTRANCY_LOCK");

    modifier nonReentrant() {
        assembly {
            if tload(LOCK_SLOT.slot) { revert(0, 0) }
            tstore(LOCK_SLOT.slot, 1)
        }
        _;
        assembly {
            tstore(LOCK_SLOT.slot, 0)
        }
    }
}
```

---

## 第九章：流程控制操作

### 9.1 操作码列表

| Opcode | 助记符   | Gas  | 栈输入       | 描述                             |
| ------ | -------- | ---- | ------------ | -------------------------------- |
| 0x56   | JUMP     | 8    | dest         | 无条件跳转                       |
| 0x57   | JUMPI    | 10   | dest, cond   | 条件跳转（cond ≠ 0 时跳转）      |
| 0x5B   | JUMPDEST | 1    | -            | 标记合法跳转目的地               |
| 0x58   | PC       | 2    | -            | 当前程序计数器（已弃用）         |
| 0x5A   | GAS      | 2    | -            | 剩余 gas                         |
| 0x00   | STOP     | 0    | -            | 停止执行，成功返回               |
| 0xFD   | REVERT   | 0\*  | offset, size | 回滚状态，返回数据，退还剩余 gas |
| 0xFE   | INVALID  | 全部 | -            | 故意失败，消耗所有 gas           |

> JUMP/JUMPI 只能跳转到 JUMPDEST 标记的位置，否则执行失败。

### 实战：理解控制流

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract FlowControlExamples {
    /// @notice 使用 assembly 实现 if-else
    function max(uint256 a, uint256 b) external pure returns (uint256 result) {
        assembly {
            // Yul 的 switch 语句
            switch gt(a, b)
            case 1 { result := a }
            default { result := b }
        }
    }

    /// @notice 使用 assembly 实现循环
    function sumUpTo(uint256 n) external pure returns (uint256 result) {
        assembly {
            let i := 0
            for { } lt(i, n) { i := add(i, 1) } {
                result := add(result, add(i, 1))
            }
        }
    }

    /// @notice 自定义 revert 消息
    function customRevert() external pure {
        assembly {
            // Error(string) 选择器 = 0x08c379a0
            let ptr := mload(0x40)
            mstore(ptr, 0x08c379a020000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 4), 32)         // string offset
            mstore(add(ptr, 36), 11)        // string length
            mstore(add(ptr, 68), "custom err\x00")  // string data
            revert(ptr, 100)
        }
    }

    /// @notice 检查剩余 gas 以防止 gas griefing
    function gasCheck() external view returns (uint256 remaining) {
        assembly {
            remaining := gas()
        }
    }
}
```

---

## 第十章：PUSH / DUP / SWAP 操作

### 10.1 PUSH 操作

| Opcode | 助记符 | Gas | 描述                              |
| ------ | ------ | --- | --------------------------------- |
| 0x5F   | PUSH0  | 2   | 推入 0（Shanghai 引入，EIP-3855） |
| 0x60   | PUSH1  | 3   | 推入 1 字节                       |
| 0x61   | PUSH2  | 3   | 推入 2 字节                       |
| ...    | ...    | 3   | ...                               |
| 0x7F   | PUSH32 | 3   | 推入 32 字节                      |

> **PUSH0 vs PUSH1 0**: PUSH0 只有 1 字节，PUSH1 0 需要 2 字节。PUSH0 节省 1 字节部署成本和 1 gas 执行成本。这就是 Clone0Factory 比经典 EIP-1167 小 1 字节的原因。

### 10.2 DUP 操作

| Opcode | 助记符 | Gas | 描述                 |
| ------ | ------ | --- | -------------------- |
| 0x80   | DUP1   | 3   | 复制栈顶第 1 个元素  |
| 0x81   | DUP2   | 3   | 复制栈顶第 2 个元素  |
| ...    | ...    | 3   | ...                  |
| 0x8F   | DUP16  | 3   | 复制栈顶第 16 个元素 |

### 10.3 SWAP 操作

| Opcode | 助记符 | Gas | 描述                   |
| ------ | ------ | --- | ---------------------- |
| 0x90   | SWAP1  | 3   | 交换栈顶与第 2 个元素  |
| 0x91   | SWAP2  | 3   | 交换栈顶与第 3 个元素  |
| ...    | ...    | 3   | ...                    |
| 0x9F   | SWAP16 | 3   | 交换栈顶与第 17 个元素 |

### 栈操作图解

```
初始栈:    [D, C, B, A]     （D 在栈顶）

DUP2:      [C, D, C, B, A]   复制第2个元素到栈顶
SWAP1:     [C, D, B, A]      前提：[D, C,...] → [C, D,...]
POP:       [C, B, A]         删除栈顶
```

### 实战：理解编译器如何使用 DUP/SWAP

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract StackExamples {
    /// @notice 以下 Yul 完成 (a + b) * (a - b) 的计算
    /// 编译器会使用 DUP 来复制需要多次引用的值
    function diffOfSquares(uint256 a, uint256 b) external pure returns (uint256 result) {
        assembly {
            // 等价于: result = (a + b) * (a - b)
            // Yul 会自动管理 DUP 和 SWAP
            result := mul(add(a, b), sub(a, b))
        }
    }

    /// @notice 演示 Stack too deep 问题
    /// 在 EVM 中，你只能直接访问栈顶16个元素
    /// 超出范围需要通过内存中转
    function manyVariables() external pure returns (uint256) {
        uint256 v1 = 1; uint256 v2 = 2; uint256 v3 = 3;
        uint256 v4 = 4; uint256 v5 = 5; uint256 v6 = 6;
        uint256 v7 = 7; uint256 v8 = 8; uint256 v9 = 9;
        // 开启 via-ir 可缓解 stack too deep 问题
        return v1 + v2 + v3 + v4 + v5 + v6 + v7 + v8 + v9;
    }
}
```

---

## 第十一章：日志操作（Events）

### 11.1 操作码列表

| Opcode | 助记符 | Gas                  | 栈输入                       | 描述                |
| ------ | ------ | -------------------- | ---------------------------- | ------------------- |
| 0xA0   | LOG0   | 375 + 8\*size        | offset, size                 | 记录无 topic 的日志 |
| 0xA1   | LOG1   | 375 + 375 + 8\*size  | offset, size, topic1         | 1 个 topic          |
| 0xA2   | LOG2   | 375 + 750 + 8\*size  | offset, size, t1, t2         | 2 个 topic          |
| 0xA3   | LOG3   | 375 + 1125 + 8\*size | offset, size, t1, t2, t3     | 3 个 topic          |
| 0xA4   | LOG4   | 375 + 1500 + 8\*size | offset, size, t1, t2, t3, t4 | 4 个 topic          |

> 每多一个 topic 额外消耗 375 gas。日志数据不存在链上状态中，只存在区块的 transaction receipt 中。

### Solidity Event 与 LOG 的关系

```solidity
event Transfer(address indexed from, address indexed to, uint256 value);

// 当触发 emit Transfer(alice, bob, 100) 时，EVM 执行的是：
// LOG3(
//   offset, size,                               // data 区域包含 value=100
//   keccak256("Transfer(address,address,uint256)"), // topic[0] = 事件签名
//   alice,                                        // topic[1] = indexed from
//   bob                                           // topic[2] = indexed to
// )
// 非 indexed 参数编码到 data 区域
// indexed 参数作为 topic 传入
// topic[0] 始终是事件签名的 keccak256（anonymous 事件除外）
```

### 实战：底层日志触发

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract LogExamples {
    /// @notice 使用 assembly 手动触发 Transfer 事件
    function emitTransfer(address from, address to, uint256 value) external {
        assembly {
            // Transfer(address,address,uint256) 事件签名
            let sig := 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef

            // 将 value 写入内存作为 data
            mstore(0x00, value)

            // LOG3: 3 个 topic (sig, from, to), data 从 offset=0 读取 32 字节
            log3(0x00, 32, sig, from, to)
        }
    }

    /// @notice anonymous 事件不使用第一个 topic 作为签名
    /// 这意味着可以有最多 4 个 indexed 参数
    event AnonymousEvent(uint256 indexed a) anonymous;

    function emitAnonymous(uint256 a) external {
        assembly {
            // LOG1 而不是 LOG2，因为没有事件签名 topic
            log1(0, 0, a)
        }
    }
}
```

---

## 第十二章：系统操作（调用与创建合约）

### 12.1 合约创建操作

| Opcode | 助记符  | Gas    | 栈输入                    | 栈输出 | 描述                            |
| ------ | ------- | ------ | ------------------------- | ------ | ------------------------------- |
| 0xF0   | CREATE  | 32000+ | value, offset, size       | addr   | 创建合约 (地址由 nonce 决定)    |
| 0xF5   | CREATE2 | 32000+ | value, offset, size, salt | addr   | 创建合约 (地址可预测, EIP-1014) |

#### CREATE vs CREATE2 地址计算

```
CREATE:  address = keccak256(rlp([sender, nonce]))[12:]
CREATE2: address = keccak256(0xff ++ sender ++ salt ++ keccak256(initcode))[12:]
```

### 12.2 外部调用操作

| Opcode | 助记符       | Gas       | 栈输入                                                   | 栈输出  | 描述                                     |
| ------ | ------------ | --------- | -------------------------------------------------------- | ------- | ---------------------------------------- |
| 0xF1   | CALL         | 100/2600+ | gas, addr, value, argsOffset, argsLen, retOffset, retLen | success | 调用外部合约                             |
| 0xF2   | CALLCODE     | 100/2600+ | gas, addr, value, argsOffset, argsLen, retOffset, retLen | success | 调用外部代码（使用自己的存储）**已弃用** |
| 0xF4   | DELEGATECALL | 100/2600+ | gas, addr, argsOffset, argsLen, retOffset, retLen        | success | 委托调用（使用自己的存储和上下文）       |
| 0xFA   | STATICCALL   | 100/2600+ | gas, addr, argsOffset, argsLen, retOffset, retLen        | success | 只读调用（不能修改状态）                 |

### CALL vs DELEGATECALL vs STATICCALL

```
┌─────────────────────────────────────────────────────┐
│                      CALL                            │
│  调用者 A ──call──> 被调者 B                          │
│  ● msg.sender = A                                    │
│  ● msg.value = 传入的 value                           │
│  ● storage: 修改 B 的存储                              │
│  ● 用途: 正常的外部调用                                 │
├─────────────────────────────────────────────────────┤
│                   DELEGATECALL                        │
│  调用者 A ──delegatecall──> 被调者 B 的代码             │
│  ● msg.sender = 保持原始调用者                          │
│  ● msg.value = 保持原始值                              │
│  ● storage: 修改 A 的存储（使用 B 的代码逻辑）            │
│  ● 用途: 代理模式 (Proxy), 库调用                       │
├─────────────────────────────────────────────────────┤
│                    STATICCALL                         │
│  调用者 A ──staticcall──> 被调者 B                     │
│  ● 不能执行任何状态修改指令                              │
│  ● 不能发送 ETH                                       │
│  ● 用途: view/pure 函数调用                            │
└─────────────────────────────────────────────────────┘
```

### 12.3 返回与销毁

| Opcode | 助记符       | Gas   | 栈输入       | 描述                                          |
| ------ | ------------ | ----- | ------------ | --------------------------------------------- |
| 0xF3   | RETURN       | 0\*   | offset, size | 返回内存数据，正常结束                        |
| 0xFD   | REVERT       | 0\*   | offset, size | 回滚所有状态变更，返回数据                    |
| 0xFF   | SELFDESTRUCT | 5000+ | addr         | 销毁合约，发送余额到指定地址（EIP-6780 限制） |

> EIP-6780 (Cancun)：SELFDESTRUCT 仅在合约创建的**同一笔交易**中才会真正销毁合约代码和存储。其他时候只转移余额。

### 实战：底层调用模式

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract SystemExamples {
    /// @notice 使用 assembly 进行底层 CALL
    function lowLevelCall(address target, bytes calldata data)
        external payable returns (bool success, bytes memory returnData)
    {
        assembly {
            // 将 calldata 复制到内存
            let ptr := mload(0x40)
            calldatacopy(ptr, data.offset, data.length)

            // CALL(gas, addr, value, argsOffset, argsLength, retOffset, retLength)
            success := call(gas(), target, callvalue(), ptr, data.length, 0, 0)

            // 获取返回数据
            let retSize := returndatasize()
            returnData := mload(0x40)
            mstore(returnData, retSize)
            returndatacopy(add(returnData, 32), 0, retSize)
            mstore(0x40, add(add(returnData, 32), retSize))
        }
    }

    /// @notice CREATE2: 可预测地址的合约部署
    function deployWithCreate2(bytes memory bytecode, bytes32 salt)
        external returns (address deployed)
    {
        assembly {
            deployed := create2(
                0,                      // value (ETH)
                add(bytecode, 0x20),    // bytecode 起始位置（跳过 length 前缀）
                mload(bytecode),        // bytecode 长度
                salt                    // salt
            )
            if iszero(deployed) { revert(0, 0) }
        }
    }

    /// @notice 预计算 CREATE2 地址
    function predictAddress(
        address deployer,
        bytes32 salt,
        bytes32 bytecodeHash
    ) external pure returns (address predicted) {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), bytecodeHash)
            predicted := and(
                keccak256(ptr, 85),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }
    }

    /// @notice DELEGATECALL: 代理模式的核心
    /// 这是 OpenZeppelin 的 Proxy 合约核心逻辑
    fallback() external payable {
        address impl = address(0); // 实际项目从 EIP-1967 slot 读取

        assembly {
            // 复制完整的 calldata
            calldatacopy(0, 0, calldatasize())

            // delegatecall 到实现合约
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)

            // 复制返回数据
            returndatacopy(0, 0, returndatasize())

            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
```

---

## 第十三章：Gas 机制深入

### 13.1 Gas 成本分类

```
总 Gas = Intrinsic Gas + Execution Gas

Intrinsic Gas:
  = 21000                        (基础交易)
  + 32000                        (如果创建合约)
  + Σ(calldata_zero_bytes) * 4   (零字节)
  + Σ(calldata_nonzero_bytes) * 16  (非零字节)

Execution Gas:
  = Σ(opcode_fixed_cost)         (每条指令的固定成本)
  + Σ(opcode_dynamic_cost)       (内存扩展、cold/warm 等)
```

### 13.2 冷/热访问（Cold/Warm Access）

Berlin 硬分叉（EIP-2929）引入了访问列表机制：

| 操作                         | Cold (首次访问) | Warm (后续访问) |
| ---------------------------- | --------------- | --------------- |
| SLOAD                        | 2100            | 100             |
| SSTORE                       | 见上表          | 见上表          |
| BALANCE                      | 2600            | 100             |
| EXTCODESIZE                  | 2600            | 100             |
| EXTCODECOPY                  | 2600            | 100             |
| EXTCODEHASH                  | 2600            | 100             |
| CALL/STATICCALL/DELEGATECALL | 2600            | 100             |

> 每笔交易开始时，sender、to 地址和预编译合约地址已经是 warm 的。 上海分叉后 COINBASE 地址也默认 warm。

### 13.3 内存扩展成本

```
word_count = ceil(byte_size / 32)
cost = (word_count² / 512) + (3 * word_count)
```

示例：
| 内存大小 | 字长 | 成本 |
|---------|------|------|
| 32 bytes | 1 | 3 |
| 64 bytes | 2 | 6 |
| 256 bytes | 8 | 24 |
| 1 KB | 32 | 98 |
| 1 MB | 32768 | 2,097,252 |
| 10 MB | 327680 | 209,715,480 |

> 超过几 KB 后成本急剧增长！这是 EVM 故意设计的，防止内存滥用。

### 13.4 Gas 退款

- 仅 SSTORE 可触发退款（将非零值设为零，退 4800 gas）
- 退款上限为交易总 Gas 的 **1/5**（London 硬分叉后）
- SELFDESTRUCT 不再提供退款（London 硬分叉后）

---

## 第十四章：实战案例

### 14.1 EIP-1167 最小代理合约（逐字节解析）

最小代理的运行时字节码（经典版本，45 字节）：

```
363d3d373d3d3d363d73bebebebebebebebebebebebebebebebebebebebe5af43d82803e903d91602b57fd5bf3
```

逐条指令拆解：

```
                          // ======== 复制 calldata 到内存 ========
36        CALLDATASIZE      // [cds]                 — calldata 大小
3d        RETURNDATASIZE    // [0, cds]              — 推入 0 (技巧!)
3d        RETURNDATASIZE    // [0, 0, cds]
37        CALLDATACOPY      // []                     — memory[0:cds] = calldata

                          // ======== DELEGATECALL 到实现合约 ========
3d        RETURNDATASIZE    // [0]                   — retSize = 0 (暂时)
3d        RETURNDATASIZE    // [0, 0]                — retOffset = 0
3d        RETURNDATASIZE    // [0, 0, 0]             — argsLength （但被覆盖）
36        CALLDATASIZE      // [cds, 0, 0, 0]        — argsLength = cds
3d        RETURNDATASIZE    // [0, cds, 0, 0, 0]     — argsOffset = 0
73 be..be PUSH20 <impl>     // [impl, 0, cds, 0, 0, 0]
5a        GAS               // [gas, impl, 0, cds, 0, 0, 0]
f4        DELEGATECALL      // [success]
           // delegatecall(gas, impl, 0, cds, 0, 0)

                          // ======== 复制返回数据 ========
3d        RETURNDATASIZE    // [rds, success]
82        DUP3              // [0, rds, success]     — retOffset
80        DUP1              // [0, 0, rds, success]  — destOffset
3e        RETURNDATACOPY    // [success]              — memory[0:rds] = returndata

                          // ======== 根据结果返回或回滚 ========
90        SWAP1             // [success]  (整理栈)
3d        RETURNDATASIZE    // [rds, success]
91        SWAP2             // [success, ?, rds]
602b      PUSH1 0x2b        // [0x2b, success, ?, rds]  — 跳转目标
57        JUMPI             // [?, rds]   — if success != 0 goto 0x2b
fd        REVERT            // revert(0, rds)
5b        JUMPDEST          // 0x2b: 成功分支
f3        RETURN            // return(0, rds)
```

> **关键技巧**：`RETURNDATASIZE (0x3d)` 在未调用外部函数时返回 0，只需 2 gas，比 `PUSH1 0 (0x60 0x00)` 省 1 gas 且少 1 字节。

### 14.2 Clone0 变体（PUSH0 版，44 字节）

```
365f5f375f5f365f73bebebebebebebebebebebebebebebebebebebebe5af43d5f5f3e5f3d91602a57fd5bf3
```

变化点：所有 `RETURNDATASIZE (0x3d)` 替换为 `PUSH0 (0x5f)`，直接用 1 字节 + 2 gas 推入 0。Shanghai 升级后可用。

### 14.3 ABI 编码/解码

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract ABIExamples {
    /// @notice 手动解析 function selector + 参数
    /// Calldata 格式: [4字节selector][32字节参数1][32字节参数2]...
    function manualDecode() external pure returns (
        bytes4 selector,
        uint256 param1,
        address param2
    ) {
        assembly {
            // 函数选择器 = calldata 的前 4 字节
            selector := calldataload(0)  // 加载 32 字节，selector 在最高 4 字节

            // 第一个参数从 offset 4 开始
            param1 := calldataload(4)

            // 第二个参数从 offset 36 开始
            // address 是 20 字节，存在 32 字节的低 20 字节
            param2 := calldataload(36)
        }
    }

    /// @notice 手动编码 CALL 的 calldata
    function manualEncode(address target) external returns (bool success) {
        assembly {
            let ptr := mload(0x40)

            // 编码: transfer(address,uint256) → 0xa9059cbb
            mstore(ptr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)

            // 参数1: address (左填充0到32字节)
            mstore(add(ptr, 4), shl(96, target))

            // 参数2: uint256 amount = 1000
            mstore(add(ptr, 36), 1000)

            // 总长度: 4 + 32 + 32 = 68
            success := call(gas(), target, 0, ptr, 68, 0, 0)
        }
    }

    /// @notice 函数选择器的计算
    /// selector = bytes4(keccak256("functionName(type1,type2)"))
    function computeSelector() external pure returns (bytes4) {
        return bytes4(keccak256("transfer(address,uint256)"));
        // = 0xa9059cbb
    }
}
```

### 14.4 存储布局探索

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract StorageLayout {
    // Slot 0
    uint256 public value1 = 100;

    // Slot 1 (三个变量共享一个 slot，因为 8+8+16 = 32 字节)
    uint64 public a = 1;      // slot 1, offset 0, 8 字节
    uint64 public b = 2;      // slot 1, offset 8, 8 字节
    uint128 public c = 3;     // slot 1, offset 16, 16 字节

    // Slot 2: mapping
    mapping(address => uint256) public balances;
    // balances[key] 存储在 keccak256(abi.encode(key, 2))

    // Slot 3: dynamic array
    uint256[] public arr;
    // arr.length 存储在 slot 3
    // arr[i] 存储在 keccak256(3) + i

    // Slot 4: string/bytes
    string public name = "hello";
    // ≤ 31 字节: 直接存在 slot 4 中（最低字节存长度*2）
    // > 31 字节: slot 4 存长度*2+1，数据存在 keccak256(4) 起始的 slots

    /// @notice 使用 assembly 读取打包的 slot
    function readPackedSlot1() external view returns (uint64 _a, uint64 _b, uint128 _c) {
        assembly {
            let packed := sload(1)
            _a := and(packed, 0xffffffffffffffff)
            _b := and(shr(64, packed), 0xffffffffffffffff)
            _c := and(shr(128, packed), 0xffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice 使用 assembly 读取 mapping 值
    function readMapping(address key) external view returns (uint256 bal) {
        assembly {
            mstore(0x00, key)
            mstore(0x20, 2)     // mapping 的 slot 号
            bal := sload(keccak256(0x00, 0x40))
        }
    }

    /// @notice 使用 assembly 读取动态数组元素
    function readArray(uint256 index) external view returns (uint256 val) {
        assembly {
            mstore(0x00, 3)     // array 的 slot 号
            val := sload(add(keccak256(0x00, 0x20), index))
        }
    }
}
```

### 14.5 ERC20 Transfer 的底层实探

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice 极简 ERC20 transfer 的底层实现
/// 理解 EVM 中的每一步操作
contract MiniERC20 {
    // slot 0: mapping(address => uint256) balanceOf
    mapping(address => uint256) public balanceOf;

    // Transfer(address indexed from, address indexed to, uint256 value)
    bytes32 constant TRANSFER_SIG = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    function transfer(address to, uint256 amount) external returns (bool) {
        assembly {
            // 1. 计算 sender 的余额 slot
            mstore(0x00, caller())
            mstore(0x20, 0)   // balanceOf 在 slot 0
            let senderSlot := keccak256(0x00, 0x40)
            let senderBal := sload(senderSlot)

            // 2. 检查余额
            if lt(senderBal, amount) {
                // revert InsufficientBalance()
                mstore(0x00, 0)
                revert(0x00, 0x04)
            }

            // 3. 扣减 sender 余额
            sstore(senderSlot, sub(senderBal, amount))

            // 4. 计算 to 的余额 slot
            mstore(0x00, to)
            // 0x20 仍然是 0
            let toSlot := keccak256(0x00, 0x40)
            let toBal := sload(toSlot)

            // 5. 增加 to 余额
            sstore(toSlot, add(toBal, amount))

            // 6. emit Transfer(caller(), to, amount)
            mstore(0x00, amount)
            log3(0x00, 0x20, TRANSFER_SIG, caller(), to)

            // 7. return true
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }
}
```

---

## 第十五章：Gas 优化技巧

### 15.1 Calldata vs Memory

```solidity
// ❌ 昂贵：将 calldata 复制到 memory
function bad(uint256[] memory data) external { /* ... */ }

// ✅ 便宜：直接从 calldata 读取
function good(uint256[] calldata data) external { /* ... */ }
// 差别：省去 CALLDATACOPY 和内存分配的 Gas
```

### 15.2 Storage 优化

```solidity
// ❌ 多次读取 storage
function bad(uint256 id) external view returns (uint256) {
    return balances[id] + balances[id] * rates[id];
}

// ✅ 缓存到 memory
function good(uint256 id) external view returns (uint256) {
    uint256 bal = balances[id];    // 1 次 SLOAD
    uint256 rate = rates[id];     // 1 次 SLOAD
    return bal + bal * rate;       // 内存操作
}

// ❌ 不使用 packing
contract Bad {
    uint8 a;      // slot 0
    uint256 b;    // slot 1 （b 太大，无法与 a 共享）
    uint8 c;      // slot 2
    // 共 3 个 slot
}

// ✅ 使用 packing
contract Good {
    uint8 a;      // slot 0, offset 0
    uint8 c;      // slot 0, offset 1  （与 a 共享 slot）
    uint256 b;    // slot 1
    // 共 2 个 slot
}
```

### 15.3 短路求值与 ISZERO

```solidity
// require(a != 0) 编译为:
// ISZERO(a) → JUMPI → REVERT
// ISZERO 只需 3 gas，比 EQ(a, 0) + PUSH1 的组合更紧凑
```

### 15.4 常量与不可变量

```solidity
// 普通 storage 变量: SLOAD = 2100 gas (cold)
uint256 public normalVar = 42;

// constant: 编译时替换到字节码中，0 gas（只是 PUSH）
uint256 public constant CONST_VAR = 42;

// immutable: 部署时存入字节码中，0 gas（只是 PUSH）
uint256 public immutable IMMUTABLE_VAR;
constructor() { IMMUTABLE_VAR = 42; }
```

### 15.5 自定义错误 vs 字符串

```solidity
// ❌ 字符串 revert: 大量 MSTORE 操作 + 存储字符串
require(x > 0, "Value must be positive");

// ✅ 自定义错误: 仅存储 4 字节选择器
error ValueMustBePositive();
if (x == 0) revert ValueMustBePositive();
// 节省约 200+ gas（部署 + 运行时）
```

### 15.6 unchecked 算术

```solidity
// 默认: 每次加减乘除都有溢出检查 (额外 ~40 gas)
for (uint256 i = 0; i < arr.length; i++) { /* ... */ }

// ✅ 当确定不会溢出时使用 unchecked
for (uint256 i = 0; i < arr.length; ) {
    // ...
    unchecked { ++i; }  // 省掉溢出检查的 gas
}
```

### 15.7 PUSH0 的使用（Shanghai+）

```solidity
// 在 Shanghai 之前：PUSH1 0x00 = 0x6000 (2 字节, 3 gas)
// 在 Shanghai 之后：PUSH0 = 0x5f (1 字节, 2 gas)
// 编译器在 Shanghai+ 目标下自动使用 PUSH0
// 确保 foundry.toml 中 evm_version >= "shanghai"
```

---

## 附录：参考资源

### 在线工具

| 工具           | 链接                             | 用途                       |
| -------------- | -------------------------------- | -------------------------- |
| evm.codes      | https://www.evm.codes/           | 操作码参考与 Playground    |
| Remix IDE      | https://remix.ethereum.org/      | 在线 Solidity IDE + 调试器 |
| Tenderly       | https://tenderly.co/             | 交易模拟与调试             |
| Etherscan      | https://etherscan.io/opcode-tool | 字节码反汇编               |
| EVM Playground | https://www.evm.codes/playground | 在线 EVM 执行              |

### 推荐阅读

- [Ethereum EVM Illustrated (2018)](https://takenobu-hs.github.io/downloads/ethereum_evm_illustrated.pdf) — 最好的 EVM 可视化入门
- [EVM Deep Dives by noxx](https://noxx.substack.com/p/evm-deep-dives-the-path-to-shadowy) — 深入 EVM 的系列文章
- [The EVM Handbook](https://noxx.substack.com/p/evm-deep-dives-the-path-to-shadowy-3ea) — 全面的 EVM 资源合集
- [Mastering Ethereum - EVM Chapter](https://github.com/ethereumbook/ethereumbook/blob/develop/13evm.asciidoc) — 经典教材
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf) — EVM 的形式化规范
- [EIP 列表](https://eips.ethereum.org/) — 所有以太坊改进提案

### 硬分叉与新增操作码时间线

| 硬分叉           | 时间    | 新增/修改的操作码                                                 |
| ---------------- | ------- | ----------------------------------------------------------------- |
| Homestead        | 2016.3  | DELEGATECALL                                                      |
| Byzantium        | 2017.10 | STATICCALL, RETURNDATASIZE, RETURNDATACOPY, REVERT                |
| Constantinople   | 2019.2  | SHL, SHR, SAR, EXTCODEHASH, CREATE2                               |
| Istanbul         | 2019.12 | CHAINID, SELFBALANCE，calldata gas 降低                           |
| Berlin           | 2021.4  | 访问列表 (EIP-2929)，cold/warm gas 差异                           |
| London           | 2021.8  | BASEFEE，gas 退款上限降至 1/5                                     |
| Paris (Merge)    | 2022.9  | DIFFICULTY → PREVRANDAO                                           |
| Shanghai         | 2023.4  | PUSH0 (EIP-3855)                                                  |
| Cancun           | 2024.3  | TSTORE, TLOAD (EIP-1153), BLOBHASH, BLOBBASEFEE, MCOPY (EIP-5656) |
| Osaka (upcoming) | TBD     | EOF (EVM Object Format) 等                                        |

### MCOPY（EIP-5656, Cancun）

| Opcode | 助记符 | Gas                | 栈输入         | 描述         |
| ------ | ------ | ------------------ | -------------- | ------------ |
| 0x5E   | MCOPY  | 3 + 3\*字长 + 扩展 | dst, src, size | 高效内存复制 |

```solidity
// Cancun 之前的内存复制需要循环 MLOAD/MSTORE
// 现在一条指令完成
assembly {
    mcopy(dest, src, length)
}
```

---

> 📝 本文档基于 [evm.codes](https://www.evm.codes/) 并结合实际开发经验整理。
> 操作码的具体 Gas 消耗可能随硬分叉更新，请以 evm.codes 上的最新信息为准。
