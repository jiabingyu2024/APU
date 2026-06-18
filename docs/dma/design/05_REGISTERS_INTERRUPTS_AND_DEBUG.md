# Registers, Interrupts, and Debug

本文解释 `apu_dma` 自定义 IP 的 AXI-Lite 寄存器、中断、性能计数器和常见调试方法。

## 1. Register Address Space

`apu_dma_0/S_AXI_CTRL` 被映射到：

```text
0x43C0_0000
```

下面表格中的 offset 都是相对于 `0x43C0_0000`。

| Offset | 名称 | 读写 | 含义 |
| ---: | --- | --- | --- |
| `0x00` | `IP_ID` | R | 固定 ID，值为 `APUD` |
| `0x04` | `PROTOCOL_VERSION` | R | packet 协议版本 |
| `0x08` | `STATUS` | R | bit0 `job_busy`，bit1 `core_busy` |
| `0x0C` | `LAST_ERROR` | R | 最近一次错误码 |
| `0x10` | `ACTIVE_SEQUENCE_ID` | R | 当前 job 的 sequence id |
| `0x14` | `JOB_CYCLE_COUNT` | R | 当前/最近 job 周期计数 |
| `0x18` | `RX_BYTES_LO` | R | 输入 stream 接收字节低 32 位 |
| `0x1C` | `RX_BYTES_HI` | R | 输入 stream 接收字节高 32 位 |
| `0x20` | `TX_BYTES_LO` | R | 输出 stream 发送字节低 32 位 |
| `0x24` | `TX_BYTES_HI` | R | 输出 stream 发送字节高 32 位 |
| `0x28` | `BUSY_CYCLES_LO` | R | job busy 周期低 32 位 |
| `0x2C` | `BUSY_CYCLES_HI` | R | job busy 周期高 32 位 |
| `0x30` | `MM2S_STALL_LO` | R | 输入方向 stall 周期低 32 位 |
| `0x34` | `MM2S_STALL_HI` | R | 输入方向 stall 周期高 32 位 |
| `0x38` | `S2MM_STALL_LO` | R | 输出方向 stall 周期低 32 位 |
| `0x3C` | `S2MM_STALL_HI` | R | 输出方向 stall 周期高 32 位 |
| `0x40` | `COMPLETED_JOBS_LO` | R | 正常完成 job 数低 32 位 |
| `0x44` | `COMPLETED_JOBS_HI` | R | 正常完成 job 数高 32 位 |
| `0x48` | `ERROR_JOBS_LO` | R | 错误 job 数低 32 位 |
| `0x4C` | `ERROR_JOBS_HI` | R | 错误 job 数高 32 位 |
| `0x50` | `IRQ_STATUS` | R/W1C | bit0 done，bit1 error；写 1 清除 |
| `0x54` | `IRQ_ENABLE` | R/W | bit0 done enable，bit1 error enable |
| `0x58` | `PERF_CLEAR` | W | bit0 写 1 清性能计数器 |

`W1C` 表示 write 1 clear：写 1 清对应状态位，写 0 不影响。

## 2. Interrupt Flow

自定义 IP 内部有两个事件：

```text
job_done_pulse
job_error_pulse
```

它们会置位：

```text
IRQ_STATUS[0] = done
IRQ_STATUS[1] = error
```

如果对应 `IRQ_ENABLE` 位也为 1，则输出：

```text
irq = |(IRQ_STATUS & IRQ_ENABLE)
```

BD 中这一路中断进入：

```text
apu_dma_0/irq -> xlconcat_irq/In2 -> axi_intc_0 -> PS IRQ_F2P
```

Python 等中断时，必须在处理完后清 `IRQ_STATUS`，否则中断会一直保持。

## 3. AXI DMA Interrupts vs APU DMA Interrupt

BD 里有三个中断源：

| 中断源 | 含义 |
| --- | --- |
| `axi_dma_0/mm2s_introut` | DDR -> stream 输入 DMA 完成或错误 |
| `axi_dma_0/s2mm_introut` | stream -> DDR 输出 DMA 完成或错误 |
| `apu_dma_0/irq` | 自定义 APU DMA job done/error |

不要混淆：

- AXI DMA 中断说明 DMA transfer 完成。
- `apu_dma` 中断说明自定义 packet/job 逻辑完成或出错。

最终软件一般既要确保 S2MM 收到了 response，也要确认 response 中有 `FINAL` 而不是 `ERROR`。

## 4. Performance Counters

性能计数器来自 `apu_dma_perf_counters.sv`。

### RX/TX bytes

```text
rx_bytes += number of valid TKEEP bits on S_AXIS_JOB transfer
tx_bytes += number of valid TKEEP bits on M_AXIS_RESULT transfer
```

由于本项目基本使用 64-bit full beat，通常每拍 8 byte。

### Busy cycles

```text
busy_cycles += 1 when job_busy == 1
```

hardware bandwidth 口径通常是：

```text
hardware MB/s = job_bytes / (busy_cycles / clock_hz) / 1e6
```

### Stall cycles

```text
mm2s_stall_cycles += 1 when input TVALID=1 and TREADY=0
s2mm_stall_cycles += 1 when output TVALID=1 and TREADY=0
```

如果 stall 很多，说明流中某一侧跟不上。

常见原因：

- RTL loader/result streamer 正在等待内部 RAM 或状态机。
- AXIS FIFO 太浅。
- S2MM 没及时准备好接收。
- DDR/HP 口或 SmartConnect 产生背压。

## 5. Error Codes

常用错误码：

| 错误 | 典型原因 |
| --- | --- |
| `BAD_MAGIC` | Python 构包错位，或 endian/word view 错 |
| `BAD_VERSION` | Python 和 RTL 协议版本不一致 |
| `BAD_OPCODE` | opcode 未定义 |
| `BAD_TARGET` | 命令和 target 不匹配，例如 RUN target 不是 NONE |
| `BAD_LENGTH` | payload_bytes、element_count、TKEEP、TLAST 不一致 |
| `ADDRESS_RANGE` | 写 RAM 越界 |
| `BANK_RANGE` | weight/BN bank >= 64 |
| `TLAST_EARLY` | job 没结束就出现 TLAST |
| `TLAST_MISSING` | END_JOB 没有 TLAST |
| `RUN_WITHOUT_PROGRAM` | instruction 未正确装载或条数不匹配 |
| `APU_TIMEOUT` | APU core 没在 timeout cycles 内完成 |
| `BUSY` | 上一个 job/核心还没空闲 |

调试时先看 response 中的 error，再看 `LAST_ERROR` 寄存器。

## 6. Debug From Software

推荐顺序：

1. 确认 overlay 加载成功。
2. 读 `IP_ID`，应能识别 `APUD`。
3. 读 `PROTOCOL_VERSION`，确认 Python 和 RTL 匹配。
4. 清性能计数器。
5. 运行 smoke 或 final test 04。
6. 如果失败，读 `LAST_ERROR`、`IRQ_STATUS`、`RX_BYTES`、`TX_BYTES`、stall counters。
7. 解析 response buffer，看是否有 `ERROR` response。

如果 `RX_BYTES` 为 0，说明输入 DMA 或 stream 没进自定义 IP。

如果 `RX_BYTES` 正常但 `TX_BYTES` 为 0，说明 `apu_dma` 没产生 response，重点看 job controller、result streamer、错误处理。

如果 `TX_BYTES` 正常但 Python 解析失败，重点看 response buffer 长度、cache invalidate、协议版本和 Python parser。

## 7. Debug From RTL

推荐抓这些信号：

### AXIS input

```text
s_axis_job_tvalid
s_axis_job_tready
s_axis_job_tdata
s_axis_job_tkeep
s_axis_job_tlast
```

看是否有正常 handshake，header 是否是 `APUJ`。

### Decoder to controller

```text
cmd_valid/cmd_ready
cmd_opcode
cmd_target
cmd_payload_bytes
cmd_address
cmd_element_count
cmd_command_id
decoder_error_valid
decoder_error_status
```

如果命令没有进入 controller，先看 decoder 的 header 状态和错误。

### Loader

```text
loader_start_valid/ready
payload_valid/ready
act_we/out_we/weight_we/bn_we/instruction_we
loader_done
loader_error
```

如果 LOAD 不成功，检查 target、address、bank、payload length。

### Core

```text
core_start
core_busy
core_done
core_abort
worksheet_done
compute_done
```

如果 RUN timeout，检查 instruction 是否装载、`WorkSheet` 是否推进、`Ctrl` 是否产生 compute_done。

### Result

```text
response_start_valid/ready
host_rd_req
host_rd_valid
m_axis_result_tvalid
m_axis_result_tready
m_axis_result_tlast
response_done
```

如果 READ_RESULT 没返回，看 result streamer 是否向 core 发起 host read。

## 8. Common Failure Patterns

### `wait_mode=polling`

功能可能能跑，但不能证明 CPU `<10%`。验收 CPU 占用率必须使用 interrupt wait。

### CPU 高但 DMA wait CPU 低

如果 profile 显示：

```text
profile_dma_wait_cpu_seconds_mean 很小
profile_rx_allocate_cpu_seconds_mean 很大
```

说明 CPU 高主要来自 PYNQ CMA buffer 分配，而不是 DMA 忙等。应复用 RX buffer。

### `hardware_mbps_mean` 看起来不对

先确认 `--clock-mhz` 和 bitstream 实际 FCLK 一致。

```text
50 MHz bit -> --clock-mhz 50
25 MHz bit -> --clock-mhz 25
```

### final test 06 带宽低

这是正常的。06 是应用级 evaluate，不是纯 DMA transport benchmark。验收带宽和 CPU 主要看 04。

### Output bit mismatch

先不要直接改 RTL。按顺序：

1. 跑 `dma/sw` 软件 golden。
2. 比较 05 输出和 golden。
3. 用 stage/prefix diagnose 找第一次 mismatch 的层。
4. 再判断是 packet 装载、输出解析、还是 APU core 时序问题。

此前定位过的 residual 个别 bit mismatch 来自 `rtl/InBuf.sv` replay 逻辑，而不是 DMA wrapper 本身。

## 9. What To Record In Reports

最终报告建议保留：

- final test 01/04 的带宽对比。
- 04 的 `wall_mbps_mean`、`hardware_mbps_mean`、`cpu_percent_mean`、`wait_mode`。
- 如果 CPU 未达标，保留 profile breakdown，说明 CPU 消耗来源。
- 02/05 单图输出对齐结果。
- 03/06 小样本 evaluate 结果。
- Vivado FCLK 频率和时序是否通过。
