# Hardware and Software Co-Design View

本文按数字 IC 学生的视角重新解释 DMA 支线：同一个概念同时从硬件和软件两边看。你学习时要建立一个习惯：每个软件动作，硬件里一定有对应的接口、状态机、寄存器或存储行为；每个 RTL 信号，软件侧也一定有某种配置、buffer、等待或解析动作。

## 1. 先建立整体分工

本项目不是“只写 RTL”，也不是“只写 Python driver”。它是一个硬件/软件协同系统。

```text
软件侧负责:
  1. 准备连续内存 buffer
  2. 按本项目协议构造 job/packet/header/payload
  3. 配置 AXI DMA
  4. 配置/读取 apu_dma AXI-Lite 寄存器
  5. 等待中断或 DMA 完成
  6. 解析 response
  7. 和软件 golden 或旧 MMIO 输出对齐

硬件侧负责:
  1. AXI DMA 从 DDR 读取 job stream
  2. 自定义 RTL 解析 packet header
  3. 根据 LOAD 写入 APU 内部 RAM
  4. 根据 RUN 启动原始 APU 计算核心
  5. 根据 READ_RESULT 读取输出 RAM
  6. 生成 response stream
  7. 更新状态寄存器、性能计数器和中断
```

如果只看软件，你会觉得 header/job 是“人为规定的格式”。如果只看硬件，你会觉得状态机在解析很多字段。真正的理解是：这些字段就是软件给硬件的命令语言。

## 2. 一条命令的软硬件对应

以 `LOAD WEIGHT bank 3` 为例。

### 软件视角

Python 构造一个 packet：

```text
opcode        = LOAD
target        = WEIGHT
address       = 0
element_count = 256
arg0          = 3
payload       = 256 个 64-bit weight word
```

软件要保证：

- payload 的字节数等于 `256 * 8`。
- packet header 按 little-endian 写进 DMA buffer。
- 整个 DMA buffer 是 AXI DMA 可访问的连续内存。
- 启动 DMA 前 cache flush。

### 硬件视角

`axis_job_decoder` 看到 AXI-Stream 输入：

```text
先收 4 个 64-bit header beat
解析 opcode/target/address/count/arg0
发现这是 LOAD WEIGHT
后续 payload beat 透传给 loader
```

`apu_stream_loader` 做：

```text
检查 bank=3 是否 <64
检查 address+count 是否 <=256
检查 payload_bytes 是否等于 count*8
每收到一个 payload beat:
  weight_we    <= 1
  weight_bank  <= 3
  weight_waddr <= 当前地址
  weight_wdata <= payload_data
```

`apu_dma_core` 里 `ComputeCoreGroup` 的 WeightSRAM 写端口收到这些信号，真正把数据写进硬件存储。

这就是一条软件命令在硬件里的落点。

## 3. job/packet/header 不是 DMA 标准，是硬件可识别的命令 ISA

对数字 IC 学生来说，可以把本项目 packet 协议理解为一个很小的“命令集”。

| 软件 packet | 类似 CPU 指令 | 硬件执行单元 |
| --- | --- | --- |
| `LOAD ACT` | store block to ACT RAM | `apu_stream_loader` + ACT SRAM 写端口 |
| `LOAD WEIGHT` | store block to Weight SRAM bank | `apu_stream_loader` + WeightSRAM 写端口 |
| `LOAD BN` | store block to BN/SIMD RAM | `apu_stream_loader` + SIMD 参数写端口 |
| `LOAD INSTRUCTION` | store APU instruction memory | `apu_stream_loader` + WorkSheet 写端口 |
| `RUN` | start execution | `apu_job_ctrl` + `apu_dma_core.core_start` |
| `READ_RESULT` | load block from output RAM | `axis_result_streamer` + host read port |
| `END_JOB` | finish program | `apu_job_ctrl` + FINAL response |

所以 header 字段不是随便设计的。它们是硬件状态机执行命令所需的操作数。

```text
opcode  决定执行哪类动作
target  决定访问哪个硬件 RAM
address 决定 RAM 起始 word index
count   决定循环多少次
arg0    对 WEIGHT/BN 是 bank，对 RUN 是 timeout
```

## 4. AXI DMA 在这里不是“智能控制器”

AXI DMA 的角色很单纯：

```text
MM2S: DDR -> AXI-Stream
S2MM: AXI-Stream -> DDR
```

它不会理解：

- header
- opcode
- target
- APU 是否计算完成
- 输出属于哪个类别

这些全部由自定义 `apu_dma` RTL 和 Python parser 负责。

硬件里真正理解 job 的模块是：

```text
axis_job_decoder
apu_job_ctrl
apu_stream_loader
axis_result_streamer
```

软件里真正理解 job 的模块是：

```text
dma/pynq/dma_job.py
dma/pynq/dma_network_job.py
dma/pynq/apu_dma_driver.py
```

AXI DMA 只是高性能搬运通道。

## 5. AXI-Lite、AXI-MM、AXI-Stream 三者从软硬件看

### AXI-Lite

软件看：

```text
driver.write(register_offset, value)
driver.read(register_offset)
```

硬件看：

```text
AW/W/B 写通道
AR/R 读通道
apu_dma_axil_regs 根据 offset 返回状态或写控制位
```

用途：控制寄存器、中断、性能计数器。

### AXI4 Memory Mapped

软件看：

```text
tx_buffer physical address
rx_buffer physical address
transfer length
```

硬件/BD 看：

```text
axi_dma_0/M_AXI_MM2S -> PS S_AXI_HP0 -> DDR
axi_dma_0/M_AXI_S2MM -> PS S_AXI_HP1 -> DDR
```

用途：AXI DMA 访问 DDR。

### AXI-Stream

软件看不到每一拍，只看到 DMA buffer 被传走或写回。

硬件看：

```text
TDATA/TKEEP/TVALID/TREADY/TLAST
```

用途：AXI DMA 和自定义 `apu_dma` RTL 之间传 job 和 response。

## 6. 为什么软件要 flush/invalidate

这是很多数字 IC 学生容易忽略的软件/硬件一致性问题。

PYNQ 上 ARM CPU 有 cache，AXI DMA 访问的是 DDR。可能出现：

```text
CPU 写了 tx_buffer
数据还在 CPU cache
DDR 里还是旧数据
DMA 从 DDR 读到旧数据
```

所以 MM2S 前要 flush：

```text
把 CPU cache 中的 tx_buffer 写回 DDR
```

S2MM 后要 invalidate：

```text
DMA 已经把 response 写入 DDR
CPU cache 里可能还有旧 rx_buffer
invalidate 后 CPU 才重新从 DDR 读新数据
```

硬件 RTL 不知道 cache 的存在。这是软件 driver 必须配合的地方。

## 7. 为什么 CPU 占用率和硬件设计有关，但不完全等于硬件问题

验收要求 CPU `<10%`。这个指标要分开看：

```text
硬件相关:
  中断是否可用
  RTL 是否能产生 done/error
  AXI DMA 是否能完成 transfer
  是否存在 TREADY 长时间拉低导致等待变长

软件相关:
  是否 polling 忙等
  是否每次重新 allocate CMA buffer
  是否做大量 Python 解析
  是否把数据集读取/预处理算进了 DMA 传输测试
```

所以如果 CPU 高，不能马上说 RTL 错。要看 profile：

```text
profile_dma_wait_cpu_seconds_mean
profile_rx_allocate_cpu_seconds_mean
profile_invalidate_parse_cpu_seconds_mean
```

如果 DMA wait CPU 很低，但 allocate CPU 很高，那是软件 buffer 管理问题，不是 AXI-Stream RTL 忙等。

## 8. 从硬件角度看一次完整推理

硬件状态流：

```text
AXI DMA MM2S sends stream
  |
axis_job_decoder parses header
  |
apu_job_ctrl dispatches command
  |
LOAD -> apu_stream_loader writes RAM
RUN  -> apu_dma_core starts WorkSheet/Ctrl/APU
READ -> axis_result_streamer reads RAM
END  -> FINAL response
  |
AXI DMA S2MM writes response to DDR
```

关键硬件状态机：

| 模块 | 状态机职责 |
| --- | --- |
| `axis_job_decoder` | header/payload 切分、基础协议检查、错误 drain |
| `apu_stream_loader` | LOAD payload 写内部 RAM |
| `apu_job_ctrl` | job 主调度，处理 LOAD/RUN/READ/END/ERROR |
| `axis_result_streamer` | response header/data 输出 |
| `apu_dma_axil_regs` | AXI-Lite 寄存器和中断状态 |

## 9. 从软件角度看一次完整推理

软件流程：

```text
load image / CIFAR sample
  |
build APU input words
  |
build DMA job packets
  |
allocate or reuse tx/rx buffer
  |
flush tx buffer
  |
start S2MM receive
start MM2S send
  |
wait interrupt / DMA completion
  |
invalidate rx buffer
  |
parse response packets
  |
unpack output bits
  |
compare class / golden / report
```

这就是为什么测试 6 的带宽低于测试 4：测试 6 包含了很多软件流程，而测试 4 主要测 DMA transport。

## 10. 看 RTL 时应该问的问题

你是数字 IC 方向，读 RTL 时建议按这些问题读：

1. 这个模块的输入输出握手是什么？
2. 哪些信号是 valid/ready 协议？
3. 这个状态机什么时候前进？
4. 如果下游 `ready=0`，本模块是否保持数据稳定？
5. 错误发生时状态机怎么恢复？
6. 写 RAM 的地址、数据、we 是否同拍对齐？
7. 读 RAM 是否有一拍延迟，谁接住这个延迟？
8. reset/abort 会清什么，不清什么？
9. 性能瓶颈可能来自哪里，是否有 backpressure？
10. 软件侧是否能观察到这个错误或状态？

例如看 `axis_result_streamer`，你应该关注：

- `host_rd_req` 发出后，什么时候 `host_rd_valid` 回来。
- `read_data_q` 如何接住返回数据。
- `m_axis_tvalid && m_axis_tready` 时状态机如何推进。
- 最后一拍什么时候拉 `TLAST`。

## 11. 看软件时应该问的问题

读 Python driver 时建议按这些问题读：

1. 这个 buffer 是普通 numpy 数组，还是 PYNQ DMA buffer？
2. buffer 物理地址是否给了 AXI DMA？
3. 发送前有没有 flush？
4. 接收后有没有 invalidate？
5. 是否先启动 S2MM，再启动 MM2S？
6. 等待方式是 interrupt 还是 polling？
7. response parser 如何识别 DATA/FINAL/ERROR？
8. 错误码是否能映射回 RTL status？
9. 性能统计中哪些时间属于 DMA，哪些属于 Python？
10. 测试脚本测的是 transport，还是 end-to-end application？

## 12. 学习本项目的推荐路径

按数字 IC 学生的学习顺序，建议这样走：

1. 先读 [00_TERMS_JOB_PACKET_HEADER.md](00_TERMS_JOB_PACKET_HEADER.md)，分清术语。
2. 再读本文，建立软硬件协同视角。
3. 读 [01_AXI_DMA_FOUNDATION.md](01_AXI_DMA_FOUNDATION.md)，分清三种 AXI 接口。
4. 读 [02_SYSTEM_DATA_FLOW.md](02_SYSTEM_DATA_FLOW.md)，看完整数据流。
5. 对着 [03_RTL_ARCHITECTURE.md](03_RTL_ARCHITECTURE.md) 打开 `dma/rtl/*.sv`。
6. 对着 [04_BLOCK_DESIGN.md](04_BLOCK_DESIGN.md) 打开 Vivado BD。
7. 最后读 [05_REGISTERS_INTERRUPTS_AND_DEBUG.md](05_REGISTERS_INTERRUPTS_AND_DEBUG.md)，学习怎么定位问题。

不要只背概念。每个概念都要能回答两句话：

```text
软件侧谁产生/消费它？
硬件侧哪个模块、哪个状态机、哪个信号处理它？
```
