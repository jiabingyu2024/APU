# FPGA 上板文档索引

目标板为 **PYNQ-Z2**，器件为 `xc7z020clg400-1`。当前方案保持 SoC 完全位于
PL：PicoRV32、片内 RAM、模型 ROM、APU、总线和 UART 均由 RTL 实现，不实例化
Zynq Processing System IP。

建议按顺序阅读：

1. [01_VIVADO_PROJECT_AND_BITSTREAM.md](01_VIVADO_PROJECT_AND_BITSTREAM.md)
   - Vivado 工程创建、文件清单、PYNQ-Z2 适配、综合实现检查和 bitstream 导出。
2. [02_PYNQ_DEPLOY_AND_C_PROGRAM_VERIFY.md](02_PYNQ_DEPLOY_AND_C_PROGRAM_VERIFY.md)
   - bit 下载、串口接线、LED 含义、C 程序执行验证，以及 HWH 的真实作用。
3. [03_ACCEPTANCE_AND_TROUBLESHOOTING.md](03_ACCEPTANCE_AND_TROUBLESHOOTING.md)
   - ARM/PS 验收边界、资源与时序问题、无串口输出等常见故障排查。
4. [04_RESOURCE_ESTIMATE.md](04_RESOURCE_ESTIMATE.md)
   - XC7Z020 资源上限、当前设计的 BRAM/LUT/FF 粗估和综合风险。
5. [PIN.md](PIN.md)
   - PYNQ-Z2 管脚、时钟、按钮、LED、Pmod 和 PS MIO 参考。

配套工程文件位于：

```text
fpga/
├── Makefile
├── constraints/pynq_z2.xdc
├── rtl/pynq_z2_top.sv
├── scripts/create_project.tcl
├── scripts/build_bitstream.tcl
├── pynq/load_bitstream.py
├── xsct/disable_arm_cores.tcl
└── host/capture_uart.py
```

快速命令：

```bash
make -C soc firmware model
make -C fpga project
make -C fpga bitstream JOBS=4
```

Vivado 输出位于 `fpga/output/`。本机当前未安装 Vivado，因此仓库内已经完成脚本和
RTL/约束准备，但仍需在装有 Vivado 的电脑上执行综合、实现和生成 bitstream。
