# Vivado Tcl 工程生成和 bit/hwh 导出指南

本页记录当前真实 APU DMA overlay 的 Vivado 操作。不要覆盖旧
`apuYjb/myDesign.bit/.hwh`。

## 1. 路径原则

Vivado 在 Windows 下容易被长路径影响。工程和 IP 打包临时目录使用短路径：

```tcl
set ::env(APU_DMA_IP_BUILD_DIR) {E:/apu_dma_ip_pack}
set ::env(APU_DMA_PROJECT_DIR)  {E:/apu_dma_bd}
```

仓库路径保持为：

```tcl
cd {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU}
```

## 2. 从 Tcl 创建完整工程

在 Vivado 2023.2 Tcl Console 或 batch 中执行：

```tcl
cd {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU}

set ::env(APU_DMA_IP_BUILD_DIR) {E:/apu_dma_ip_pack}
set ::env(APU_DMA_PL_FREQ_MHZ) 50
source dma/vivado/package_apu_dma_ip.tcl

set ::env(APU_DMA_PROJECT_DIR) {E:/apu_dma_bd}
source dma/vivado/create_apu_dma_project.tcl
```

成功标志：

```text
APU_DMA_IP_PACKAGED=...
APU_DMA_IP_VLNV=apu.local:user:apu_dma:1.0
APU_DMA_STATUS=BD_VALIDATED
Project: E:/apu_dma_bd/apu_dma.xpr
```

`create_apu_dma_project.tcl` 会实例化已经封装好的 `apu.local:user:apu_dma:1.0`，
不是直接把 RTL module reference 拉进 BD。

## 3. BD 必查连接

打开 `E:/apu_dma_bd/apu_dma.xpr`，检查 `apu_dma_bd`：

```text
axi_dma_0/M_AXIS_MM2S -> axis_fifo_job -> apu_dma_0/S_AXIS_JOB
apu_dma_0/M_AXIS_RESULT -> axis_fifo_result -> axi_dma_0/S_AXIS_S2MM
axi_dma_0/M_AXI_MM2S -> smartconnect_mm2s -> PS S_AXI_HP0
axi_dma_0/M_AXI_S2MM -> smartconnect_s2mm -> PS S_AXI_HP1
PS M_AXI_GP0 -> smartconnect_ctrl -> axi_dma_0 / apu_dma_0 / axi_intc_0
xlconcat_irq/dout -> axi_intc_0/intr
axi_intc_0/irq -> processing_system7_0/IRQ_F2P
```

地址：

```text
axi_dma_0  : 0x40400000
axi_intc_0 : 0x41800000
apu_dma_0  : 0x43C00000
```

当前 bring-up bit 使用 25 MHz 单时钟。25 MHz 版本用于功能和稳定性验证；
要通过 `wall_mbps_mean >= 200`，需要重新生成更高频率版本，建议先做 100 MHz。

### 3.1 频率参数

`dma/vivado/package_apu_dma_ip.tcl` 和 `dma/vivado/create_apu_dma_project.tcl`
共用单一参数控制自定义 IP 元数据、PS FCLK0 和整条 BD 时钟：

```tcl
set pl_freq_mhz 25.000000
```

你可以直接改这个值，或者在 source 前覆盖：

```tcl
set ::env(APU_DMA_PL_FREQ_MHZ) 100
source dma/vivado/package_apu_dma_ip.tcl
source dma/vivado/create_apu_dma_project.tcl
```

这个值必须在打包 IP 前设置，否则 `apu.local:user:apu_dma:1.0` 的
`component.xml` 仍可能保留旧的 `FREQ_HZ`，导致 `validate_bd_design` 报频率不匹配。
后续在板上跑脚本时，`--clock-mhz` 也要填同一个数。

## 4. 生成 bitstream

GUI：

1. `Run Synthesis`
2. `Open Synthesized Design`，检查 critical warning
3. `Run Implementation`
4. `Report Timing Summary`
5. 确认 `WNS >= 0`、`TNS = 0`
6. `Generate Bitstream`

Tcl：

```tcl
cd {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU}
set ::env(APU_DMA_PROJECT_DIR) {E:/apu_dma_bd}
source dma/vivado/build_apu_dma_bitstream.tcl
```

## 5. 导出 overlay

在已打开且已经生成 bitstream 的工程中执行：

```tcl
source {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU/dma/vivado/export_apu_dma_overlay.tcl}
```

输出：

```text
dma/overlay/apu_dma.bit
dma/overlay/apu_dma.hwh
```

bit 和 hwh 必须同一次构建产生，不能混用。

## 6. 导出 Vivado 报告

```tcl
source {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU/dma/vivado/report_apu_dma_design.tcl}
```

报告目录：

```text
dma/vivado/reports/apu_dma/
```

至少保留：

```text
timing_summary.rpt
utilization.rpt
drc.rpt
clock_interaction.rpt
```

## 7. 不能忽略的问题

- `apu_dma_0` 接口缺失或 IP repository 未刷新；
- `axi_intc_0` 未接入 GP0 或未接到 PS `IRQ_F2P`；
- AXIS `TDATA/TKEEP/TLAST` 宽度不一致；
- 地址段未分配；
- bit/hwh 不是同一轮导出；
- Implementation timing 为负或 DRC 有 error。
