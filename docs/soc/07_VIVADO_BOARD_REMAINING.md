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

1. 创建纯 RTL project，不添加 Zynq Processing System block design。
2. 顶层选择 `riscv_apu_board_top`。
3. 按板卡时钟设置 `CLK_HZ`，保持固件 UART 波特率与 `UART_BAUD` 一致。
4. 添加 `soc/build/firmware.hex` 和 `soc/build/model.hex` 为 memory initialization 文件；
   若 Vivado 工程工作目录不同，覆盖顶层参数 `FIRMWARE_INIT_FILE/MODEL_INIT_FILE`。
5. 编写 XDC：`clk_i`、`resetn_i`、`uart_tx_o`，可选 LED 对应 `done_o/trap_o`。
6. 添加主时钟约束并检查复位同步器路径。
7. 综合后检查 BRAM/DSP/LUT/FF 使用率和未约束端口。
8. 实现后检查 WNS/TNS；重点观察 Ctrl 到 Feature SRAM、APU bridge 和 PicoRV32 路径。
9. 生成 bitstream，下载后串口应依次打印完整 PASS 日志。

## 3. ARM PS 禁用验收

本工程的 PL 顶层没有 PS7/PS8 实例，也不依赖 `FCLK_CLK`、AXI GP/HP、DDR 或 ARM 软件。
验收时应提供：

- Vivado hierarchy/原理图中不存在 Processing System IP；
- 时钟来自 PL 外部管脚而非 PS FCLK；
- bitstream 下载后不启动 ARM 应用也能完成推理；
- 若教师明确要求“复位或时钟门控”的板级证据，按具体板卡说明 PS 未配置并保持复位。

## 4. 上板成功标准

- UART 输出 `SOC PREBOARD PASS`；
- `done_o=1`、`trap_o=0`；
- 无需运行任何 ARM 端程序；
- 完整网络结果仍通过固件内 golden 比较；
- 保存综合 utilization、timing summary、层次图和串口日志用于报告。
