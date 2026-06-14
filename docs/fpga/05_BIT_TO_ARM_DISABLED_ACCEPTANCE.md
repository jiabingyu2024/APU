# 从 bitstream 到 ARM 双核禁用验收

## 1. 目标与边界

最终运行链路是：

```text
板卡基础设施初始化
-> JTAG 下载纯 PL bitstream
-> XSCT 将两个 Cortex-A9 同时置于 reset + clock-stop
-> BTN0 只复位 PL
-> PL 内 PicoRV32 独立执行固件和 APU
-> 通过 LED/RGB/阶段码验收
```

目标寄存器状态：

```text
A9_CPU_RST_CTRL = 0x00000033
bit 5 A9_CLKSTOP1 = 1
bit 4 A9_CLKSTOP0 = 1
bit 1 A9_RST1     = 1
bit 0 A9_RST0     = 1
```

这满足“ARM 硬核保持复位且停止时钟”。它不等于复位整个 PS：PL 的 `H16` 125 MHz 来自
以太网 PHY，PHY reset/初始化涉及 PS MIO，必须保留相应基础设施。

## 2. 所需物品

1. PYNQ-Z2 和可正常启动的 SD 卡。
2. 一根支持数据的 Micro-USB 线，连接 `J8 PROG UART` 与电脑。
3. 安装 Vivado/Vitis/XSCT 的电脑。
4. 已通过实现和时序检查的 `fpga/output/riscv_apu_pynq_z2.bit`。

不需要外置 USB-TTL。J8 USB 用于供电、USB-JTAG 下载和 XSCT；板载 J8 UART 属于 PS
MIO，纯 PL `uart_tx_o` 不能直接接到它。

## 3. 首次下载与基础检查

1. 从 SD 卡启动 PYNQ Linux，等待板卡和以太网 PHY 初始化完成。
2. 打开 Vivado Hardware Manager，执行 `Open Target -> Auto Connect`。
3. 对 `xc7z020_1` 执行 `Program Device`，选择纯 PL bitstream。
4. 按住 BTN1，确认 LED0..3 全亮。此检查不依赖 H16/CPU/APU。
5. 松开 BTN1，令 SW0=0；LED3 应持续闪烁。
6. 正常约 0.2 秒内，LED0、LED2 亮，LED1 灭，LD4 绿色。
7. 令 SW0=1，SW1=0/1 分别读取阶段码低/高半字节，最终应为 `7F`。

如果 LED3 不闪，不要继续禁用 ARM。先检查 H16、PHY reset、MMCM、BTN0、顶层和 XDC。
详细定位见 [06_NO_USB_TTL_BOARD_DEBUG.md](06_NO_USB_TTL_BOARD_DEBUG.md)。

## 4. 禁用两个 Cortex-A9

禁用前在 Linux 执行：

```bash
sudo sync
```

停止会写 SD 卡的任务。随后在电脑端仓库根目录执行：

```text
xsct fpga/xsct/disable_arm_cores.tcl
```

Windows 示例：

```powershell
cd E:\path\to\APU
& 'D:\Xilinx\Vitis\2023.2\bin\xsct.bat' fpga/xsct/disable_arm_cores.tcl
```

期望输出包含：

```text
A9_CPU_RST_CTRL readback: ...00000033
Both Cortex-A9 cores are now held in reset with their clocks stopped.
```

部分 XSCT 版本在停止 CPU 时钟后无法再次访问 CPU target，可能报告 readback
unavailable。应保存完整输出，并确认写入前没有 JTAG/target 错误。

## 5. ARM 禁用后的最终重跑

1. 保持 J8 USB/JTAG 连接。
2. 确认 Linux/SSH/Jupyter 已停止响应。
3. 按下并松开 BTN0，仅重启 PL 内 SoC。
4. 观察 LED3 心跳、LD5 绿色 CPU alive、LED2/LD5 蓝色 APU seen。
5. 最终确认 LED0、LED2 亮，LED1 灭，LD4 绿色，阶段码为 `7F`。

BTN0 没有连接 Cortex-A9 reset，因此这次重新执行不会恢复 ARM。若阶段码不是 `7F`，按
[06_NO_USB_TTL_BOARD_DEBUG.md](06_NO_USB_TTL_BOARD_DEBUG.md) 读取失败阶段。

## 6. 验收证据

至少保存：

1. Vivado hierarchy/schematic 截图，证明无 `processing_system7`、无 PS AXI/FCLK/DDR。
2. post-route timing summary，证明 `WNS >= 0`、`TNS = 0`。
3. utilization 和 DRC 报告。
4. XSCT 写 `A9_CPU_RST_CTRL=0x00000033` 的控制台记录。
5. ARM 禁用后 BTN0 重跑的 LED/RGB 照片。
6. SW0/SW1 显示最终阶段码 `7F` 的照片。
7. `soc/build/firmware.dis`，证明 Boot RAM 中是 RISC-V 程序。

论证链：

```text
两个 Cortex-A9 reset + clock-stop
AND PL 不使用 PS AXI/FCLK/DDR
AND BTN0 后阶段码重新从 01 运行到 7F
=> 验证由 PL 内 PicoRV32/APU 独立完成
```

## 7. 常见问题

### XSCT 找不到 target

确认 J8 使用数据线、Hardware Manager 能 Auto Connect、板卡已上电，并避免多个 Vivado/
XSCT 进程同时占用 `hw_server`。XSCT 中的 `APU` target 指 Zynq Cortex-A9 Application
Processing Unit，不是本项目神经网络 APU。

### 禁用 ARM 后 LED3 不再闪

说明 H16/MMCM 失效。当前脚本只应写 `A9_CPU_RST_CTRL`；若额外复位 PS 外设或 PHY，
H16 可能消失。重新上电后按本文顺序重试，不要执行整个 PS reset。

### 如何恢复 Linux

断电重启。BTN0 只复位 PL，不能解除 Cortex-A9 的 reset/clock-stop。
