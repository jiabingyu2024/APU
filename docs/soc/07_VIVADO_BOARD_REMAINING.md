# 剩余工作：Vivado 与上板

当前软件、SoC RTL、APU 总线桥、模型装载、完整推理、UART TX 和 Verilator 回归均已完成。
以下项目必须结合实际 FPGA 板卡和 Vivado 才能完成，因此是当前唯一剩余阶段。

## 1. 必须确认的板卡信息

- FPGA 具体器件型号和封装；
- PL 外部时钟频率、时钟管脚和电平标准；
- 复位按键极性与管脚；
- USB-UART TX 管脚和波特率；
- 可用 Block RAM 数量是否容纳 boot RAM、model ROM 和 APU SRAM；
- 是否需要把 model ROM 改为 QSPI/SDRAM 流式读取。

## 2. Vivado 操作清单

1. 使用 `fpga/scripts/create_project.tcl` 创建纯 RTL project，不添加 Zynq Processing System。
2. 顶层选择 PYNQ-Z2 包装层 `pynq_z2_top`。
3. H16 输入 125 MHz，经 PL 内 MMCM 生成 25 MHz；`CLK_HZ=25_000_000`，UART 保持 115200。
4. 添加 `soc/build/firmware.hex` 和 `soc/build/model.hex` 为 memory initialization 文件；
   若 Vivado 工程工作目录不同，覆盖顶层参数 `FIRMWARE_INIT_FILE/MODEL_INIT_FILE`。
5. 使用 `fpga/constraints/pynq_z2.xdc`：H16 时钟、BTN0、PMODB UART TX 和四个 LED。
6. 检查 125 MHz 输入时钟和 MMCM 派生的 25 MHz/40 ns 时钟，并检查复位同步器路径。
7. 综合后检查 BRAM/DSP/LUT/FF 使用率和未约束端口。
8. 实现后检查 WNS/TNS；重点观察 Ctrl 到 Feature SRAM、APU bridge 和 PicoRV32 路径。
9. 生成 bitstream，下载后串口应依次打印完整 PASS 日志。

## 3. ARM PS 禁用验收

本工程的 PL 顶层没有 PS7 实例，也不依赖 `FCLK_CLK`、AXI GP/HP、DDR 或 ARM 软件。
最终验收采用 `fpga/xsct/disable_arm_cores.tcl`：写
`A9_CPU_RST_CTRL(0xF8000244)=0x00000033`，同时复位两个 Cortex-A9 并停止两核时钟。
保留 PS MIO 基础设施，仅用于维持以太网 PHY 和 H16 外部时钟。验收时应提供：

- Vivado hierarchy/原理图中不存在 Processing System IP；
- 时钟来自 PL 外部管脚而非 PS FCLK；
- XSCT 写寄存器后 Linux 停止响应；
- ARM 已禁用后按 BTN0 重新运行，仍能完成完整推理；
- 保存 `A9_CPU_RST_CTRL=0x00000033` 的控制台证据。

## 4. 上板成功标准

- UART 输出 `SOC PREBOARD PASS`；
- `done_o=1`、`trap_o=0`；
- 完整验收运行期间两个 ARM 核保持 reset 和 clock-stop；
- 完整网络结果仍通过固件内 golden 比较；
- 保存综合 utilization、timing summary、层次图和串口日志用于报告。
