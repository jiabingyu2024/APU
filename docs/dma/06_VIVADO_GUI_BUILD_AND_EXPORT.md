# Vivado GUI：建立完整APU DMA工程并导出Overlay

## 1. 前提

- Vivado 2023.2；
- 已安装PYNQ-Z2 board files；
- 仓库路径中能看到`rtl/`、`dma/rtl/`和`dma/vivado/`；
- 不要覆盖`apuYjb/myDesign.bit/.hwh`。

本方案是PS+PL DMA方案，PS必须启用。它与之前“禁用ARM硬核”的自研SoC路线不同。

## 2. 创建工程

打开Vivado，在Tcl Console执行：

```tcl
cd /home/jiabingyu/prj/26_myprj/APU
source dma/vivado/create_apu_dma_project.tcl
```

Windows Vivado访问WSL目录不稳定时，把整个仓库放到Windows盘，再对实际Windows路径执行
`cd`。脚本成功结束应打印：

```text
APU_DMA_STATUS=BD_VALIDATED
```

脚本到此停止，不会自动运行综合或生成bitstream。

## 3. GUI中必须检查

打开`apu_dma_bd`，确认：

1. `axi_dma_0/M_AXIS_MM2S -> axis_fifo_job -> apu_dma_0/S_AXIS_JOB`；
2. `apu_dma_0/M_AXIS_RESULT -> axis_fifo_result -> axi_dma_0/S_AXIS_S2MM`；
3. DMA MM2S和S2MM memory master分别经SmartConnect连接PS HP0、HP1；
4. PS GP0只连接DMA寄存器和APU DMA控制寄存器；
5. 三个中断均进入`xlconcat_irq -> IRQ_F2P`；
6. 所有数据面时钟为100 MHz，复位来自`proc_sys_reset_0/peripheral_aresetn`；
7. Address Editor中DMA为`0x40400000`，APU DMA控制为`0x43C00000`。

如果`apu_dma_0`没有显示`S_AXIS_JOB/M_AXIS_RESULT/S_AXI_CTRL`，不要继续生成bitstream；先检查
`apu_dma_top.sv`是否作为SystemVerilog加入、compile order中package是否在其他DMA RTL之前。

## 4. 综合、实现和bitstream

在Flow Navigator依次执行：

1. `Run Synthesis`；
2. 打开synthesized design，检查没有latch、多驱动、未连接关键端口；
3. `Run Implementation`；
4. 查看Timing Summary，要求`WNS >= 0`且`TNS = 0`；
5. 查看Utilization，确认BRAM/LUT没有超过器件资源；
6. `Generate Bitstream`。

任何一步报错都应保留完整log，不要只截最后一行。

## 5. 导出bit和hwh

bitstream完成后，在同一Vivado工程Tcl Console执行：

```tcl
source /home/jiabingyu/prj/26_myprj/APU/dma/vivado/export_apu_dma_overlay.tcl
```

结果应生成：

```text
dma/overlay/apu_dma.bit
dma/overlay/apu_dma.hwh
```

两个文件必须来自同一次工程生成，文件名必须同名。不要把新bit与旧`myDesign.hwh`混用。

## 6. 需要保存的报告

在Vivado GUI导出或保存到`dma/vivado/reports/apu_dma/`：

- synthesis utilization；
- implementation utilization；
- timing summary；
- DRC report；
- address map截图或报告；
- 关键warning清单。
