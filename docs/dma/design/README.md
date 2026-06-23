# APU DMA Design Notes

新增重点文档：

- [07_FINAL_TEST_DRIVERS_AND_METRICS.md](07_FINAL_TEST_DRIVERS_AND_METRICS.md)
  - 解释 final tests 中旧 MMIO driver 与新 DMA driver 的 Python 调用关系，以及带宽、CPU 占用、推理时间等数字的计算方法。

本目录用于学习 DMA 支线的设计，不是运行命令清单。假设读者已经知道 AHB/MMIO 的基本概念，但对 AXI、AXI-Stream、AXI DMA 和本项目 RTL 细节还不熟。

建议阅读顺序：

1. [00_TERMS_JOB_PACKET_HEADER.md](00_TERMS_JOB_PACKET_HEADER.md)
   - 先分清 job、packet、header、payload、beat、TLAST 是什么，哪些是 DMA/AXI 术语，哪些是本项目自定义协议。
2. [00A_HARDWARE_SOFTWARE_CO_VIEW.md](00A_HARDWARE_SOFTWARE_CO_VIEW.md)
   - 按数字 IC 学生的视角，从硬件 RTL 和软件 driver 两边同时理解 DMA 支线。
3. [01_AXI_DMA_FOUNDATION.md](01_AXI_DMA_FOUNDATION.md)
   - 先把 AXI-Lite、AXI4 memory mapped、AXI-Stream、AXI DMA 的角色分清楚。
4. [02_SYSTEM_DATA_FLOW.md](02_SYSTEM_DATA_FLOW.md)
   - 看一条 job 从 Python 到 DDR、DMA、RTL、APU core、再回 DDR 的完整路径。
5. [03_RTL_ARCHITECTURE.md](03_RTL_ARCHITECTURE.md)
   - 逐模块解释 `dma/rtl/` 下的实现。
6. [04_BLOCK_DESIGN.md](04_BLOCK_DESIGN.md)
   - 解释 Vivado block design 里每个 IP 为什么存在、怎么连。
7. [05_REGISTERS_INTERRUPTS_AND_DEBUG.md](05_REGISTERS_INTERRUPTS_AND_DEBUG.md)
   - 解释 AXI-Lite 寄存器、中断、性能计数器和常见定位方法。
8. [06_HARDWARE_BLOCK_DIAGRAM.md](06_HARDWARE_BLOCK_DIAGRAM.md)
   - 用硬件框图区分 Vivado IP、自定义 DMA RTL 和基础 APU RTL。

## What This DMA Branch Adds

原始 `apuYjb/myDesign` 方案中，PS 端 Python 通过 MMIO/AHB 把数据一点点写进 APU 的 RAM，再轮询计算完成，最后一点点读回结果。这条路线功能直观，但传输效率低，CPU 参与太多。

DMA 支线做的事情是：

```text
旧路线:
Python -> AXI-Lite/AHB MMIO -> APU internal RAM
Python <- AXI-Lite/AHB MMIO <- APU output RAM

新路线:
Python 构造连续 job buffer in DDR
AXI DMA MM2S 从 DDR 读 job buffer
AXI-Stream 送入自定义 apu_dma IP
apu_dma IP 写入 APU 内部 RAM、启动 APU、读取输出
AXI-Stream 返回 response
AXI DMA S2MM 写回 DDR response buffer
Python 解析 response buffer
```

所以 DMA 支线不是重写 APU 计算核心，而是在旧 APU 外面包了一层高吞吐的数据装载、命令调度、结果返回和状态统计接口。

## Source Files

| 路径 | 用途 |
| --- | --- |
| `dma/rtl/apu_dma_top.sv` | 自定义 DMA IP 顶层，连接 AXIS、AXI-Lite 和内部子模块 |
| `dma/rtl/axis_job_decoder.sv` | 解析输入 AXI-Stream job packet |
| `dma/rtl/apu_stream_loader.sv` | 把 LOAD payload 写入 APU 的 ACT/OUT/WEIGHT/BN/INSTRUCTION RAM |
| `dma/rtl/apu_job_ctrl.sv` | job 主状态机，调度 LOAD/RUN/READ_RESULT/END_JOB |
| `dma/rtl/apu_dma_core.sv` | 包装原始 APU 核心模块，暴露 DMA 装载和结果读取接口 |
| `dma/rtl/axis_result_streamer.sv` | 把结果 RAM 读成 AXI-Stream response |
| `dma/rtl/apu_dma_axil_regs.sv` | AXI-Lite 状态、性能计数器和中断寄存器 |
| `dma/rtl/apu_dma_perf_counters.sv` | 统计 RX/TX 字节、busy cycles、stall cycles、完成/错误 job |
| `dma/vivado/create_apu_dma_project.tcl` | 创建 PYNQ-Z2 block design |
| `dma/vivado/package_apu_dma_ip.tcl` | 把 DMA RTL 和基础 APU RTL 封装成 Vivado IP |

## Final Mental Model

你可以把本设计理解成三个层次：

```text
PYNQ Python layer
  构造 job buffer、配置 AXI DMA、等待中断、解析 response

Vivado block design layer
  PS7、AXI DMA、AXIS FIFO、SmartConnect、中断控制器、自定义 apu_dma IP

Custom RTL layer
  packet decoder、loader、job controller、APU wrapper、result streamer、registers
```

学习时不要一开始就钻进某个 `always_ff`。先理解这三个层次之间的责任边界，再看每个 RTL 模块做了哪一段工作。
