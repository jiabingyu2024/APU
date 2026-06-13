# APU 二值神经网络加速器

本项目实现了一个面向 CIFAR-10 二值 ResNet 中间卷积层的 APU（AI Processing Unit）。
设计采用 64 bit 特征/权重粒度和 64 路输出通道并行计算，包含 AHB 配置接口、
指令执行、双 Feature SRAM、卷积计算阵列、累加、BN 等效比较、二值激活和残差路径。

当前验证基线覆盖固定网络中的 32/16/8 空间尺寸、64/128/256 通道、3x3 卷积、
stride 1/2 及下采样 residual 指令；不能仅根据 RTL 参数化形式推断其支持任意网络。

## 项目结构

```text
APU/
|-- Makefile                 # Verilator 编译、运行、回归入口
|-- rtl/                     # 可综合 SystemVerilog RTL
|   |-- Top_student.sv       # APU 顶层，连接 AHB、存储、控制和计算通路
|   |-- ahb_slave*.sv        # AHB 从设备及内部 RAM/寄存器访问控制
|   |-- addr_map.sv          # AHB 地址译码
|   |-- ram_mux.sv           # AHB 与 APU 对内部 RAM 的控制权复用
|   |-- WorkSheet.sv         # 16 深度指令 RAM 与顺序发射
|   |-- Ctrl.sv              # 卷积/残差调度、地址生成和流水控制
|   |-- FeatureProcessor.sv  # ActSRAM/OutSRAM 及卷积窗口读取
|   |-- InBuf.sv             # 计算输入选择、锁存与 residual replay
|   |-- WeightSRAM.sv        # 64 路权重 SRAM
|   |-- WeightBuffer.sv      # 权重读出缓冲
|   |-- ComputeCoreGroup.sv  # 64 路并行卷积计算阵列
|   |-- ComputeCore.sv       # 单输出通道计算核
|   |-- Multiplier.sv        # 二值乘法
|   |-- AdderTree.sv         # 64 路归约加法树
|   |-- Accumulator.sv       # 卷积项跨周期累加
|   `-- SIMD.sv              # BN 等效比较、激活及输出打包
|-- tb/
|   |-- tb_top_student.sv    # AHB 驱动、参数装载、执行和结果导出
|   `-- verilator_main.cpp   # Verilator 仿真入口
|-- scripts/
|   `-- compare_outputs.py   # 硬件输出与 golden 数据逐 bit 对拍
|-- data/
|   |-- param_files/         # 输入、卷积权重和 BN/SIMD 参数
|   `-- data_flow/           # 软件模型各层 golden 输出
|-- docs/                    # 架构、设计、仿真和历史问题文档
|-- soc/                     # PicoRV32 + APU 的 PL-only SoC、固件、模型打包和测试
|-- fpga/                    # PYNQ-Z2 顶层、XDC、Vivado Tcl 和上板辅助脚本
|-- third_party/picorv32/    # PicoRV32 上游源码（git submodule）
`-- build/                   # 自动生成的 Verilator 产物、波形和仿真输出
```

详细文档入口见 [docs/README.md](docs/README.md)。当前设计规范基线见
[docs/design/final/README.md](docs/design/final/README.md)。

## 快速上手

### 1. 环境依赖

需要 Linux/WSL 环境，并确保以下工具可从命令行直接调用：

- GNU Make
- Verilator 5.x
- 支持 C++17 的编译器（如 GCC/G++）
- Python 3

检查环境：

```bash
make --version
verilator --version
g++ --version
python3 --version
```

### 2. 编译仿真器

```bash
make
```

该命令读取全部 `rtl/*.sv`、`tb/tb_top_student.sv` 和
`tb/verilator_main.cpp`，生成 `build/verilator/Vtb_top`。Makefile 已启用
`--timing` 和 VCD trace；编译告警当前按非致命方式处理。

### 3. 运行完整仿真

```bash
make run
```

仿真平台通过 AHB 装载 `data/param_files/` 中的输入、权重、BN 参数和指令，执行
layer1 至 layer3，并将检查点写入 `build/sim/`。仿真正常结束必须由 testbench
执行到 `$finish`；若长时间只打印完成状态而不退出，应优先检查 Ctrl 指令完成条件、
WorkSheet 推进和 testbench completion timeout，而不是直接把它视为正常慢速运行。

### 4. 执行标准回归

```bash
CCACHE_DISABLE=1 make check
```

`make check` 会运行完整网络、补充运行一次 `+LAYER1_ONLY`，然后调用
`scripts/compare_outputs.py` 对以下六个检查点逐 bit 比较：

| 检查点 | 硬件输出 |
| --- | --- |
| `layer1.1_tanh3` | `build/sim/layer1.1_tanh3_hw.txt` |
| `layer2.1_tanh3` | `build/sim/layer2.1_tanh3_hw.txt` |
| `layer3.0_tanh1` | `build/sim/layer3.0_tanh1_hw.txt` |
| `layer3.0_tanh3` | `build/sim/layer3.0_tanh3_hw.txt` |
| `layer3.1_tanh1` | `build/sim/layer3.1_tanh1_hw.txt` |
| `layer3.1_bn3` | `build/sim/data_out.txt` |

每项均应显示 `PASS` 且 `bits=0`。`CCACHE_DISABLE=1` 用于规避部分环境中
Verilator 调用 ccache 时的缓存/权限问题；本机未使用 ccache 时可以直接执行
`make check`。

### 5. 清理生成文件

```bash
make clean
```

该命令删除整个 `build/`。之后再次执行 `make` 会完整重编译。

### 6. 运行 RISC-V 全自主 SoC

```bash
make soc-toolchain-check
make soc-firmware
make soc-bridge-check
make soc-uart-check
CCACHE_DISABLE=1 make soc-check
```

该回归在开发电脑上把参数文本打包为 363520-byte `model.hex`，交叉编译 RV32IMC 固件，
随后由 PicoRV32 自主装载并执行完整 12-op APU 网络。成功日志包含：

```text
APU FULL NETWORK PASS
APU ZERO CONV PASS
SOC PREBOARD PASS
```

SoC 实施细节见 [docs/soc/README.md](docs/soc/README.md)。

### 7. 创建 PYNQ-Z2 Vivado 工程

在安装了 Vivado 的环境中执行：

```bash
make -C fpga project
make -C fpga bitstream JOBS=4
```

脚本使用纯 PL 顶层，不实例化 Zynq Processing System；输出和报告位于
`fpga/output/`。完整步骤、PYNQ 下载方式、外部 PL UART 接线和 ARM/PS 验收边界见
[FPGA 上板文档](docs/fpga/README.md)。

初步上板频率为 25 MHz，由 H16 的 125 MHz 输入经 PL 内 MMCM 产生。最终验收在加载
bit 后通过 `fpga/xsct/disable_arm_cores.tcl` 将两个 Cortex-A9 同时保持复位并停止时钟，
再按 BTN0 重新运行 PicoRV32 固件。

## 常用定位入口

| 目标 | 建议先看 |
| --- | --- |
| 理解整机组成和数据通路 | [系统架构](docs/design/final/01_SYSTEM_ARCHITECTURE.md) |
| 理解 AHB 地址、启动和完成协议 | [编程模型](docs/design/final/02_PROGRAMMING_MODEL.md) |
| 理解 32 bit 指令字段和网络映射 | [指令与网络](docs/design/final/03_INSTRUCTION_AND_NETWORK.md) |
| 理解特征、权重和通道组布局 | [数据与存储布局](docs/design/final/04_DATA_AND_MEMORY_LAYOUT.md) |
| 理解 Ctrl 状态机和逐拍控制 | [控制与时序](docs/design/final/05_CONTROL_AND_TIMING.md) |
| 深入理解 Ctrl/InBuf 变量与地址映射 | [Ctrl 与 InBuf 设计](docs/design/Ctrl_InBuf_Design.md) |
| 理解 residual/shortcut 路径 | [Residual 路径](docs/design/final/07_RESIDUAL_PATH.md) |
| 理解 testbench 与回归标准 | [验证与重建](docs/design/final/08_VERIFICATION_AND_REBUILD.md) |

## 修改与验证约定

1. 修改 RTL 前先确认 `docs/design/final/` 中对应的接口、存储布局和时序合同。
2. 不要修改 `data/data_flow/` 的 golden 文件来掩盖 RTL mismatch。
3. 控制器、地址映射、通道组顺序或 residual 路径变化必须执行完整 `make check`。
4. `build/` 是生成目录，不应作为设计源文件维护；关键结论应记录到 `docs/`。
5. `docs/archive/` 只用于问题追溯，若与 `docs/design/final/` 冲突，以后者为准。
