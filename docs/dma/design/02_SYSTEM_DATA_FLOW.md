# System Data Flow

本文从一条完整 job 的角度解释数据怎么走。先看整体，再看 RTL 和 block design 会容易很多。

## 1. End-to-End Path

```text
Python
  |
  | 1. build job words in CMA/DDR buffer
  v
AXI DMA MM2S
  |
  | 2. AXI-Stream job beats
  v
axis_fifo_job
  |
  v
apu_dma custom IP
  |
  | 3. decode packets
  | 4. load APU RAMs
  | 5. start original APU core
  | 6. read result RAM
  v
axis_fifo_result
  |
  | 7. AXI-Stream response beats
  v
AXI DMA S2MM
  |
  | 8. write response buffer in DDR
  v
Python parses response
```

本项目的 DMA job 不是裸数据流，而是一个带命令格式的流。原因是 APU 不只是接收一块输入图像，它还要接收权重、BN 参数、指令，然后启动计算，最后读回输出。

## 2. Job Packet Sequence

一次完整网络推理大致由这些命令组成：

```text
LOAD ACT input
LOAD WEIGHT bank 0
LOAD WEIGHT bank 1
...
LOAD BN bank 0
LOAD BN bank 1
...
LOAD INSTRUCTION
RUN
READ_RESULT
END_JOB
```

每条命令都有 4 个 64-bit beat 的 header。`LOAD` 后面还有 payload。`RUN`、`READ_RESULT`、`END_JOB` 没有 payload。

## 3. Packet Header

每个 packet header 固定 4 beat：

```text
beat 0:
  [31:0]  magic
  [39:32] version
  [47:40] opcode
  [55:48] target
  [63:56] flags

beat 1:
  [31:0]  sequence_id
  [63:32] payload_bytes

beat 2:
  [31:0]  address
  [63:32] element_count

beat 3:
  [31:0]  arg0
  [63:32] command_id
```

几个容易混淆的字段：

- `sequence_id`：整个 job 的编号，同一个 job 里所有 packet 一致。
- `command_id`：job 内部每条命令递增编号，用来定位错误。
- `address`：目标 RAM 的 word index，不是 AXI 地址，也不是 `0x43C00000`。
- `arg0`：对 `LOAD WEIGHT/BN` 来说是 bank；对 `RUN` 来说是 timeout cycles。

## 4. LOAD How Data Enters APU

`LOAD` 的 target 决定 payload 写到哪里：

| target | 写入位置 | 元素大小 | 地址单位 |
| --- | --- | --- | --- |
| `ACT` | APU Act SRAM | 64 bit | 64-bit word |
| `OUT` | APU Out SRAM | 64 bit | 64-bit word |
| `WEIGHT` | APU Weight SRAM bank | 64 bit | 64-bit word |
| `BN` | SIMD/BN 参数 bank | 32 bit, low 13 bits used | 32-bit word |
| `INSTRUCTION` | WorkSheet instruction RAM | 32 bit | 32-bit word |

64-bit 目标最简单：一个 AXIS beat 就是一个 RAM word。

32-bit 目标稍微特殊：一个 64-bit beat 里可以放两个 32-bit 元素，低 32 位先写，再写高 32 位。

## 5. RUN How APU Starts

`RUN` packet 不带 payload。它告诉 `apu_job_ctrl`：

```text
已经装载 instruction_count 条指令
现在启动原始 APU core
最多等待 timeout_cycles
```

RTL 会检查：

- target 必须是 `NONE`。
- payload 必须为 0。
- instruction_count 必须和刚才 `LOAD INSTRUCTION` 的条数一致。
- instruction_count 不能超过 15。
- APU core 当前不能 busy。

通过检查后，`apu_dma_core` 给原始 `WorkSheet` 一个 `core_start` 脉冲，相当于旧 MMIO 方案里的“启动 APU”。

## 6. READ_RESULT How Data Comes Back

`READ_RESULT` 不带 payload。它告诉 RTL：

```text
从 ACT 或 OUT RAM 的某个 address 开始
读 element_count 个 64-bit word
通过 M_AXIS_RESULT 返回
```

返回的 response 也有 4-beat header，然后跟数据 payload。

```text
DATA response header
DATA response payload
FINAL response header
```

如果中途出错，返回：

```text
ERROR response header
```

## 7. END_JOB and TLAST

`END_JOB` 是整个 job 的最后一条命令。它必须满足：

- target 是 `NONE`。
- payload 是 0。
- address/count/arg0 是 0。
- 这个 header 的最后一个 beat 同时看到 `TLAST=1`。

如果过早看到 `TLAST`，RTL 报 `TLAST_EARLY`。如果 `END_JOB` 没有 `TLAST`，RTL 报 `TLAST_MISSING`。

## 8. Response Path

输出 response 的 header magic 是 `APUR`，输入 job 的 header magic 是 `APUJ`。

Response type：

| type | 含义 |
| --- | --- |
| `DATA` | `READ_RESULT` 产生的数据 |
| `FINAL` | job 正常结束 |
| `ERROR` | job 出错并终止 |

Python driver 会解析 response，确认：

- 是否有 `FINAL`。
- 是否有 `ERROR`。
- `DATA` payload 是否符合期望长度。
- 硬件返回的 result 是否能还原成推理输出。

## 9. Why There Are Two Directions

输入 job 和输出 response 是两个方向：

```text
Input direction:
  DDR job buffer -> AXI DMA MM2S -> apu_dma/S_AXIS_JOB

Output direction:
  apu_dma/M_AXIS_RESULT -> AXI DMA S2MM -> DDR response buffer
```

这就是为什么 Vivado 里 AXI DMA 同时启用了 MM2S 和 S2MM。

## 10. Where Performance Is Measured

主要有三层性能口径：

| 口径 | 来源 | 含义 |
| --- | --- | --- |
| hardware MB/s | `apu_dma_perf_counters` + clock MHz | 只看 RTL busy cycles 下的数据面能力 |
| wall MB/s | Python benchmark wall time | 从 Python 启动 DMA 到完成的真实耗时 |
| application throughput | final test 06 | 包含数据集、预处理、推理调度和解析 |

验收“DMA 传输带宽 >= 200 MB/s”时，主要看 final test 04 的 transport benchmark，而不是 06 的应用级 evaluate。
