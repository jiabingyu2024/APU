# 从 bitstream 到 ARM 完全禁用验收

本文面向第一次使用 PYNQ-Z2 上板的用户。目标不是让 ARM 运行 APU，而是：

```text
PYNQ Linux 先完成板卡初始化
-> JTAG 下载纯 PL bitstream
-> XSCT 将两个 Cortex-A9 同时置于 reset + clock-stop
-> 按 BTN0 只复位 PL
-> PL 内 PicoRV32 独立运行并完成 APU 验证
```

最终 ARM 状态为：

```text
A9_CPU_RST_CTRL = 0x00000033
bit 5 A9_CLKSTOP1 = 1
bit 4 A9_CLKSTOP0 = 1
bit 1 A9_RST1     = 1
bit 0 A9_RST0     = 1
```

这同时满足“时钟停止”和“保持复位”，比只停止 Linux 进程更严格。

## 0. 最短操作卡

首次操作建议完整阅读后文。熟悉后按以下八步执行：

1. 确认使用 `fpga/output/riscv_apu_pynq_z2.bit`，不是 `apuYjb/myDesign.bit`。
2. PYNQ-Z2 插 SD 卡正常启动 Linux，J8 Micro-USB 保持连接电脑。
3. USB-TTL 只接 `PMODB pin 1 -> RX`、`PMODB GND -> GND`，不接 VCC/TX。
4. Vivado Hardware Manager 通过 JTAG 下载 bit。
5. 先按 BTN0，确认 UART 九项 PASS 和 LED0/2/3 亮、LED1 灭。
6. Linux 执行 `sudo sync`，电脑端启动 UART 捕获。
7. 电脑执行 `xsct fpga/xsct/disable_arm_cores.tcl`，Linux 随即停止响应。
8. 再按 BTN0；若仍得到九项 PASS，即完成 ARM reset + clock-stop 状态下的最终验收。

USB-TTL 只用于观察日志。真正下载 bit 和禁用 ARM 的控制路径都是 J8 上的 JTAG。

## 1. 先确认使用的是哪一种 bit

本文只适用于仓库生成的纯 PL bit：

```text
fpga/output/riscv_apu_pynq_z2.bit
```

它的顶层必须是 `pynq_z2_top`，内部包含 PicoRV32、boot RAM、model ROM 和 APU，且
Vivado hierarchy 中没有 `processing_system7`。

如果使用的是 `apuYjb/myDesign.bit` 或含 Zynq PS/AXI 的 Block Design overlay，则不是本文
的自主 PicoRV32 方案，关闭 ARM 后 Python、MMIO 驱动和分类程序都会停止。

## 2. 需要准备的东西

### 2.1 必需

1. PYNQ-Z2 和装有 PYNQ Linux 的 SD 卡。
2. 一根数据功能正常的 Micro-USB 线，连接板上 `J8 PROG UART` 与电脑。
3. 安装了 Vivado/Vitis 2023.2 或兼容版本的电脑。
4. 已通过实现和时序检查的 `riscv_apu_pynq_z2.bit`。

J8 同时提供供电、JTAG 和 PS 串口。本文使用其中的 JTAG，不使用板载 PS 串口观察 PL
程序输出。

### 2.2 强烈建议：3.3 V USB-TTL 模块

USB-TTL 是一个把 FPGA 的 3.3 V 串行信号转换为电脑 USB 串口的小模块。购买时搜索：

```text
CP2102 USB TTL 3.3V
CH340 USB TTL 3.3V
FT232 USB TTL 3.3V
```

必须确认其 RX 输入兼容 **3.3 V TTL**。不要使用 RS-232 模块，也不要接 5 V 信号。

只接两根信号线：

| PYNQ-Z2 PMODB | USB-TTL | 说明 |
|---|---|---|
| pin 1，板级信号 W14 | RX/RXD | FPGA 向电脑发送日志 |
| pin 5 或 pin 11 | GND | 两块设备共地 |

以下引脚不要连接：

- USB-TTL 的 TX/TXD：本工程没有 UART RX，不需要。
- USB-TTL 的 5V、3V3/VCC：PYNQ 已由 J8 供电，禁止再次供电。

以板上 PMODB 丝印和 pin 1 标记为准，不要只按照片方向猜引脚。

没有 USB-TTL 也可以先看 LED，但不能取得完整九项 PASS 日志，最终验收证据不充分。

## 3. 第一次操作：先验证 bit 能运行

### 3.1 启动板卡

1. 插好 PYNQ Linux SD 卡。
2. 将启动模式设为从 SD 卡启动。
3. 用 J8 Micro-USB 连接电脑并给板卡上电。
4. 等待 PYNQ Linux 正常启动。

先让 Linux 启动是为了初始化 PS MIO 和板载以太网 PHY。PL 使用的 H16 125 MHz 时钟来自
该 PHY。后面只停止两个 ARM 核，不复位 PS 外设，因此 H16 可以继续工作。

### 3.2 使用 Vivado Hardware Manager 下载 bit

在电脑上打开 Vivado：

1. `Open Hardware Manager`。
2. 选择 `Open Target -> Auto Connect`。
3. 在器件 `xc7z020_1` 上选择 `Program Device`。
4. Bitstream file 选择 `fpga/output/riscv_apu_pynq_z2.bit`。
5. 点击 `Program`。

本纯 RTL 工程不需要 `.hwh`，也不需要在 Vivado 中打开 Block Design。

下载完成后 PicoRV32 会自动开始执行。此时 ARM/Linux 仍在运行，这一步只用于确认 bit
本身可工作，不是最终验收。

### 3.3 观察 LED

| LED | 预期 | 含义 |
|---|---|---|
| LED3 | 亮 | H16/MMCM 正常，PL 已释放复位 |
| LED2 | 运行后亮 | APU 至少完成过一次 |
| LED1 | 始终灭 | PicoRV32 没有 trap |
| LED0 | 最终亮 | 全部固件检查通过 |

如果 LED3 不亮，先不要执行 ARM 禁用。优先检查 bit 顶层、XDC、H16 时钟和 BTN0。

## 4. 配置 USB-TTL 日志捕获

将 USB-TTL 插入电脑后查看串口号：

- Windows：设备管理器中的 `COMx`，例如 `COM5`。
- Linux：通常是 `/dev/ttyUSB0` 或 `/dev/ttyACM0`。

电脑安装 pyserial：

```bash
python -m pip install pyserial
```

Windows PowerShell 示例：

```powershell
python fpga/host/capture_uart.py COM5 --timeout 60
```

Linux 示例：

```bash
python3 fpga/host/capture_uart.py /dev/ttyUSB0 --timeout 60
```

串口参数已经固定为 `115200, 8 data bits, no parity, 1 stop bit`。先启动捕获程序，再按下并
松开 BTN0，避免漏掉启动日志。

正确日志应包含：

```text
HELLO RISCV APU SOC
RAM BYTE/HALF/WORD PASS
RV32IM PASS
TIMER PASS
DEFAULT SLAVE PASS
APU FULL NETWORK PASS
APU ZERO CONV PASS
APU MMIO BRIDGE PASS
SOC PREBOARD PASS
```

先在 ARM 仍运行时得到一次完整 PASS，可以排除 bit、串口接线和固件本身的问题。

## 5. 最终操作：禁用两个 ARM 核

### 5.1 禁用前准备

1. 保持 J8 Micro-USB 与电脑连接，JTAG 必须可用。
2. 保持刚才下载的 bit 在 PL 中运行。
3. 在 PYNQ Linux 中执行：

```bash
sudo sync
```

4. 停止正在写 SD 卡的 Jupyter/SSH 任务。
5. 在电脑端先启动 USB-TTL 捕获。

执行下一步后 Linux、SSH 和 Jupyter 会立即失去响应，这是预期现象。

### 5.2 运行 XSCT 脚本

在安装了 Vitis/XSCT 的电脑终端中，进入仓库根目录：

```text
xsct fpga/xsct/disable_arm_cores.tcl
```

Windows 常见命令：

```powershell
cd E:\path\to\APU
& 'D:\Xilinx\Vitis\2023.2\bin\xsct.bat' fpga/xsct/disable_arm_cores.tcl
```

按实际 Vivado/Vitis 安装路径修改。若 `xsct` 已加入 PATH，可直接使用第一条命令。

期望控制台输出包含：

```text
Unlocking SLCR...
Asserting reset and stopping clocks for both Cortex-A9 cores...
A9_CPU_RST_CTRL readback: ...00000033
Both Cortex-A9 cores are now held in reset with their clocks stopped.
```

部分 XSCT 版本在停止 CPU 时钟后无法继续读取目标，脚本可能输出
`post-disable readback unavailable`。只要写操作前没有 JTAG/target 错误，这通常是停止时钟后
CPU target 消失造成的。保存完整控制台输出作为证据。

### 5.3 在 ARM 已禁用时重跑 PicoRV32

1. 确认 SSH/Jupyter 已断开。
2. 保持 USB-TTL 捕获程序运行。
3. 按住 BTN0 一秒后松开。
4. 等待完整九项 PASS。
5. 确认 LED0、LED2、LED3 亮，LED1 灭。

BTN0 只连接 PL 顶层，不会解除 Cortex-A9 的 reset 或 clock-stop。因此这次日志是在两个
ARM 核已经禁用的状态下，由 PL 内 PicoRV32 重新执行得到的。

## 6. 如何证明 ARM 确实没有参与

最终报告至少保存：

1. Vivado hierarchy 截图，证明没有 `processing_system7`，只有纯 PL PicoRV32/APU。
2. `post_route_timing_summary.rpt`，证明 `WNS >= 0`、`TNS = 0`。
3. XSCT 控制台记录，证明写入 `A9_CPU_RST_CTRL=0x00000033`。
4. XSCT 执行后 Linux/SSH 立即停止响应的记录。
5. ARM 禁用后按 BTN0 得到的完整 UART 九项 PASS 日志。
6. 最终 LED 状态照片：LED0/2/3 亮、LED1 灭。
7. `soc/build/firmware.dis`，证明运行代码是 RISC-V 指令。

关键论证链：

```text
两个 Cortex-A9 reset + clock-stop
AND PL 不使用 PS AXI/FCLK/DDR
AND BTN0 后仍能重新输出完整 PASS
=> 完整验证由 PL 内 PicoRV32/APU 独立完成
```

## 7. 常见问题

### 7.1 XSCT 提示找不到 APU target

检查：

1. J8 是否为支持数据的 USB 线；
2. Vivado Hardware Manager 是否能 `Auto Connect`；
3. 板卡是否已上电；
4. 是否有其他 Vivado/XSCT 进程独占 `hw_server`；
5. 关闭 Hardware Manager target 后重试 XSCT。

这里的 XSCT target 名称 `APU` 指 Zynq 的 Application Processing Unit，即两个 Cortex-A9，
不是本项目的神经网络 APU。

### 7.2 禁用 ARM 后 LED3 熄灭

LED3 熄灭说明 H16/MMCM 或 PL 复位出现问题。当前脚本只写 `A9_CPU_RST_CTRL`，不应复位
PS 外设。如果额外执行了 PS 全复位或关闭 PHY，H16 可能消失。重新上电后按本文顺序重试，
不要写 `PERI_RST`。

### 7.3 禁用 ARM 后如何恢复 Linux

给板卡断电并重新上电。普通 BTN0 只复位 PL，不能恢复 ARM。

### 7.4 没有 USB-TTL，能否完成验收

只能完成弱验收：XSCT 写寄存器后，按 BTN0，观察 LED0/2/3 亮且 LED1 灭。LED 不能显示
九个测试分别是否通过，也无法保存完整运行日志，因此建议购买一个 3.3 V USB-TTL 模块。

### 7.5 能否关闭整个 PS

不建议。本板 PL 的 H16 125 MHz 时钟来自以太网 PHY，而 PHY 初始化/复位涉及 PS MIO。
当前合规方案是停止并复位两个 ARM 核，保留必要的 PS 基础设施和 PHY 时钟。它满足
“ARM 硬核完全禁用”，但不等于整块 PS 断电。
