# 阶段 C：DMA Stream Job Packet 协议

## 1. 协议目标

一个MM2S DMA传输承载一个完整job。job由多个packet连续组成，最后必须是`END_JOB`：

```text
LOAD input
LOAD weight bank 0..63
LOAD BN bank 0..63
LOAD instruction
RUN
...
READ_RESULT
END_JOB + TLAST
```

AXI-Stream为64 bit。包头固定32字节，payload按8字节补零。只有整个job最后一个beat拉高
`TLAST`，packet边界由包头的`payload_bytes`确定。

## 2. 端序

- AXI beat为`TDATA[63:0]`；
- PS/PYNQ内存按little-endian解释；
- 一个64-bit RAM word直接占一个beat；
- 32-bit payload在beat内先放低32位，再放高32位；
- `payload_bytes`不包含对齐补零；
- DMA传输总长度必须是8字节整数倍。

## 3. 固定包头

| Beat | 位段 | 字段 | 说明 |
|---:|---:|---|---|
| 0 | `31:0` | `magic` | Job=`0x4A555041`，内存字节为`APUJ` |
| 0 | `39:32` | `version` | 当前为1 |
| 0 | `47:40` | `opcode` | 命令类型 |
| 0 | `55:48` | `target` | RAM/数据目标 |
| 0 | `63:56` | `flags` | 当前必须为0，保留扩展 |
| 1 | `31:0` | `sequence_id` | 整个job的编号 |
| 1 | `63:32` | `payload_bytes` | 实际payload字节数，不含padding |
| 2 | `31:0` | `address` | 目标RAM原生word索引 |
| 2 | `63:32` | `element_count` | 原生word数量或RUN指令数 |
| 3 | `31:0` | `arg0` | bank或timeout_cycles |
| 3 | `63:32` | `command_id` | job内从0递增的命令编号 |

## 4. Opcode

| 值 | 名称 | payload | 行为 |
|---:|---|---|---|
| `0x00` | `NOP` | 0 | 保留测试 |
| `0x01` | `LOAD` | 有 | 将payload写入目标RAM |
| `0x02` | `RUN` | 0 | 启动已装载的worksheet |
| `0x03` | `READ_RESULT` | 0 | 请求通过S2MM返回RAM数据 |
| `0xFF` | `END_JOB` | 0 | job结束，必须对应输入TLAST |

## 5. Target与地址单位

| 值 | Target | 原生元素 | `address`单位 | bank |
|---:|---|---:|---|---|
| `0x00` | `ACT` | 64 bit | 64-bit word | 必须0 |
| `0x01` | `OUT` | 64 bit | 64-bit word | 必须0 |
| `0x02` | `WEIGHT` | 64 bit | 64-bit word | `0..63` |
| `0x03` | `BN` | 32 bit | 32-bit word | `0..63`，仅低13位有效 |
| `0x04` | `INSTRUCTION` | 32 bit | 32-bit word | 必须0 |
| `0xFF` | `NONE` | 无 | 无 | 无 |

这消除了旧接口中`w_addr*8`、`bn_addr*4`和MMIO byte offset混用的问题。packet中的address
永远是目标RAM的原生word index，不是byte address，也不是`0x43C00000`绝对地址。

## 6. 各命令约束

### LOAD

```text
payload_bytes = element_count * target_element_bytes
arg0          = bank
```

64-bit目标payload无需重排。32-bit目标按little-endian连续排列，奇数个元素时最后beat高32位
填0，但`payload_bytes`仍是`count*4`。

### RUN

```text
target        = NONE
payload_bytes = 0
address       = 0
element_count = instruction_count (1..15)
arg0          = timeout_cycles
```

当前 `WorkSheet` 的安全装载上限是15条；16条会触发原模块计数宽度的回绕风险，因此软硬件
都拒绝16。硬件检查实际装载的worksheet条数与`instruction_count`一致，然后产生一次单周期start。超时后
返回`APU_TIMEOUT`并进入错误恢复，而不是永久保持busy。

### READ_RESULT

```text
target        = ACT或OUT
payload_bytes = 0
address       = 起始64-bit word
element_count = 返回的64-bit word数
arg0          = 0
```

最终`1x256x8x8`二值特征图为16384 bit，即256个64-bit word、2048字节。旧驱动以512个
32-bit word读取，两者字节数相同。

### END_JOB

所有长度和地址字段必须为0。该包header的最后一个beat必须同时看到输入`TLAST=1`。过早或
缺失TLAST分别报告`TLAST_EARLY`或`TLAST_MISSING`。

## 7. S2MM响应包

响应也使用相同32字节头布局，但：

- `magic=0x52555041`，内存字节为`APUR`；
- header中的`opcode`字段解释为response type；
- `target/address/element_count`描述返回数据；
- `flags`字段解释为status；
- `arg0`保存该命令或job的硬件周期数；
- `command_id`指向触发响应的输入命令。

Response type：

| 值 | 名称 | 说明 |
|---:|---|---|
| `0x01` | `DATA` | `READ_RESULT`返回的数据包 |
| `0x02` | `FINAL` | `END_JOB`最终状态，无payload |
| `0xFF` | `ERROR` | 错误状态，无payload并终止当前job |

## 8. 错误码

| 值 | 名称 | 典型原因 |
|---:|---|---|
| `00` | `OK` | 正常 |
| `01` | `BAD_MAGIC` | 包头错位/软件版本错误 |
| `02` | `BAD_VERSION` | 协议版本不兼容 |
| `03` | `BAD_OPCODE` | 未定义命令 |
| `04` | `BAD_TARGET` | target与opcode不匹配 |
| `05` | `BAD_LENGTH` | payload和element_count不一致 |
| `06` | `BAD_ALIGNMENT` | job或packet未8字节对齐 |
| `07` | `ADDRESS_RANGE` | RAM地址越界 |
| `08` | `BANK_RANGE` | weight/BN bank越界 |
| `09` | `TLAST_EARLY` | job未到END就结束 |
| `0A` | `TLAST_MISSING` | END header结束但没有TLAST |
| `0B` | `RUN_WITHOUT_PROGRAM` | worksheet未正确装载 |
| `0C` | `APU_TIMEOUT` | 计算未在限定周期完成 |
| `0D` | `BUSY` | 前一job尚未恢复 |
| `7F` | `INTERNAL` | 内部不变量失败 |

## 9. 协议权威文件

| 文件 | 用途 |
|---|---|
| `dma/rtl/apu_dma_pkg.sv` | RTL常量、枚举和对齐函数 |
| `dma/pynq/dma_job.py` | PC/PYNQ原位构包和离线解析 |
| `dma/tests/test_dma_job.py` | Python协议一致性测试 |
| `dma/tools/build_job_image.py` | 生成确定性示例binary |
| `dma/tools/decode_job_image.py` | 解码binary并检查packet边界 |

任何字段调整必须同时更新这五处和本文档，并增加protocol version；不能只改驱动或RTL一侧。

## 10. 阶段通过条件

- 固定header、opcode、target、地址单位和错误码；
- Python构包器直接写可写`np.uint64` view，不创建bytes中间job；
- 奇数个32-bit payload、容量越界、尾随数据均有测试；
- 示例job可生成并被独立工具解码；
- 后续RTL decoder严格以`apu_dma_pkg.sv`为准。
