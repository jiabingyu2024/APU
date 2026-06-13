# PYNQ 下载与 C 程序执行验证

## 1. 谁在执行 C 程序

| 处理器 | 开发期快速下载时的职责 | 是否执行 `soc/firmware/main.c` |
|---|---|---|
| Zynq ARM PS | 运行 PYNQ Linux/Python，把 bit 下载到 PL | 否 |
| PL 内 PicoRV32 | 配置后从 boot RAM 地址 0 取指并访问 APU | 是 |

`load_bitstream.py` 只完成 FPGA 配置，不会把 C 函数交给 ARM，也不会调用 APU。自主 SoC
成立的证据是 PicoRV32 固件通过自己的总线完成 RAM、RV32IM、timer、非法地址、完整 APU
推理和结果比较。

## 2. 硬件连接

### 2.1 基本连接

- J8 `PROG UART` 接电脑：供电和 JTAG；
- BTN0：PicoRV32 SoC 复位，按下复位，松开重新执行；
- LED0..LED3：查看 PASS/TRAP/APU/reset 状态。

### 2.2 PL UART 使用外部 USB-TTL

准备 **3.3 V TTL** 串口模块，禁止使用 5 V 电平。

| PYNQ-Z2 PMODB | USB-TTL | 作用 |
|---|---|---|
| pin 1 / W14 | RX | 接收 FPGA 的 `uart_tx_o` |
| pin 5 或 pin 11 | GND | 共地 |

本工程只有 TX，不需要把 USB-TTL TX 接回 FPGA。串口参数：

```text
115200 baud, 8 data bits, no parity, 1 stop bit, no flow control
```

## 3. 方法 A：PYNQ Python 快速下载

这是方便的开发验证方式，但 ARM/Linux 正在运行，不能单独作为“ARM 完全禁用”的最终
验收证据。

### 3.1 复制文件到 PYNQ Linux

至少复制：

```text
fpga/output/riscv_apu_pynq_z2.bit
fpga/pynq/load_bitstream.py
```

例如放到 `/home/xilinx/riscv_apu/`。不要求 `.hwh`，因为工程没有 PS AXI 寄存器图，
使用 `Bitstream` 类即可。

### 3.2 先打开串口捕获

在连接 USB-TTL 的电脑上安装 pyserial：

```bash
python3 -m pip install pyserial
```

Linux：

```bash
python3 fpga/host/capture_uart.py /dev/ttyUSB0 --timeout 30
```

Windows：

```powershell
python fpga/host/capture_uart.py COM5 --timeout 30
```

先启动捕获再配置 PL，避免漏掉开头日志。

### 3.3 在 PYNQ Linux 下载 bit

通过 SSH 或 Jupyter terminal 执行：

```bash
cd /home/xilinx/riscv_apu
python3 load_bitstream.py riscv_apu_pynq_z2.bit
```

脚本核心操作：

```python
from pynq import Bitstream
Bitstream("riscv_apu_pynq_z2.bit").download()
```

PYNQ `Bitstream` 类通过 Linux FPGA manager 把 bitstream 下载到 PL。配置释放后，PicoRV32
自动从 boot RAM 运行。若串口捕获启动晚了，按住 BTN0 再松开，固件会从头执行。

## 4. 正确结果

串口应包含：

```text
HELLO RISCV APU SOC
RAM BYTE/HALF/WORD PASS
RV32IM PASS
TIMER PASS cycles=0x........
DEFAULT SLAVE PASS
APU FULL NETWORK PASS
APU ZERO CONV PASS
APU MMIO BRIDGE PASS
SOC PREBOARD PASS
```

`capture_uart.py` 只有在所有关键 token 都出现时才返回成功。任何
`FAIL code=0x........` 都是失败。

| LED | 正确状态 | 含义 |
|---|---|---|
| LED0 | 最终亮 | 固件向 EXIT 寄存器写 0，全部测试通过 |
| LED1 | 始终灭 | PicoRV32 没有进入 trap |
| LED2 | 运行中变亮并保持 | APU 至少完成过一次计算 |
| LED3 | 未按 BTN0 时亮 | 25 MHz MMCM 已锁定且 SoC 已释放复位 |

判断优先级：UART 完整 PASS 日志 > LED0/LED1 > LED2。LED2 不能证明结果正确。

## 5. 如何证明 C 程序由 RISC-V 执行

建议保留：

1. `firmware.dis` 中 `_start`、`main`、`apu_run_full_network` 的 RISC-V 反汇编；
2. Vivado hierarchy 中 `picorv32 -> soc_interconnect -> native_to_apu_ahb -> Top`；
3. UART 首行和各测试 PASS；
4. LED1 未亮、LED0 最终亮；
5. 固件中故意改变一处测试常量后重新编译，串口行为随 RISC-V 固件变化，验证后恢复；
6. 完整网络 golden bit-exact 检查由 `main.c` 完成，而不是由 Python 比较。

第 5 项说明 bitstream 中的 boot RAM 内容确实发生变化，执行主体不是 ARM 上的固定 Python
测试脚本。

## 6. 修改 C 程序后的循环

修改 `soc/firmware/main.c` 后：

```bash
make -C soc firmware
CCACHE_DISABLE=1 make -C soc check
make -C fpga bitstream JOBS=4
```

然后重新复制并下载新的 bit。只复制新的 `.elf` 到板子不会改变 PicoRV32 程序，因为
firmware.hex 是 boot RAM 的配置初值。

模型参数变化时：

```bash
make -C soc model firmware
CCACHE_DISABLE=1 make -C soc check
make -C fpga bitstream JOBS=4
```

若 `MODEL_TOTAL_WORDS` 不再是 90,880，还要同步检查 `model_rom.WORDS` 和 BRAM 资源。

## 7. 最终验收：复位并停止两个 ARM 核

只做到“不运行 ARM 应用”不满足本项目要求。最终验收使用 UG585 定义的
`A9_CPU_RST_CTRL`：

| 位 | 名称 | 写入值 | 作用 |
|---:|---|---:|---|
| 5 | `A9_CLKSTOP1` | 1 | 停止 Cortex-A9 CPU1 时钟 |
| 4 | `A9_CLKSTOP0` | 1 | 停止 Cortex-A9 CPU0 时钟 |
| 1 | `A9_RST1` | 1 | CPU1 保持复位 |
| 0 | `A9_RST0` | 1 | CPU0 保持复位 |

寄存器绝对地址为 `0xF8000244`，最终值为 `0x00000033`。不设置 `PERI_RST`，因为
PYNQ-Z2 的 H16/125 MHz 来自以太网 PHY，而 PHY 复位由 PS MIO9 控制。复位整个 PS
可能使 PL 的时钟源消失。

### 7.1 验收操作顺序

1. 正常启动 PYNQ Linux，使板卡完成 MIO 和以太网 PHY 初始化。
2. 使用 `load_bitstream.py` 加载 bit，此时仅用于准备 PL，不作为最终运行结果。
3. 在 PYNQ Linux 执行 `sudo sync`，关闭 Jupyter/SSH 中正在写文件的任务。
4. 在连接同一块板卡 JTAG 的开发电脑上执行：

```bash
xsct fpga/xsct/disable_arm_cores.tcl
```

5. 脚本写入 `A9_CPU_RST_CTRL=0x33` 后，Linux 会立即停止响应，这是预期行为。
6. 开发电脑启动外部 USB-TTL 捕获。
7. 按住再松开 BTN0。BTN0 只接 PL 顶层，不会解除 ARM reset/clock-stop。
8. PicoRV32 在 ARM 已禁用的状态下重新执行完整 C 固件。
9. 验收 UART 九项 PASS、LED0 亮、LED1 灭、LED2 亮。

停止 Linux CPU 属于强制操作，先执行 `sync` 并备份重要 SD 卡数据。恢复 ARM 的最简单
方法是给板卡重新上电。

此方式不需要 HWH。PL 使用 H16 的 125 MHz 输入，经 MMCM 生成 25 MHz 驱动 SoC；两个
Cortex-A9 则保持复位且各自时钟停止。

最终报告应保存 XSCT 控制台输出，并记录 `A9_CPU_RST_CTRL` 写入值。应用架构仍无 PS7
实例、PS AXI、PS DDR 或 FCLK。

## 8. 为什么不能用 `Overlay.ip_dict` 验证 APU

典型 PYNQ overlay 是：

```text
ARM PS -> AXI GP -> AXI IP/APU
```

当前工程是：

```text
PicoRV32 -> native bus -> AHB bridge -> APU
```

ARM 与这条总线没有物理连接。因此 `Overlay.ip_dict` 中没有 APU 是正确现象。若为了
Python MMIO 增加 PS AXI，会改变验收架构，只能作为单独 debug build。
