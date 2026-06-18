# AXI and DMA Foundation

本文先解释本项目用到的总线概念。你已经了解过 AHB，可以把 AXI 理解成更复杂、更分离、更适合高性能 SoC 的总线族。

## 1. AHB/MMIO 回顾

旧版 `myDesign` 的思路接近：

```text
CPU 发起一次 MMIO 写 -> 总线把 32-bit 数据写到 APU 某个地址
CPU 发起一次 MMIO 读 -> 总线从 APU 某个地址读回 32-bit 数据
```

这很适合控制寄存器、小数据量调试、简单外设访问。

问题是神经网络数据量很大。若每个 32-bit 或 64-bit word 都由 CPU/Python 发起一次访问，开销会主要花在软件循环、总线事务启动、Python 调用和等待上，而不是硬件计算上。

DMA 的目标就是把“CPU 逐字搬数据”改成“CPU 只告诉 DMA 起点地址和长度，DMA 自己成批搬数据”。

## 2. AXI 不是一种接口

本项目里同时用了三类 AXI 风格接口：

| 接口 | 全名 | 主要用途 | 本项目位置 |
| --- | --- | --- | --- |
| AXI-Lite | AXI4-Lite | 少量寄存器读写 | PS 配置 AXI DMA、读写 `apu_dma` 控制寄存器、中断控制器 |
| AXI4 Memory Mapped | AXI4-MM | 对 DDR 做 burst 读写 | AXI DMA 的 `M_AXI_MM2S`、`M_AXI_S2MM` 访问 PS DDR |
| AXI-Stream | AXIS | 连续数据流，无地址 | AXI DMA 和 `apu_dma` IP 之间传 job/result |

一个常见误区是把 AXI-Lite 和 AXI-Stream 混在一起。它们不是同一种事：

- AXI-Lite 有地址，像 MMIO，用来读写寄存器。
- AXI-Stream 没有地址，只是一拍一拍传数据，像水管。
- AXI4-MM 有地址和 burst，用来访问 DDR 这类内存。

## 3. AXI-Stream 最小握手

本项目的 job/result 流都是 64-bit AXI-Stream：

```text
TDATA[63:0]  当前 beat 的数据
TKEEP[7:0]   当前 beat 哪些 byte 有效
TVALID       发送方说：我这一拍数据有效
TREADY       接收方说：我这一拍能接收
TLAST        一个 stream packet/job 的最后一拍
```

只有当 `TVALID=1` 且 `TREADY=1` 时，这一拍数据才真正传输成功。

```text
transfer_fire = TVALID && TREADY
```

如果 `TVALID=1` 但 `TREADY=0`，发送方必须保持数据不变，等待接收方准备好。这就是 AXI-Stream 背压。背压不是错误，是正常流控机制。

## 4. TLAST 在本项目里的含义

本项目规定：

- 一个 MM2S DMA transfer 承载一个完整 job。
- 一个 job 由多个 packet 组成。
- packet 边界不靠 `TLAST`，而靠 4-beat header 里的 `payload_bytes`。
- 整个 job 的最后一个 beat 才拉高 `TLAST`。

也就是说：

```text
LOAD packet header
LOAD packet payload
LOAD packet header
LOAD packet payload
RUN packet header
READ_RESULT packet header
END_JOB packet header with TLAST=1
```

这样设计的原因是 DMA 一次传输更适合承载完整 job，避免每个小 packet 都启动一次 DMA。

## 5. AXI DMA 的两个方向

Vivado AXI DMA IP 有两个主要方向：

```text
MM2S: Memory Mapped to Stream
      从 DDR 读数据，变成 AXI-Stream 输出

S2MM: Stream to Memory Mapped
      接收 AXI-Stream 输入，写回 DDR
```

本项目连接方式：

```text
DDR job buffer
  -> AXI DMA MM2S
  -> AXIS FIFO
  -> apu_dma/S_AXIS_JOB

apu_dma/M_AXIS_RESULT
  -> AXIS FIFO
  -> AXI DMA S2MM
  -> DDR response buffer
```

Python 只负责：

1. 在 DDR/CMA buffer 中准备 job。
2. 配置 AXI DMA 传输地址和长度。
3. 等 DMA 完成中断。
4. 从 response buffer 解析结果。

Python 不再逐字写 APU 内部 RAM。

## 6. 为什么还需要 AXI-Lite

即使有 DMA，也仍然需要 AXI-Lite。原因是 DMA 只能搬大块数据，不适合做控制和状态管理。

本项目 AXI-Lite 用于：

- 配置 Xilinx AXI DMA IP 的寄存器。
- 读取 `apu_dma` IP 的状态和性能计数器。
- 使能和清除 `apu_dma` IP 的中断。
- 配置 AXI interrupt controller。

所以 AXI-Lite 是“控制面”，AXI-Stream/AXI DMA 是“数据面”。

```text
Control plane:
  PS -> AXI-Lite -> registers

Data plane:
  DDR -> AXI DMA -> AXI-Stream -> apu_dma -> AXI-Stream -> AXI DMA -> DDR
```

## 7. 为什么说是低拷贝/零拷贝方向

严格说，PYNQ/Python 里仍然会有必要的数据准备和 cache flush/invalidate。但核心区别是：

- 旧 MMIO：CPU/Python 循环把每个 word 写进硬件寄存器/RAM。
- DMA：CPU/Python 把 job 放在一块连续 buffer，DMA 从 DDR 成批搬运。

验收里说“零拷贝高效传输”，在本项目中主要体现为：

- job buffer 使用 PYNQ 可 DMA 的连续 buffer。
- AXI DMA 直接从该 buffer 读 job。
- response 直接写入 RX buffer。
- Python 不逐字参与硬件数据通路。

性能报告中如果 CPU 占用率偏高，要区分是 DMA 等待本身高，还是 Python 分配 buffer、cache 维护、解析 response 的开销高。

## 8. 和 AHB 的对应关系

如果用你熟悉的 AHB 来类比：

| 旧 AHB/MMIO 思维 | DMA 支线中的对应物 |
| --- | --- |
| CPU 写 APU RAM 地址 | `LOAD` packet 写 ACT/OUT/WEIGHT/BN/INSTRUCTION |
| CPU 写 start 寄存器 | `RUN` packet |
| CPU 轮询 done | DMA/interrupt wait + `FINAL` response |
| CPU 读输出 RAM | `READ_RESULT` packet + S2MM response |
| 地址是 MMIO byte offset | packet 里的 address 是目标 RAM 的 native word index |

这个转换是学习本项目 DMA 设计的关键。
