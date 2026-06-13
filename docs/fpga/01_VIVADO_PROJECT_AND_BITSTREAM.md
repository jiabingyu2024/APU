# PYNQ-Z2 Vivado 工程与 Bitstream

## 1. 本阶段要证明什么

软件和 RTL 仿真已经证明：PicoRV32 能执行固件，经片内总线配置 APU，并完成完整网络
和 golden 比较。Vivado 阶段要证明三件不同的事：

1. 全部 RTL 能映射进 `xc7z020clg400-1` 的 LUT、FF、BRAM 和布线资源；
2. 由外部 125 MHz 经 MMCM 生成的 25 MHz SoC 时钟下，`WNS >= 0` 且 `TNS = 0`；
3. `firmware.hex` 与 `model.hex` 被真实写入 FPGA 配置数据，而不是只在仿真中加载。

上板顶层为 `fpga/rtl/pynq_z2_top.sv`，不是 testbench，也不是
`riscv_apu_soc_top`。层次如下：

```text
pynq_z2_top
└── riscv_apu_board_top
    ├── riscv_apu_soc_top
    │   ├── picorv32_wrapper -> picorv32
    │   ├── boot_ram         <- firmware.hex
    │   ├── model_rom        <- model.hex
    │   ├── soc_interconnect / timer / console / default_slave
    │   ├── native_to_apu_ahb
    │   └── Top              -> APU
    └── uart_tx
```

## 2. 上板前生成软件镜像

在仓库根目录执行：

```bash
make -C soc toolchain-check
make -C soc firmware model
```

| 文件 | 含义 | 如何进入 FPGA |
|---|---|---|
| `soc/build/firmware.elf` | 带符号和段信息的 RISC-V 程序 | 调试/反汇编使用，不直接综合 |
| `soc/build/firmware.hex` | 16,384 个 32-bit 字 | `$readmemh` 初始化 `boot_ram` |
| `soc/build/model.hex` | 90,880 个 32-bit 字，含输入、权重、BN 和 golden | `$readmemh` 初始化 `model_rom` |
| `soc/build/firmware.dis` | RISC-V 反汇编 | 确认机器码和函数地址 |
| `soc/build/model_layout.h` | 各段模型数据的 word offset | 编译 `main.c` 时使用 |

完整链路：

```text
main.c/start.S
  -> riscv64-unknown-elf-gcc
  -> firmware.elf
  -> objcopy + makehex.py
  -> firmware.hex
  -> Vivado RAM INIT
  -> bitstream
  -> FPGA 配置完成
  -> PicoRV32 从 0x0000_0000 取第一条指令
```

当前版本每次修改 C 程序后，都要重新生成 `firmware.hex` 和 bitstream。目前没有实现
UART bootloader、JTAG debug module 或运行时程序加载器。

## 3. Vivado 文件清单

### 3.1 Design Sources

必须加入：

```text
third_party/picorv32/picorv32.v
soc/rtl/*.sv
rtl/*.sv
fpga/rtl/pynq_z2_top.sv
```

不要加入 `soc/tb/*.sv`、`tb/*.sv` 和 `build/verilator/*`。顶层设置为：

```text
pynq_z2_top
```

### 3.2 Memory Initialization Files

加入以下两个文件，并把文件类型设为 `Memory Initialization Files`：

```text
soc/build/firmware.hex
soc/build/model.hex
```

板级包装层传入稳定文件名 `firmware.hex` 和 `model.hex`。Vivado 将初始化文件复制到运行
目录，使 `$readmemh` 能找到它们。若日志出现 `cannot open file`，必须先修复，不能继续
生成一个内容为空的 bitstream。

### 3.3 Constraints

加入 `fpga/constraints/pynq_z2.xdc`：

| RTL 端口 | 板上资源 | 管脚 | 说明 |
|---|---|---|---|
| `clk_125mhz_i` | PL 125 MHz 输入 | H16 | 经 MMCM 生成 25 MHz SoC 时钟 |
| `btn0_i` | BTN0 | D19 | 按下为高，包装层反相成低有效复位 |
| `uart_tx_o` | PMODB pin 1 | W14 | 接外部 3.3 V USB-TTL RX |
| `led_o[0]` | LED0 | R14 | 全部固件检查通过 |
| `led_o[1]` | LED1 | P14 | PicoRV32 trap |
| `led_o[2]` | LED2 | N16 | APU 至少完成过一次 |
| `led_o[3]` | LED3 | M14 | MMCM 已锁定且当前已释放复位 |

板载 J8 USB-UART 接在 **PS MIO14/MIO15**，不是普通 PL 管脚，纯 PL 工程不能直接把
`uart_tx_o` 接到该串口。因此本方案使用 PMODB pin 1 和独立 USB-TTL 模块。

## 4. PYNQ-Z2 专用适配

### 4.1 复位极性和同步释放

BTN0 按下时输出高，而 SoC 的 `resetn_i` 低有效：

```systemverilog
assign resetn_board = ~btn0_i;
```

`riscv_apu_board_top` 内部再执行“异步拉低、同步释放”的两级同步，并使用
`ASYNC_REG` 属性提示 Vivado 正确放置。删除反相会导致未按键时一直复位；删除同步释放
会增加复位撤销时的亚稳态风险。

### 4.2 25 MHz 初步验证时钟

H16 仍输入板载 125 MHz，但 PicoRV32、总线、APU 和 UART 实际使用
`clock_gen_25mhz.sv` 产生的 25 MHz：

```text
125 MHz -> MMCME2_BASE: VCO 1000 MHz -> divide 40 -> BUFG -> 25 MHz
```

MMCM 参数为 `CLKFBOUT_MULT_F=8`、`DIVCLK_DIVIDE=1`、
`CLKOUT0_DIVIDE_F=40`。`clock_locked=0` 时 SoC 保持复位；锁定后再同步释放。
UART 的 `CLK_HZ` 同步设置为 `25_000_000`，波特率仍为 115200。

### 4.3 APU 完成脉冲锁存

`apu_done_o` 只持续很短时间，直接接 LED 肉眼不可见。`pynq_z2_top` 将其锁存到
`apu_seen_q`，直到按 BTN0 清除。LED2 只能证明 APU 曾完成，最终正确性仍以 LED0 和
UART 的 `SOC PREBOARD PASS` 为准。

### 4.4 BRAM 资源适配

XC7Z020 同时要容纳 boot RAM、模型 ROM、两块 feature SRAM 和 64 组权重 SRAM。已做
两项不改变算法的映射适配：

1. `model_rom` 深度由 128K word 收紧到实际的 `90_880` word；
2. Vivado 工程定义 `FPGA_DISTRIBUTED_WEIGHT_RAM`，把 64 组 `256x64` 权重 RAM 引导到
   LUTRAM，把 BRAM 留给大容量模型 ROM。

这只是资源规划，不等于已确认能放入。综合后必须检查层次化 utilization。如果 LUT
超限，需要进一步减少片上模型、压缩参数或添加 PL 可访问的外部存储，不能改用 PS DDR
却仍声称“脱离 ARM PS”。

## 5. Tcl 自动建工程

在装有 Vivado 的电脑上执行：

```bash
make -C fpga project
```

等价命令：

```bash
vivado -mode batch -source fpga/scripts/create_project.tcl
```

工程生成在：

```text
fpga/build/vivado/riscv_apu_pynq_z2.xpr
```

脚本自动完成器件选择、RTL 文件加入、hex 类型设置、XDC 加入、顶层设置和权重 RAM 宏
定义。需要 GUI 查看时打开该 `.xpr`，不要另建一份配置不同的工程。

### 5.1 Windows 的 `错误 9009`

若 PowerShell 输出：

```text
python3 tools/build_model_image.py ...
make[1]: *** [build/model.stamp] 错误 9009
```

表示 Windows 找不到 `python3.exe`，尚未进入 Vivado。先检查：

```powershell
python --version
py -3 --version
```

若 `python` 可用：

```powershell
make -C fpga project PYTHON=python VIVADO=vivado.bat
```

若只有 Windows Python Launcher `py` 可用，变量值包含空格，必须作为一个参数传给 make：

```powershell
make -C fpga project 'PYTHON=py -3' VIVADO=vivado.bat
```

可以先检查完整环境：

```powershell
make -C fpga environment-check 'PYTHON=py -3' VIVADO=vivado.bat
```

该检查还会验证 `riscv64-unknown-elf-gcc/objcopy/objdump`。Python 修好后若继续提示
`riscv64-unknown-elf-gcc` 找不到，说明 Windows 没有安装 RISC-V 裸机工具链。

### 5.2 推荐：WSL 生成软件，Windows 运行 Vivado

Vivado 通常安装在 Windows，而当前 RISC-V GCC 已安装在 WSL。无需再为 Windows 安装
一套 RISC-V 工具链，可以按下面分工。

先在 WSL 中进入同一个 E 盘工程：

```bash
cd /mnt/e/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU
make -C soc firmware model
```

确认生成：

```text
soc/build/firmware.hex
soc/build/model.hex
```

再回到 Windows PowerShell，跳过软件重建：

```powershell
cd E:\Resources\01_lessons\class2_NS\APU\finalTest\prj\APU
make -C fpga project-prebuilt VIVADO=vivado.bat
make -C fpga bitstream-prebuilt VIVADO=vivado.bat JOBS=4
```

`project-prebuilt/bitstream-prebuilt` 不调用 Python 或 RISC-V GCC，但 Tcl 会检查两个 hex 是否
存在。修改 C、模型参数或数据后，必须先回 WSL 重新生成 hex，再重新生成 bitstream。

如果 Vivado 尚未加入 PATH，可传完整路径，建议使用正斜杠：

```powershell
make -C fpga project-prebuilt `
  'VIVADO=D:/Xilinx/Vivado/2023.2/bin/vivado.bat'
```

将版本号和安装目录替换为实际值。若安装在带空格的目录，优先先运行 Vivado 的环境设置
脚本把 `vivado.bat` 加入 PATH，再使用 `VIVADO=vivado.bat`。

## 6. GUI 手工创建步骤

1. `Create Project`，选择 `RTL Project`。
2. Part 选择 `xc7z020clg400-1`；不要创建 Block Design。
3. 按第 3.1 节加入 Design Sources，确认 `.sv` 类型为 SystemVerilog。
4. 加入两个 hex，文件类型改为 `Memory Initialization Files`。
5. 加入 `fpga/constraints/pynq_z2.xdc`。
6. 将 `pynq_z2_top` 设为 Top。
7. 在 `Settings -> Synthesis -> Verilog Options` 增加宏
   `FPGA_DISTRIBUTED_WEIGHT_RAM`。
8. `Run Synthesis`，检查错误、资源和综合后时序。
9. `Run Implementation`，检查布局布线后时序和 DRC。
10. 只有 `WNS >= 0`、`TNS = 0` 且无关键 DRC 后，才生成 bitstream。

不要加入 Zynq Processing System IP、AXI Interconnect、Processor Reset System 或 PS FCLK，
否则工程已经变成 PS 控制的普通 PYNQ overlay。

## 7. 一键生成 bitstream

```bash
make -C fpga bitstream JOBS=4
```

等价命令：

```bash
vivado -mode batch -source fpga/scripts/build_bitstream.tcl -tclargs 4
```

主要输出：

```text
fpga/output/riscv_apu_pynq_z2.bit
fpga/output/riscv_apu_pynq_z2.xsa
fpga/output/pynq_z2_top_routed.dcp
fpga/output/reports/post_route_utilization.rpt
fpga/output/reports/post_route_timing_summary.rpt
fpga/output/reports/post_route_drc.rpt
fpga/output/reports/post_route_methodology.rpt
```

## 8. 综合和实现后必须检查什么

### 8.1 Memory 初始化

在 Vivado 日志搜索 `firmware.hex`、`model.hex`、`readmemh` 和 `WARNING`。确认没有文件
找不到、初始化行数不足或地址越界。若模型布局变化，还要同步修改 `model_rom.WORDS`，
并重新运行 Verilator 回归。

### 8.2 资源

重点查看 `Block RAM Tile`、`LUT as Memory`、`LUT as Logic`，并确认：

- `u_model_rom/mem` 主要使用 BRAM；
- `u_boot_ram/mem` 使用 BRAM；
- `gen_compute_core[*].u_weight_sram/rData` 使用 Distributed RAM/LUTRAM；
- 资源未超器件容量，并保留合理布线余量。

### 8.3 时序

外部输入周期是 8 ns；Vivado 应从 MMCM 自动推导 25 MHz、40 ns 的内部生成时钟。检查：

- `WNS >= 0 ns`；
- `TNS = 0 ns`；
- 没有 unconstrained internal endpoint；
- 重点路径是否仍是 `Ctrl` 到 `FeatureProcessor.featureMemory_data_out_reg`；
- LUTRAM 权重读取路径是否成为新的关键路径。

初步验收目标是内部 25 MHz 时钟收敛。不能因为外部端口约束仍为 8 ns，就误判 SoC 在
125 MHz 运行；应在 timing report 中确认 CPU/APU 寄存器属于 40 ns 的 MMCM 输出时钟。

## 9. HWH 为什么不是必需品

HWH 主要描述 Block Design 中可由 PS 访问的 AXI IP、地址段、中断和寄存器元数据。本
工程没有 PS-PL AXI 接口，也没有 ARM 可 MMIO 访问的 APU，因此：

- 纯 RTL 工程通常不会产生有用的 `.hwh`；
- PYNQ 下载可直接使用 `pynq.Bitstream` 和 `.bit`；
- 即使人为生成空 HWH，也不会让 Python 获得 PicoRV32/APU 的寄存器访问能力；
- 要让 ARM 通过 HWH/MMIO 控制 APU，就必须增加 PS AXI，这属于另一种架构。

构建脚本会在版本支持时导出 XSA，并写出 `HWH_NOT_REQUIRED.txt`，避免误把 HWH 缺失
判断为构建失败。

## 10. 官方参考

- AMD Vivado Synthesis UG901，外部文件初始化 RAM：
  <https://docs.amd.com/r/en-US/ug901-vivado-synthesis/Specifying-RAM-Initial-Contents-in-an-External-Data-File>
- PYNQ `Bitstream` API：
  <https://pynq.readthedocs.io/en/latest/pynq_package/pynq.bitstream.html>
- PYNQ Overlay 与 HWH/register map 示例：
  <https://pynq.readthedocs.io/en/latest/overlay_design_methodology/overlay_tutorial.html>
