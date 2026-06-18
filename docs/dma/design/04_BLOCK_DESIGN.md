# Vivado Block Design

本文解释 `dma/vivado/create_apu_dma_project.tcl` 创建的 block design。目标是让你看 Vivado BD 图时知道每个 IP 为什么存在、数据怎么流、地址和中断怎么连。

## 1. Top-Level BD Components

BD 主要 IP：

```text
processing_system7_0   Zynq PS，运行 Linux/Python，连接 DDR
axi_dma_0              Xilinx AXI DMA，负责 DDR <-> AXI-Stream
apu_dma_0              自定义 APU DMA IP
axis_fifo_job          MM2S 到 apu_dma 的输入 FIFO
axis_fifo_result       apu_dma 到 S2MM 的输出 FIFO
smartconnect_ctrl      AXI-Lite 控制总线
smartconnect_mm2s      DMA MM2S 读 DDR 的 AXI-MM 通路
smartconnect_s2mm      DMA S2MM 写 DDR 的 AXI-MM 通路
axi_intc_0             AXI interrupt controller
xlconcat_irq           合并多个中断输入
proc_sys_reset_0       同步复位
```

整体结构：

```text
                 AXI-Lite control
PS M_AXI_GP0 ---------------------- smartconnect_ctrl
                                        | M00 -> axi_dma_0/S_AXI_LITE
                                        | M01 -> apu_dma_0/S_AXI_CTRL
                                        | M02 -> axi_intc_0/S_AXI

                 DDR read path
axi_dma_0/M_AXI_MM2S -> smartconnect_mm2s -> PS S_AXI_HP0

                 DDR write path
axi_dma_0/M_AXI_S2MM -> smartconnect_s2mm -> PS S_AXI_HP1

                 stream job path
axi_dma_0/M_AXIS_MM2S -> axis_fifo_job -> apu_dma_0/S_AXIS_JOB

                 stream result path
apu_dma_0/M_AXIS_RESULT -> axis_fifo_result -> axi_dma_0/S_AXIS_S2MM
```

## 2. Why PS7 Is Needed

PYNQ-Z2 是 Zynq-7000，包含：

- PS：ARM Cortex-A9、DDR 控制器、Linux/Python。
- PL：FPGA fabric，放你的 APU/DMA RTL。

本项目中 PS 负责：

- 运行 Python driver。
- 分配 DMA buffer。
- 配置 AXI DMA 和自定义 `apu_dma` 寄存器。
- 等待中断。
- 解析返回结果。

PL 负责：

- AXI DMA 数据面。
- 自定义 `apu_dma` packet 解析和 APU 计算。

## 3. Control Path: `M_AXI_GP0`

PS 通过 `M_AXI_GP0` 发起 AXI-Lite 读写。

连接：

```text
processing_system7_0/M_AXI_GP0
  -> smartconnect_ctrl/S00_AXI
  -> smartconnect_ctrl/M00_AXI -> axi_dma_0/S_AXI_LITE
  -> smartconnect_ctrl/M01_AXI -> apu_dma_0/S_AXI_CTRL
  -> smartconnect_ctrl/M02_AXI -> axi_intc_0/S_AXI
```

用途：

| 从设备 | 地址 | 用途 |
| --- | --- | --- |
| `axi_dma_0/S_AXI_LITE` | `0x4040_0000` | 配置 MM2S/S2MM DMA 传输 |
| `apu_dma_0/S_AXI_CTRL` | `0x43C0_0000` | 读状态、性能计数器、中断控制 |
| `axi_intc_0/S_AXI` | `0x4180_0000` | 配置中断控制器 |

这个路径是控制面，不搬大块数据。

## 4. Data Path: MM2S

MM2S = memory mapped to stream。

路径：

```text
DDR job buffer
  -> PS DDR controller
  -> PS S_AXI_HP0
  -> smartconnect_mm2s
  -> axi_dma_0/M_AXI_MM2S
  -> axi_dma_0/M_AXIS_MM2S
  -> axis_fifo_job
  -> apu_dma_0/S_AXIS_JOB
```

准确说，AXI DMA 的 `M_AXI_MM2S` 是一个 AXI memory mapped master，它通过 HP0 从 DDR 读。读到的数据由 DMA 转成 `M_AXIS_MM2S` stream。

为什么用 HP0：

- HP 是 PS 提供给 PL 访问 DDR 的高性能端口。
- 比通过 GP 端口搬大块数据合适。

## 5. Data Path: S2MM

S2MM = stream to memory mapped。

路径：

```text
apu_dma_0/M_AXIS_RESULT
  -> axis_fifo_result
  -> axi_dma_0/S_AXIS_S2MM
  -> axi_dma_0/M_AXI_S2MM
  -> smartconnect_s2mm
  -> PS S_AXI_HP1
  -> DDR response buffer
```

AXI DMA 从 stream 接收 response，然后通过 `M_AXI_S2MM` 把数据写入 DDR。

为什么用 HP1：

- MM2S 读和 S2MM 写分开用 HP0/HP1，结构清楚。
- 读写方向不共用同一个 SmartConnect，便于理解和调试。

## 6. Why AXIS FIFOs Are Inserted

BD 里有两个 AXIS FIFO：

```text
axis_fifo_job
axis_fifo_result
```

它们不是协议必须，但很实用。

作用：

- 缓冲 AXI DMA 和自定义 RTL 之间的短暂停顿。
- 降低组合 ready 路径压力。
- 在 DMA burst 和 APU packet 处理之间做弹性解耦。
- 让时序更容易收敛。

例如 `apu_dma` 在解析 header 或等待 loader 时可能临时 `TREADY=0`。FIFO 可以吸收一部分输入数据，避免 DMA 端马上被反压。

## 7. AXI DMA Configuration

Tcl 中配置：

```tcl
CONFIG.c_include_sg {0}
CONFIG.c_include_mm2s {1}
CONFIG.c_include_s2mm {1}
CONFIG.c_include_mm2s_dre {1}
CONFIG.c_include_s2mm_dre {1}
CONFIG.c_m_axi_mm2s_data_width {64}
CONFIG.c_m_axi_s2mm_data_width {64}
CONFIG.c_m_axis_mm2s_tdata_width {64}
CONFIG.c_s_axis_s2mm_tdata_width {64}
CONFIG.c_mm2s_burst_size {64}
CONFIG.c_s2mm_burst_size {64}
CONFIG.c_sg_length_width {26}
```

解释：

| 配置 | 含义 |
| --- | --- |
| `c_include_sg=0` | 不使用 scatter-gather，使用 simple DMA |
| `include_mm2s=1` | 启用 DDR -> stream |
| `include_s2mm=1` | 启用 stream -> DDR |
| `dre=1` | 允许非严格自然对齐的地址，PYNQ buffer 使用更方便 |
| data width 64 | 和 `apu_dma` AXIS 64-bit 对齐 |
| burst size 64 | DMA 访问 DDR 时允许较长 burst |
| length width 26 | 支持较大的 DMA transfer length |

## 8. Interrupt Design

中断来源有三个：

```text
axi_dma_0/mm2s_introut
axi_dma_0/s2mm_introut
apu_dma_0/irq
```

它们先进入 `xlconcat_irq`：

```text
In0 = mm2s_introut
In1 = s2mm_introut
In2 = apu_dma irq
```

然后进入：

```text
xlconcat_irq/dout -> axi_intc_0/intr -> axi_intc_0/irq -> PS IRQ_F2P
```

为什么不用直接把三个中断都接 PS：

- PS fabric interrupt 接口通常希望有清晰的中断管理。
- AXI interrupt controller 可以通过 AXI-Lite 配置、屏蔽、查询中断。
- PYNQ 更容易把中断暴露给 Python。

`apu_dma_0/irq` 只表示自定义 IP 的 job done/error。AXI DMA 自己的 MM2S/S2MM 完成也会产生中断。

## 9. Clocking

Tcl 中使用一个频率参数：

```tcl
set pl_freq_mhz 50.000000
```

也可以通过环境变量覆盖：

```powershell
$env:APU_DMA_PL_FREQ_MHZ = "50"
```

这个频率用于 PS FCLK0：

```text
processing_system7_0/FCLK_CLK0
```

然后 FCLK0 连接到所有主要 PL IP：

```text
PS M_AXI_GP0_ACLK
PS S_AXI_HP0_ACLK
PS S_AXI_HP1_ACLK
SmartConnect aclk
AXI DMA clocks
AXIS FIFO clocks
apu_dma/aclk
axi_intc clock
proc_sys_reset slowest_sync_clk
```

本设计是单时钟域设计。好处是简单，不需要额外 CDC。代价是所有 IP 都要在同一个 PL 频率下通过时序。

## 10. Reset

PS 提供：

```text
FCLK_RESET0_N
```

接到 `proc_sys_reset_0/ext_reset_in`，再由 `proc_sys_reset_0/peripheral_aresetn` 输出同步低有效复位，连接到：

```text
SmartConnect
AXI DMA
AXIS FIFO
apu_dma
axi_intc
```

`apu_dma` 内部使用 `aresetn` 作为全局低有效复位。

## 11. Address Map

Tcl 固定分配地址：

```text
0x4040_0000  AXI DMA registers
0x43C0_0000  APU DMA custom registers
0x4180_0000  AXI interrupt controller registers
```

这些地址是 PS 通过 AXI-Lite 访问 PL 外设的地址，不是 packet 中的 `address`。

要区分：

```text
AXI-Lite address:
  0x43C0_0000 + register offset
  用于 PS 访问 apu_dma 寄存器

Packet address:
  target RAM word index
  例如 ACT RAM 第 0 个 64-bit word
```

## 12. How Tcl Creates the BD

`create_apu_dma_project.tcl` 的主要步骤：

1. 创建 Vivado project。
2. 检查 PYNQ-Z2 board part。
3. 加入 packaged `APU_DMA` IP repo。
4. 创建 block design。
5. 创建 PS7、SmartConnect、AXI DMA、FIFO、自定义 IP、中断控制器。
6. 连接 AXI-Lite 控制面。
7. 连接 DMA 的 DDR MM2S/S2MM memory mapped 通路。
8. 连接 AXI-Stream job/result 通路。
9. 连接中断。
10. 连接 FCLK0 和复位。
11. 设置接口 `FREQ_HZ`，避免 Vivado validate 时频率 metadata 不匹配。
12. 分配地址。
13. `validate_bd_design`。
14. 生成 wrapper。

## 13. What Happens After BD Generation

Tcl 只创建和验证 BD，不一定自动跑完整 bitstream。

后续 Vivado 流程：

```text
synthesis
implementation
generate bitstream
export hardware / hwh
copy apu_dma.bit and apu_dma.hwh to dma/overlay/
```

如果只修改 Python，不需要跑 Vivado。

如果修改这些文件，需要重新 Vivado：

```text
rtl/*.sv
dma/rtl/*.sv
dma/vivado/*.tcl, when it affects IP/BD
```

## 14. Common BD Mistakes

### Frequency mismatch

典型错误：

```text
FREQ_HZ does not match between /apu_dma_0/S_AXI_CTRL and /smartconnect_ctrl/M01_AXI
```

原因通常是：

- BD 里 FCLK 改成 50 MHz。
- 但 packaged IP 的接口 metadata 仍写着旧频率，比如 25 MHz。

解决方向：

- `package_apu_dma_ip.tcl` 和 `create_apu_dma_project.tcl` 都要使用同一个 `APU_DMA_PL_FREQ_MHZ`。
- `apu_dma_top.sv` 不应硬编码旧的 `FREQ_HZ`。

### Interrupt output Bus vs Single

典型 warning：

```text
Interrupt output connection Bus is selected, but interrupt bus interface is not connected
```

本项目设置：

```tcl
CONFIG.C_IRQ_CONNECTION {0}
```

让 `axi_intc` 使用 single interrupt output，连接到 PS `IRQ_F2P`。

### Missing HP ports

如果 PS7 没启用 HP0/HP1，AXI DMA 就没有高性能 DDR 访问路径。Tcl 中启用：

```tcl
CONFIG.PCW_USE_S_AXI_HP0 {1}
CONFIG.PCW_USE_S_AXI_HP1 {1}
```

### AXIS width mismatch

AXI DMA、FIFO 和 `apu_dma` 都要是 64-bit stream，即 `TDATA_NUM_BYTES=8`。

否则 packet header 和 payload beat 对齐会错。

## 15. How To Read the Vivado Diagram

看 BD 图时按这个顺序：

1. 找 `processing_system7_0`。
2. 从 `M_AXI_GP0` 跟到 `smartconnect_ctrl`，确认三个 AXI-Lite 从设备。
3. 找 `axi_dma_0`。
4. 看 `M_AXI_MM2S` 是否通向 `S_AXI_HP0`。
5. 看 `M_AXI_S2MM` 是否通向 `S_AXI_HP1`。
6. 看 `M_AXIS_MM2S` 是否经过 `axis_fifo_job` 到 `apu_dma_0/S_AXIS_JOB`。
7. 看 `apu_dma_0/M_AXIS_RESULT` 是否经过 `axis_fifo_result` 到 `S_AXIS_S2MM`。
8. 看三个中断是否进入 `xlconcat_irq -> axi_intc_0 -> IRQ_F2P`。
9. 看所有主要 IP 是否使用同一个 FCLK0。
10. 看 reset 是否来自 `proc_sys_reset_0/peripheral_aresetn`。
