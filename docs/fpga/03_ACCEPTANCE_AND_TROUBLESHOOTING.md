# FPGA 验收与故障排查

## 1. 两种模式的合规边界

| 模式 | bit 下载者 | ARM 状态 | 用途 | 最终 ARM 禁用证据 |
|---|---|---|---|---|
| PYNQ 快速验证 | PYNQ Linux `Bitstream` | 正在运行 | 快速迭代 | 不能 |
| ARM 禁用验收 | PYNQ 初始化后由 XSCT 写 SLCR | 两核 reset 且 clock-stop | 最终独立运行 | 满足本项目方式 |

项目 RTL 已满足：无 PS7 实例、无 FCLK、无 PS AXI、无 PS DDR。最终验收再通过 XSCT
写 `A9_CPU_RST_CTRL(0xF8000244)=0x00000033`，同时置位两核 reset 和 clock-stop。

报告应分两层表述：

- **架构独立性**：RISC-V/APU 的取指、数据、时钟和外设路径不依赖 PS；
- **物理 ARM 状态**：`A9_RST0/1=1` 且 `A9_CLKSTOP0/1=1`；保留 PS MIO 基础设施仅用于
  维持板载 PHY/H16 时钟，不参与 PicoRV32/APU 的取指和数据访问。

## 2. 验收清单

### 2.1 构建证据

- `soc` Verilator 全回归通过；
- Vivado synthesis 成功，无 RAM 初始化文件缺失；
- implementation 成功；
- `WNS >= 0`、`TNS = 0`；
- 无关键 DRC；
- utilization 未超器件容量；
- hierarchy 中没有 `processing_system7`。

### 2.2 运行证据

- LED0 最终亮；
- LED1 始终灭；
- LED2 运行后亮；
- LED3 持续闪烁，LD4 最终显示绿色；
- SW0/SW1 读取阶段码 `7F`；
- BTN1 灯检可点亮 LED0..3；
- BTN0 可使系统重新执行；
- XSCT 禁用两个 A9 后，按 BTN0 重新运行仍完整通过；
- 保存 `A9_CPU_RST_CTRL=0x00000033` 的脚本和控制台记录；
- 保存阶段码、LED/RGB 照片、timing/utilization 截图。

## 3. Vivado 找不到 hex

现象：日志出现 `cannot open firmware.hex`、`cannot open model.hex` 或初始化警告。

```bash
make -C soc firmware model
wc -l soc/build/firmware.hex soc/build/model.hex
```

当前应分别为 16,384 行和 90,880 行。再确认 Sources 窗口中两个文件类型是
`Memory Initialization Files`。空 boot RAM 会使 PicoRV32 执行无效内容，不能忽略。

## 4. BRAM 超限

先检查工程是否定义 `FPGA_DISTRIBUTED_WEIGHT_RAM`，并确认
`model_rom.WORDS=90_880`。若层次报告中 64 个 `WeightSRAM` 仍各占 BRAM，说明宏或
`ram_style` 没生效。

若 LUTRAM 适配后仍超限，可行方向：

1. 根据实际栈需求缩小 64 KiB boot RAM，并同步修改 linker script；
2. 对模型格式做无损紧凑打包，再由 RISC-V 解包；
3. 增加 PL 可直接访问的外部 SPI Flash/SDRAM 扩展板；
4. 更换 BRAM 更多的 FPGA。

不能直接使用 PS DDR/QSPI/SD 并继续宣称完全脱离 PS，因为这些板载资源主要连接到 PS。

## 5. 实现时序不收敛

打开 `post_route_timing_summary.rpt`，记录起点、终点和逻辑级数：

| 路径 | 可能原因 | 处理方向 |
|---|---|---|
| `Ctrl` -> feature RAM | 地址计算组合级数深 | 等价流水或预计算优化 Ctrl |
| weight LUTRAM -> compute | LUTRAM 与阵列距离大 | 布局约束、增加寄存、评估 RAM 映射折中 |
| PicoRV32 -> interconnect | 地址译码扇出 | 局部寄存或简化 decode |
| reset path | 复位网络高扇出 | 检查同步释放，避免把复位当数据路径 |

外部 H16 仍是 8 ns 约束，SoC 内部时钟应由 MMCM 推导为 40 ns。若 CPU/APU 仍被分析为
8 ns，说明时钟生成或约束识别错误；UART 的 `CLK_HZ` 必须保持 `25_000_000`。

## 6. 四个 LED 都不亮

依次检查：

1. bit 顶层是否为 `pynq_z2_top`；
2. XDC 是否加载；
3. BTN0 是否卡住；
4. H16 是否有 125 MHz；
5. 以太网 PHY 是否被保持复位，因为 H16 时钟由 PHY 输出；
6. 用 ILA 或示波器观察 `clk_125mhz_i`；
7. 实现报告是否把时钟或端口优化掉。

先按住 BTN1；若四灯仍不亮，是 bit/顶层/XDC 问题。松开 BTN1 后 LED3 应闪烁，表示
MMCM 输出时钟持续运行。若 LED3 闪而 LD5 绿色不出现，继续查 PicoRV32、boot RAM 和
trap。

## 7. LED1 亮，PicoRV32 trap

常见原因：

- `firmware.hex` 未初始化或过期；
- linker script 与 boot RAM 大小不一致；
- 编译目标不是 `rv32imc/ilp32`；
- 时序违例导致取指/数据错误；
- 修改 C 后只复制 ELF，没有重建 bitstream。

比较 bit 与 `firmware.hex` 的生成时间，并确认反汇编入口 `_start` 位于地址 0。

## 8. UART 无输出，但 LED 有变化

本次验收不要求 UART。板载 J8 UART 属于 PS MIO，不能直接接收 PL `uart_tx_o`；没有
外置 USB-TTL 时直接按阶段码继续判断。若以后自备 USB-TTL，再检查：

- USB-TTL 必须是 3.3 V；
- W14/PMODB pin 1 接 USB-TTL RX，不是 TX；
- 两边必须共地；
- 参数为 115200 8-N-1；
- 不要使用板载 J8 PS UART 接收 PL TX；
- `CLK_HZ=25_000_000` 必须与 MMCM 输出一致；
- 先启动捕获，再按 BTN0 重新运行。

字符稳定但乱码时优先怀疑时钟/波特率不一致；完全无跳变时观察 W14。

## 9. APU PASS，但 LED0 不亮

完整网络之后还会运行 zero-conv 和 MMIO bridge。令 SW0=1，用 SW1 分别读取阶段码；
`B6` 表示完整网络 mismatch，`A1` 表示 zero-conv mismatch，`90..97` 表示 MMIO smoke
失败。`done_o` 只有固件向 EXIT 写入 0 后才为高，不能因为 LED2 亮就认为全部通过。

## 10. 建议保存的报告材料

```text
fpga/output/riscv_apu_pynq_z2.bit
fpga/output/reports/post_route_utilization.rpt
fpga/output/reports/post_route_timing_summary.rpt
fpga/output/reports/post_route_drc.rpt
soc/build/firmware.dis
SW0/SW1 阶段码与 LED/RGB 状态照片
Vivado hierarchy / schematic 截图
PYNQ-Z2 LED/RGB 最终状态照片
```

最终报告应同时覆盖工具链、机器码生成、BRAM 初始化、RISC-V 启动、总线访问、APU 推理、
golden 比较、FPGA 资源、时序和 ARM/PS 边界。

Zynq PS 复位、时钟和启动模式应查阅 AMD Zynq-7000 TRM UG585：
<https://docs.amd.com/r/en-US/ug585-zynq-7000-SoC-TRM>。

本工程实际使用的官方寄存器定义：

- `A9_CPU_RST_CTRL` 地址：
  <https://docs.amd.com/r/en-US/ug585-zynq-7000-SoC-TRM/Register-slcr-A9_CPU_RST_CTRL>
- `A9_RST0/1` 与 `A9_CLKSTOP0/1` 位定义：
  <https://docs.amd.com/r/en-US/ug585-zynq-7000-SoC-TRM/Register-A9_CPU_RST_CTRL-Details>
