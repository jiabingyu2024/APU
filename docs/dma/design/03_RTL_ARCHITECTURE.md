# RTL Architecture

本文解释 `dma/rtl/` 下的 RTL 设计。阅读目标是理解每个模块负责什么，而不是逐行背代码。

## 1. Top-Level View

顶层模块是：

```text
dma/rtl/apu_dma_top.sv
```

它对外暴露三类接口：

```text
S_AXIS_JOB      输入 job stream，由 AXI DMA MM2S 送来
M_AXIS_RESULT   输出 response stream，送给 AXI DMA S2MM
S_AXI_CTRL      AXI-Lite 控制和状态寄存器
irq             job done/error 中断输出
```

内部模块连接如下：

```text
S_AXIS_JOB
  |
  v
axis_job_decoder
  | cmd
  | payload
  v
apu_job_ctrl ---------> apu_stream_loader -------> APU internal RAM write ports
  |                         ^
  | core_start              |
  v                         |
apu_dma_core <--------------+
  |
  | host read data
  v
axis_result_streamer
  |
  v
M_AXIS_RESULT

apu_dma_perf_counters -> apu_dma_axil_regs -> S_AXI_CTRL / irq
```

可以把它分成四条功能线：

1. 输入解析线：`axis_job_decoder`
2. 命令调度线：`apu_job_ctrl`
3. APU 数据和计算线：`apu_stream_loader` + `apu_dma_core`
4. 输出和状态线：`axis_result_streamer` + `apu_dma_axil_regs` + `apu_dma_perf_counters`

## 2. `apu_dma_pkg.sv`

这个 package 定义协议常量：

```text
AXIS_DATA_WIDTH       64
HEADER_BEATS         4
PROTOCOL_VERSION     1
SAFE_INSTRUCTION_LIMIT 15
JOB_MAGIC            "APUJ"
RESPONSE_MAGIC       "APUR"
```

还定义了 opcode、target、response type 和 error status。

为什么要单独放 package：

- RTL 多个模块都要使用相同 opcode/status。
- Python 构包器也要和这些值保持一致。
- 协议字段变化时，有一个权威位置。

关键函数：

```systemverilog
padded_payload_bytes(bytes) = (bytes + 7) & ~7
```

因为 AXI-Stream 是 64-bit，即 8 byte 一拍。payload 真实长度可以不是 8 的倍数，但 DMA 传输 beat 必须补齐到 8 byte 边界。

## 3. `axis_job_decoder.sv`

作用：把输入 AXI-Stream 拆成“命令 header”和“payload stream”。

它不直接写 APU RAM，也不启动 APU，只负责解析和基础协议检查。

### State Machine

```text
ST_HEADER0
ST_HEADER1
ST_HEADER2
ST_HEADER3
ST_COMMAND
ST_PAYLOAD
ST_DRAIN
```

含义：

| 状态 | 功能 |
| --- | --- |
| `ST_HEADER0..3` | 连续接收 4 个 64-bit header beat |
| `ST_COMMAND` | header 已经完整，向 `apu_job_ctrl` 发出 `cmd_valid` |
| `ST_PAYLOAD` | 如果是 LOAD，把后续 payload 透传给 loader |
| `ST_DRAIN` | 出错后丢弃当前 job 剩余数据，直到看到 TLAST |

### Important Handshakes

命令侧：

```text
cmd_valid -> apu_job_ctrl
cmd_ready <- apu_job_ctrl
```

payload 侧：

```text
payload_valid -> apu_stream_loader
payload_ready <- apu_stream_loader
```

AXI-Stream 输入侧：

```text
s_axis_tready = payload_ready when forwarding payload
```

这表示 loader 如果暂时不能写 RAM，decoder 会通过 `TREADY=0` 反压 AXI DMA。

### Protocol Checks

decoder 主要检查：

- header beat 的 `TKEEP` 必须是 `8'hFF`。
- header 不能提前出现 `TLAST`。
- `magic` 必须是 `APUJ`。
- version 必须匹配。
- `END_JOB` 必须带 `TLAST`，且长度字段为 0。
- 非 LOAD 命令不能带 payload。
- LOAD 命令必须带非零 payload。
- payload 最后一拍的 `TKEEP` 要符合真实 payload 长度。

如果错误发生，decoder 输出：

```text
error_valid
error_status
error_sequence_id
error_command_id
```

然后进入 `ST_DRAIN`，把 AXI DMA 继续送来的当前 job 剩余 beat 吃掉，直到 `TLAST`。这样做可以让 AXI DMA 这次传输正常收尾，不会卡在半个 job。

## 4. `apu_stream_loader.sv`

作用：执行 `LOAD` 命令，把 payload 写入 APU 内部存储。

它接收 `apu_job_ctrl` 发来的 load metadata：

```text
load_target
load_address
load_element_count
load_payload_bytes
load_bank
```

然后接收 decoder 透传来的 payload。

### Targets

| target | 输出写端口 |
| --- | --- |
| `ACT` | `act_we/act_waddr/act_wdata` |
| `OUT` | `out_we/out_waddr/out_wdata` |
| `WEIGHT` | `weight_we/weight_bank/weight_waddr/weight_wdata` |
| `BN` | `bn_we/bn_bank/bn_waddr/bn_wdata` |
| `INSTRUCTION` | `instruction_we/instruction_waddr/instruction_wdata` |

### Range and Length Checks

loader 会检查：

```text
ACT/OUT      address + count <= 1024, bank must be 0
WEIGHT       address + count <= 256,  bank < 64
BN           address + count <= 32,   bank < 64
INSTRUCTION  address must be 0, count <= 15, bank must be 0
```

长度检查：

```text
ACT/OUT/WEIGHT: payload_bytes == count * 8
BN/INSTRUCTION: payload_bytes == count * 4
```

### 64-bit and 32-bit Payload

64-bit target：

```text
one AXIS beat -> one RAM word
```

32-bit target：

```text
one AXIS beat low 32  -> first element
one AXIS beat high 32 -> second element
```

所以 loader 有一个 `ST_HIGH32` 状态，用来在下一拍写入刚保存的高 32 位。

### Why Loader Is Separate

如果把 payload 写 RAM 的逻辑塞进 decoder，decoder 会同时承担协议解析、地址检查、RAM 写入和错误恢复，状态机会很乱。

现在拆开后：

- decoder 管“输入 stream 格式对不对”。
- loader 管“这个 LOAD 是否能写进目标 RAM”。
- job controller 管“这条命令什么时候开始、什么时候结束、错了怎么回 response”。

## 5. `apu_job_ctrl.sv`

这是 DMA RTL 的主状态机。它决定每条命令应该怎么执行。

### State Machine

```text
ST_IDLE
ST_LOAD_START
ST_LOAD_WAIT
ST_RUN_START
ST_RUN_WAIT
ST_READ_START
ST_READ_WAIT
ST_FINAL_START
ST_FINAL_WAIT
ST_ERROR_START
ST_ERROR_WAIT
```

核心思路：

- 在 `ST_IDLE` 接收 decoder 给出的命令。
- `LOAD` 进入 loader。
- `RUN` 启动 APU core 并等待完成。
- `READ_RESULT` 启动 result streamer。
- `END_JOB` 发送 final response。
- 任意错误进入 error response。

### Job-Level State

`apu_job_ctrl` 维护 job 的整体状态：

```text
job_busy
active_sequence_id
job_cycle_count
last_error
programmed_instruction_count_q
```

`sequence_id` 的作用是防止两个 job 混在一起。一个 job 开始后，后续命令必须使用相同 `sequence_id`。

### RUN Checks

`RUN` 不是无条件启动。RTL 会检查：

- target 必须是 `TARGET_NONE`。
- payload_bytes 必须为 0。
- address 必须为 0。
- `element_count` 必须等于之前 `LOAD INSTRUCTION` 的条数。
- instruction count 必须在 `1..15`。
- timeout cycles 不能为 0。
- APU core 当前不能 busy。

这些检查很重要，因为原始 `WorkSheet` 最多 16 深度，但安全装载上限设为 15，避免计数回绕风险。

### Error Handling

错误来源有三类：

1. decoder 报协议错误。
2. loader 报地址/长度/target 错误。
3. job controller 自己发现 RUN/READ_RESULT/sequence 等逻辑错误。

出错时：

```text
进入 ST_ERROR_START
启动 axis_result_streamer 发送 ERROR response
必要时 decoder_abort/core_abort
job_error_pulse 拉高一拍
job_busy 清零
```

这样 Python 端能明确收到错误，而不是一直等待 DMA 或硬件完成。

## 6. `apu_dma_core.sv`

这个模块是 DMA wrapper 和原始 APU RTL 的交界处。它没有重写卷积计算，而是实例化了原来的模块：

```text
WorkSheet
Ctrl
InBuf
FeatureProcessor x2
ComputeCoreGroup
SIMD
```

### What It Adds

相对于原始 APU，`apu_dma_core` 增加了三类外部端口：

1. DMA loader 写端口：

```text
act_we/out_we/weight_we/bn_we/instruction_we
```

2. DMA job controller 启动/中止：

```text
core_start
core_abort
core_busy
core_done
```

3. result streamer 读端口：

```text
host_rd_req
host_rd_target
host_rd_addr
host_rd_valid
host_rd_data
```

### ACT and OUT SRAM Arbitration

ACT/OUT SRAM 同时可能被两方访问：

- loader 写入输入或中间数据。
- APU 计算过程中读写 feature。
- result streamer 读结果。

当前设计用组合选择实现简单仲裁：

```text
write side:
  if loader writes, use loader address/data
  else use APU compute writeback

read side:
  if host/result streamer reads, use host address and 1x1 parameters
  else use Ctrl generated read window
```

这里没有复杂多主仲裁，因为 job controller 的命令顺序保证：

- LOAD 阶段不会同时 RUN。
- READ_RESULT 阶段发生在 RUN 完成后。

所以 loader/host read 和 APU compute 不应该在同一个阶段争抢同一 RAM 操作。

### Reset and Abort

```systemverilog
control_resetn = aresetn && !core_abort;
```

`core_abort` 会让 `WorkSheet/Ctrl/InBuf/ComputeCoreGroup` 等控制相关模块复位，避免 timeout 或错误后 APU 卡在中间状态。

注意 `FeatureProcessor` 和 `SIMD` 的 reset 仍接 `aresetn`，因为权重、BN、feature RAM 内容在错误恢复时不一定需要全部清空；job 协议会重新装载所需内容。

## 7. `axis_result_streamer.sv`

作用：把 `READ_RESULT` 或 `FINAL/ERROR` 变成 AXI-Stream response。

### State Machine

```text
ST_IDLE
ST_HEADER0
ST_HEADER1
ST_HEADER2
ST_HEADER3
ST_READ_ISSUE
ST_READ_WAIT
ST_DATA
```

对于 `FINAL` 和 `ERROR`：

```text
只发 4-beat header
count = 0
如果 terminate=1，则 header3 同时 TLAST=1
```

对于 `DATA`：

```text
发 4-beat header
循环读 host RAM
每读到一个 64-bit word，就发一个 data beat
最后一个 data beat 根据 terminate 决定是否 TLAST
```

在本项目中，通常 `DATA` response 后还会有 `FINAL` response，所以 `DATA` 不一定带 TLAST；`FINAL` 才终止整个 S2MM stream。

## 8. `apu_dma_axil_regs.sv`

这是 `apu_dma` 自定义 IP 的 AXI-Lite 寄存器模块。

它负责：

- 让 PS 读取 IP ID、版本、busy 状态、错误码。
- 让 PS 读取性能计数器。
- 让 PS 使能/清除 `job_done` 和 `job_error` 中断。
- 输出 `irq` 给 block design 中的 interrupt controller。

AXI-Lite 写通道在这个模块里被简化处理：

- 分别接收 AW 和 W。
- 两者都到齐后执行写。
- 返回 OKAY response。

读通道：

- AR 到来后根据地址组合选择 `read_data`。
- 下一拍通过 R channel 返回。

## 9. `apu_dma_perf_counters.sv`

该模块不影响功能，只统计性能：

| 计数器 | 含义 |
| --- | --- |
| `rx_bytes` | S_AXIS_JOB 成功接收的字节数 |
| `tx_bytes` | M_AXIS_RESULT 成功发送的字节数 |
| `busy_cycles` | job_busy 为 1 的周期数 |
| `mm2s_stall_cycles` | 输入方向 `TVALID=1,TREADY=0` 的周期数 |
| `s2mm_stall_cycles` | 输出方向 `TVALID=1,TREADY=0` 的周期数 |
| `completed_jobs` | 正常完成 job 数 |
| `error_jobs` | 错误 job 数 |

`hardware_mbps_mean` 就是根据这些硬件周期和你传入的 `--clock-mhz` 算出来的。因此 `--clock-mhz` 必须和 bitstream 实际频率一致。

## 10. Important Design Boundaries

### Boundary 1: AXI DMA IP vs Custom RTL

Xilinx AXI DMA IP 只负责 DDR 和 AXI-Stream 之间搬运。它不知道 APU 的 ACT/WEIGHT/BN，也不知道 RUN/READ_RESULT 的含义。

这些含义全部由自定义 `apu_dma` IP 的 packet protocol 实现。

### Boundary 2: Packet Protocol vs APU Core

packet protocol 是 DMA wrapper 的控制语言。原始 APU core 仍然只认识：

- instruction RAM
- feature RAM
- weight SRAM
- BN/SIMD 参数
- start/done 控制

`apu_dma_core` 的责任就是把 packet 里的 LOAD/RUN/READ_RESULT 翻译成原始 APU 能理解的 RAM 写入和启动信号。

### Boundary 3: Function vs Performance

功能正确依赖：

- decoder/loader/job_ctrl 正确解释 packet。
- APU core 和原始 MMIO/golden 对齐。
- result streamer 返回正确输出。

性能依赖：

- AXI DMA burst 能跑起来。
- AXIS FIFO 不频繁阻塞。
- Python 不在每次迭代里做高开销 buffer 分配。
- 中断等待可用，不使用 polling 忙等。

## 11. Suggested Code Reading Order

建议按这个顺序看源码：

1. `apu_dma_pkg.sv`
2. `apu_dma_top.sv`
3. `axis_job_decoder.sv`
4. `apu_job_ctrl.sv`
5. `apu_stream_loader.sv`
6. `apu_dma_core.sv`
7. `axis_result_streamer.sv`
8. `apu_dma_axil_regs.sv`
9. `apu_dma_perf_counters.sv`

不要一开始就读 `apu_dma_core.sv`，因为它会把 DMA wrapper 和原始 APU 模块混在一起；先理解 packet 和 job 状态机会更清楚。
