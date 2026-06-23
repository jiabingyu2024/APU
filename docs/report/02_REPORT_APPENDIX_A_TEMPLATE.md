# 附录 A：实验报告结构模板

本文档是 DMA 选题实验报告的长文模板。它不是最终定稿，但已经按 15 页以上报告的结构组织，可以转成 Word 后补充截图、表格、Vivado 报告和个人表达。

建议正文标题保持以下结构：

1. 摘要与工作概述
2. 系统架构设计
3. 关键模块详细设计
4. 仿真与验证结果
5. 上板测试与性能数据
6. 遇到的问题与解决方案
7. 大模型辅助开发记录
8. 心得体会与建议
9. 参考文献

## 1. 摘要与工作概述

### 1.1 项目背景

随着神经网络模型在嵌入式端侧设备中的应用增多，如何在资源受限的 FPGA/SoC 平台上实现高效推理成为重要问题。本项目基于 PYNQ-Z2 的 Zynq-7000 SoC 平台，围绕二值神经网络推理加速器 APU 展开设计与验证。

项目早期已经具备一个基础 APU 计算核，该计算核能够执行二值卷积网络中的 feature 读取、权重读取、乘加归约、BN 阈值比较、二值激活和输出写回。原始上板验证路径使用 PS 侧 Python 程序通过 AXI-Lite/AHB/MMIO 方式访问 APU。该方式功能上可行，但传输效率较低，CPU 需要参与大量逐字读写和轮询等待，不能满足高性能数据流架构的要求。

本项目在保留基础 APU 计算核的前提下，设计并实现了一条 AXI-Stream + AXI-DMA 数据通路。PS 侧软件将一次推理任务组织为 job 数据块，AXI DMA 从 DDR 中读取 job 并以 AXI-Stream 形式送入 PL。PL 中新增的 `apu_dma` 自定义 IP 解析 job，执行参数加载、APU 启动、结果读取和 response 返回。最终结果再通过 AXI DMA 写回 DDR，由 Python driver 解析。

### 1.2 赛道要求对应关系

本项目对应赛道二：高性能数据流架构。赛道要求与本项目实现对应如下：

| 赛道要求 | 本项目实现 |
| --- | --- |
| 将 AXI-Lite 接口升级为 AXI-Stream + AXI-DMA | 使用 Xilinx AXI DMA IP，新增 `apu_dma_0` 自定义 AXI-Stream IP，旧 MMIO 路径作为对照 |
| 实现数据零拷贝高效传输 | 使用 PYNQ `allocate` 分配 DMA 可访问连续 DDR buffer，软件直接在 buffer 中构造 job，DMA 直接读写该 buffer |
| 设计流水线数据通路 | BD 中建立 MM2S job stream、APU 解析/执行、S2MM result stream，并加入 AXIS FIFO 缓冲 |
| 传输带宽 >= 200 MB/s | 50 MHz DMA transport 实测 `wall_mbps_mean=380.825 MB/s` |
| DMA 功能正常，CPU 占用率 <10% | 04 测试中 `wait_mode=interrupt`，`cpu_percent_mean=5.827%` |
| 提供详细性能测试报告 | 六个 final tests 输出 JSON 报告，并保存到 `dma/reports/final/` |
| 对比 AXI-Lite 与 DMA 方案性能差异 | 01/02/03 为旧方案，04/05/06 为 DMA 方案 |

### 1.3 本人完成的主要工作

本文报告的主要工作包括：

1. 梳理基础 APU RTL，明确计算核与外部数据搬运接口的边界。
2. 设计 APU DMA job/packet/header 协议，将 APU 加载、运行、读回结果抽象为 stream 命令。
3. 编写 DMA wrapper RTL，包括 `axis_job_decoder`、`apu_stream_loader`、`apu_job_ctrl`、`axis_result_streamer`、`apu_dma_axil_regs` 和 `apu_dma_perf_counters` 等模块。
4. 在 Vivado 中通过 Tcl 自动创建 block design，集成 PS7、AXI DMA、SmartConnect、AXIS FIFO、中断控制器和自定义 APU DMA IP。
5. 编写 PYNQ Python driver 和 final 测试脚本，完成旧 MMIO 路径与新 DMA 路径的功能和性能对比。
6. 定位并修复 residual replay 导致的个别 bit 输出不一致问题，确保 DMA 路径与旧路径输出对齐。
7. 整理项目文档、汇报材料和可复现实验命令。

## 2. 系统架构设计

### 2.1 整体系统框图

建议在报告中插入 `docs/dma/design/apu_dma_hardware_block_diagram.png`，并配合下面的简化框图说明。

```text
        +---------------------------+
        | PS: ARM + Linux + Python  |
        |                           |
        | final_tests / driver      |
        | PYNQ allocate DDR buffer  |
        +-------------+-------------+
                      |
          AXI-Lite control / interrupt
                      |
                      v
        +-------------+-------------+
        | Vivado IP Interconnect    |
        | SmartConnect + AXI INTC   |
        +-------------+-------------+
                      |
                      v
+---------------------+---------------------+
| PL data path                              |
|                                           |
| DDR -> AXI DMA MM2S -> AXIS FIFO ->      |
| apu_dma_0 -> AXIS FIFO -> AXI DMA S2MM   |
|                                           |
| apu_dma_0 internally controls original   |
| APU compute RTL                          |
+-------------------------------------------+
```

系统分为控制面和数据面：

- 控制面：PS 通过 AXI-Lite 配置 AXI DMA，读取 `apu_dma` 状态寄存器，配置中断控制器。
- 数据面：AXI DMA 通过 HP port 访问 DDR，将 job 以 AXI-Stream 送入 `apu_dma_0`，再将 response 写回 DDR。

这种划分符合 SoC 中常见的高性能外设设计方法：低速控制寄存器使用 AXI-Lite，高吞吐数据传输使用 AXI DMA 和 AXI-Stream。

### 2.2 旧方案架构

旧方案使用 `apuYjb/myDesign.bit`。PS 通过 PYNQ MMIO 访问 APU。

```text
Python
  -> MMIO write/read
  -> AXI-Lite / GP port
  -> AXI-to-AHB bridge
  -> APU AHB slave
  -> APU RAM/registers
```

旧方案的优点是简单，便于早期验证 APU 功能；缺点是数据搬运开销大。对于权重、BN、feature 等大量数据，CPU 需要反复执行寄存器访问，传输效率低，CPU 占用高。

### 2.3 新方案架构

新方案使用 `dma/overlay/apu_dma.bit`。PS 不再逐字写 APU RAM，而是在 DDR 中构造 job。

```text
Python builds job in DDR
  -> AXI DMA MM2S
  -> AXI-Stream job
  -> apu_dma_0
  -> original APU core
  -> AXI-Stream response
  -> AXI DMA S2MM
  -> DDR result buffer
```

`apu_dma_0` 是连接 AXI DMA 和原始 APU core 的关键桥梁。它接收 stream，不直接暴露大量 APU 内部 RAM 地址给 PS，而是通过 packet 协议在硬件内部完成解释和调度。

### 2.4 Vivado Block Design 组成

主要 Vivado IP：

| IP | 作用 |
| --- | --- |
| `processing_system7_0` | Zynq PS，运行 Linux/Python，连接 DDR |
| `axi_dma_0` | DDR 与 AXI-Stream 之间的数据搬运 |
| `smartconnect_ctrl` | AXI-Lite 控制总线互连 |
| `smartconnect_mm2s` | AXI DMA MM2S 读取 DDR 通路 |
| `smartconnect_s2mm` | AXI DMA S2MM 写回 DDR 通路 |
| `axis_fifo_job` | 输入 stream 缓冲 |
| `axis_fifo_result` | 输出 stream 缓冲 |
| `axi_intc_0` | 中断控制器 |
| `xlconcat_irq` | 合并多个中断源 |
| `proc_sys_reset_0` | 同步复位 |

自定义 IP：

| IP | 来源 | 作用 |
| --- | --- | --- |
| `apu_dma_0` | `dma/rtl` + `rtl` 封装 | 解析 DMA job，控制 APU，返回结果 |

### 2.5 时钟与频率

本设计采用单 PL 时钟域。`processing_system7_0/FCLK_CLK0` 连接主要 PL IP，包括 AXI DMA、SmartConnect、AXIS FIFO、`apu_dma_0`、中断控制器和 reset 模块。

`dma/vivado/create_apu_dma_project.tcl` 中已经将 PL 频率参数化。实际生成 bitstream 时可设置：

```powershell
$env:APU_DMA_PL_FREQ_MHZ = "50"
```

或在 Tcl 中修改统一频率参数。注意该频率会影响 Vivado BD 中接口 `FREQ_HZ` 元数据，也会影响性能报告中硬件计数器的换算。因此上板运行 04 测试时：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py --clock-mhz 50 ...
```

必须与 bitstream 实际频率一致。

## 3. 关键模块详细设计

### 3.1 APU 原始计算核

基础 APU RTL 位于顶层 `rtl/` 目录。它主要完成二值神经网络推理中的计算任务。

关键模块包括：

| 模块 | 作用 |
| --- | --- |
| `WorkSheet.sv` | 指令存储和指令发射 |
| `Ctrl.sv` | 控制 APU 计算流程、地址生成、写回调度 |
| `InBuf.sv` | 输入数据选择、缓存、residual replay |
| `FeatureProcessor.sv` | feature SRAM 读写和卷积窗口读取 |
| `ComputeCoreGroup.sv` | 多输出通道并行计算阵列 |
| `ComputeCore.sv` | 单通道二值卷积计算核心 |
| `Multiplier.sv` | 二值乘法逻辑 |
| `AdderTree.sv` | 归约加法树 |
| `Accumulator.sv` | 卷积累加 |
| `WeightSRAM.sv` | 权重存储 |
| `WeightBuffer.sv` | 权重读取缓冲 |
| `SIMD.sv` | BN 阈值比较、二值激活和输出打包 |

DMA 方案没有重写这些计算模块，而是在它们外部增加了高效数据搬运和命令调度逻辑。

### 3.2 APU DMA Packet 协议

AXI DMA 只搬运字节流，不知道 APU 内部结构。因此本项目定义了上层 packet 协议。

每条 packet 由两部分组成：

```text
4 beats header + optional payload
```

每个 beat 为 64 bit。header 中包含：

- magic：识别 job 或 response。
- version：协议版本。
- opcode：命令类型。
- target：目标 RAM 或 NONE。
- payload_bytes：payload 真实字节数。
- address：目标 RAM 内部 word 地址。
- element_count：元素数量。
- arg0：扩展参数，例如 bank 或 timeout。
- command_id：命令编号。
- sequence_id：job 编号。

主要 opcode：

| Opcode | 含义 |
| --- | --- |
| `LOAD` | 将 payload 写入 APU 内部 RAM |
| `RUN` | 启动 APU 执行指定数量 instruction |
| `READ_RESULT` | 从 APU feature RAM 读回结果 |
| `END_JOB` | 标记 job 结束 |

主要 target：

| Target | 含义 |
| --- | --- |
| `ACT` | activation/input feature RAM |
| `OUT` | output feature RAM |
| `WEIGHT` | 权重 SRAM |
| `BN` | BN/阈值参数 |
| `INSTRUCTION` | APU 指令 RAM |
| `NONE` | RUN 或 END_JOB 等不需要目标 RAM 的命令 |

这种设计把“软件想让 APU 做什么”编码进 stream，硬件再把 packet 翻译成 RAM 写、启动信号和结果读取。

### 3.3 `axis_job_decoder`

`axis_job_decoder` 是输入 stream 的第一站。它负责：

- 接收 AXI-Stream beat。
- 解析 4-beat header。
- 检查 magic、version、opcode、target、payload 长度、TLAST 等协议约束。
- 将命令元信息交给 `apu_job_ctrl`。
- 将 LOAD payload 透传给 `apu_stream_loader`。
- 出错时进入 drain 状态，丢弃当前 job 剩余数据直到 TLAST，避免 DMA 卡死。

它只做协议解析，不直接写 APU RAM，也不启动 APU。这样的拆分可以降低状态机复杂度。

### 3.4 `apu_stream_loader`

`apu_stream_loader` 负责执行 LOAD 命令，把 payload 写入 APU 内部 RAM。

它根据 target 选择写端口：

| Target | 写入端口 |
| --- | --- |
| `ACT` | activation RAM |
| `OUT` | output RAM |
| `WEIGHT` | weight SRAM，带 bank |
| `BN` | BN 参数 RAM，带 bank |
| `INSTRUCTION` | instruction RAM |

它还负责检查地址范围和 payload 长度。例如：

- ACT/OUT 是 64-bit word。
- WEIGHT 是 64-bit word。
- BN/INSTRUCTION 是 32-bit word，需要在 64-bit stream beat 中拆分低 32 bit 和高 32 bit。

### 3.5 `apu_job_ctrl`

`apu_job_ctrl` 是 DMA wrapper 的主状态机。它调度一个 job 的执行顺序。

主要状态包括：

```text
IDLE
LOAD_START / LOAD_WAIT
RUN_START / RUN_WAIT
READ_START / READ_WAIT
FINAL_START / FINAL_WAIT
ERROR_START / ERROR_WAIT
```

它的职责：

- 接收 decoder 输出的命令。
- 对 LOAD 命令启动 loader 并等待完成。
- 对 RUN 命令检查 instruction count 和 timeout，启动 APU core 并等待 done。
- 对 READ_RESULT 命令启动 result streamer。
- 对 END_JOB 命令返回 final response。
- 对 decoder、loader 或 core error 返回 error response。

该模块维护 job 级状态，例如 busy、sequence id、last error、job cycle count 等。

### 3.6 `apu_dma_core`

`apu_dma_core` 是 DMA wrapper 和原始 APU core 的边界模块。

它对外提供：

- loader 写端口：写 ACT/OUT/WEIGHT/BN/INSTRUCTION。
- core 控制端口：`core_start`、`core_done`、`core_busy`、`core_abort`。
- result streamer 读端口：从 ACT/OUT 中读回结果。

内部实例化原始 APU 计算模块。该模块的设计原则是尽量不改变原始 APU 计算行为，只增加外部访问和调度接口。

### 3.7 `axis_result_streamer`

`axis_result_streamer` 负责把结果打包为 AXI-Stream response。

对于 `READ_RESULT`：

```text
response header
result payload
```

对于 `END_JOB`：

```text
final response header with TLAST
```

对于错误：

```text
error response header with status code
```

Python 端 driver 读取 DMA S2MM buffer 后，按 response packet 协议解析数据。

### 3.8 `apu_dma_axil_regs` 与 `apu_dma_perf_counters`

`apu_dma_axil_regs` 暴露 AXI-Lite 状态寄存器和中断控制。PS 可通过它读取：

- IP ID 和版本。
- busy 状态。
- last error。
- 性能计数器。
- completed job 数量。
- error job 数量。

`apu_dma_perf_counters` 统计：

- RX bytes。
- TX bytes。
- busy cycles。
- MM2S stall cycles。
- S2MM stall cycles。
- completed/error jobs。

04 测试中的 `hardware_mbps_mean` 就依赖这些硬件计数器和 `--clock-mhz` 参数。

## 4. 仿真与验证结果

### 4.1 软件 golden 对齐

为了判断硬件输出是否正确，项目中建立了软件参考路径：

- `dma/sw/ideal_inference.py`
- `dma/sw/reference_model.py`
- `dma/sw/compare_hardware.py`

软件参考使用和 final tests 对齐的输入、权重和参数：

- 图片：`apuYjb/image/cifar10_test_image.jpg`
- checkpoint：`apuYjb/model_best.pth.tar`
- 参数目录：`apuYjb/param`

参考输出：

- ideal class：`plane`
- ideal APU output SHA256：`a236f489b1f93b1df7d9f801b436f70b644ab3874329ff13b2f979b7fd97c345`

这保证后续比较不是拿错误路径或 testbench 路径做参考，而是和实际板上 final tests 对齐。

### 4.2 Python 协议单元测试

`dma/tests/` 中包含 DMA job 构造和解析相关测试，用于验证 Python 侧协议和 RTL 侧协议常量一致。

测试重点：

- header 字段编码。
- payload 8 字节对齐。
- LOAD/RUN/READ_RESULT/END_JOB 顺序。
- response 解析。
- 异常长度和非法字段检查。

这些测试不代替 RTL 仿真，但能在上板前发现协议层错误。

### 4.3 RTL 级问题定位

项目曾出现 02 和 05 单图输出中个别 bit 不一致的问题。通过分层诊断，发现：

- `layer1.0.conv1` 到 `layer2.0.conv1` 输出一致。
- `layer2.0.conv2` 出现 mismatch。
- mismatch 集中在第二个 64-channel output group。

该现象指向 residual replay 相关逻辑，而不是权重、输入图片、BN 参数或输出顺序错误。最终定位到 `rtl/InBuf.sv` 中 residual replay 捕获/回放逻辑存在隐式状态和复位不完整风险。

修复方法：

- 将 residual replay 状态改为显式同步寄存器。
- 对 `main_select`、`replay_word0`、`replay_word1`、`count`、`rBuf` 等状态进行同步更新和复位。
- 保持原有 38/152 cycle 协议不变。

验证：

- 新增 `tb/tb_inbuf_replay.sv`。
- Icarus 运行通过，输出 `TB_INBUF_REPLAY_PASS`。
- `apu_dma_top` Icarus elaboration 通过。
- Python 协议测试通过。

该问题修复后需要重新 Vivado 综合、实现、生成 bit/hwh 并上板验证。

## 5. 上板测试与性能数据

### 5.1 测试环境

硬件平台：

- PYNQ-Z2 / Zynq-7000
- PS：ARM Cortex-A9 + DDR
- PL：自定义 APU + AXI DMA 数据通路

软件环境：

- PYNQ Python 虚拟环境：`pynq-venv`
- 测试目录：`/home/xilinx/jupyter_notebooks/APUdma`
- 本地报告目录：`dma/reports/final/`

### 5.2 最终六个测试命令

旧版 MMIO/AHB：

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100
```

新版 AXI-Stream + AXI-DMA：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py \
  --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

### 5.3 Final reports 输出位置

| 测试 | 输出文件 |
| --- | --- |
| 01 | `dma/reports/final/01_mydesign_benchmark.json` |
| 02 | `dma/reports/final/02_mmio_inference.json` |
| 03 | `dma/reports/final/03_mmio_evaluate.json` |
| 04 | `dma/reports/final/04_apu_dma_benchmark.json` |
| 05 | `dma/reports/final/05_dma_inference.json` |
| 06 | `dma/reports/final/06_dma_evaluate.json` |

### 5.4 传输层性能对比

旧版 01 结果摘要：

| 方向 | 规模 | 平均带宽 | CPU 占用 |
| --- | --- | --- | --- |
| PS->PL | 4096 bytes | 约 `0.785 MB/s` | 约 `99.6%` |
| PS->PL | 8192 bytes | 约 `0.787 MB/s` | 约 `99.8%` |
| PL->PS | 4096 bytes | 约 `0.236 MB/s` | 约 `99.9%` |
| PL->PS | 8192 bytes | 约 `0.232 MB/s` | 约 `99.3%` |

新版 04 结果摘要：

| 字段 | 数值 |
| --- | --- |
| `clock_mhz` | `50.0` |
| `wait_mode` | `interrupt` |
| `wall_mbps_mean` | `380.825 MB/s` |
| `hardware_mbps_mean` | `396.946 MB/s` |
| `cpu_percent_mean` | `5.827%` |
| `passes_200mbps_wall` | `true` |
| `passes_cpu_10percent` | `true` |

结论：

> DMA transport 相比旧 MMIO/AHB 逐字访问，传输带宽提升到数百 MB/s 量级，同时 CPU 占用从接近满占用降低到 10% 以下，满足赛道验收。

### 5.5 单图推理对比

| 测试 | 方案 | 预测类别 | APU 输出 SHA256 | 推理时间 |
| --- | --- | --- | --- | --- |
| 02 | MMIO/AHB | `plane` | `a236f489...c345` | 约 `2586 ms` |
| 05 | DMA | `plane` | `a236f489...c345` | 约 `147 ms` |

结论：

> 05 与 02 的预测类别和 APU 输出 SHA256 一致，说明 DMA wrapper 接入后没有改变 APU 计算结果。推理时间显著降低，说明 DMA 路径在实际单图流程中有效减少了数据搬运开销。

### 5.6 CIFAR-10 小样本评估对比

| 测试 | 方案 | 样本数 | Top-1 | Top-5 | 平均单图时间 |
| --- | --- | --- | --- | --- | --- |
| 03 | MMIO/AHB | 100 | `21.0%` | `95.0%` | 约 `2478 ms` |
| 06 | DMA | 100 | `21.0%` | `95.0%` | 约 `108.8 ms` |

结论：

> 03 与 06 的 Top-1/Top-5 一致，说明新旧硬件路径在应用级输出上对齐。DMA 方案显著降低平均单图耗时。

### 5.7 为什么 06 的带宽不能用于验收

06 的报告中应用级 `wall_mbps` 约为 `7.55 MB/s`，低于 04。这并不表示 DMA 通道不满足 200 MB/s。

原因是 06 测的是完整应用流程：

- 读取 CIFAR-10 数据集。
- 图像预处理和归一化。
- PyTorch 模型外层调度。
- 每张图构造 job。
- DMA buffer cache 维护。
- 结果解析。
- Top-1/Top-5 统计。
- Python 循环和打印。

这些开销不是 AXI DMA 纯数据通路本身。因此报告中要明确区分：

- 传输带宽和 CPU 占用验收：看 04。
- 单图功能正确性：看 02 vs 05。
- 应用端到端效果：看 03 vs 06。

## 6. 遇到的问题与解决方案

### 6.1 中断不可用问题

现象：

```text
Interrupt s2mm_introut not created
RuntimeError: DMA interrupts are unavailable
```

原因：

- `.hwh` 中中断连接信息不完整。
- Vivado BD 中 AXI DMA interrupt、`apu_dma` interrupt、AXI INTC、PS IRQ_F2P 没有正确连接。
- PYNQ 无法根据 hwh 创建 UIO interrupt。

解决方法：

- 在 BD 中使用 `xlconcat_irq` 合并 `mm2s_introut`、`s2mm_introut` 和 `apu_dma_0/irq`。
- 连接到 `axi_intc_0/intr`，再由 `axi_intc_0/irq` 连接 PS `IRQ_F2P`。
- 确保导出的 `.hwh` 与 `.bit` 一起更新到 `dma/overlay/`。
- 上板测试要求 `wait_mode=interrupt`。

### 6.2 BD 频率 metadata 不匹配

现象：

```text
FREQ_HZ does not match between /apu_dma_0/S_AXI_CTRL and /smartconnect_ctrl/M01_AXI
FREQ_HZ does not match between /apu_dma_0/aclk and /processing_system7_0/FCLK_CLK0
```

原因：

- PS FCLK 修改为 50 MHz。
- 自定义 IP 的接口 metadata 仍然保留旧频率，例如 25 MHz。

解决方法：

- 在 Tcl 中参数化 PL 频率。
- `package_apu_dma_ip.tcl` 和 `create_apu_dma_project.tcl` 使用同一个 `APU_DMA_PL_FREQ_MHZ`。
- 对 `apu_dma_0` 的 AXI/AXIS 接口设置一致的 `FREQ_HZ`。

### 6.3 输出个别 bit 不一致

现象：

- 02 和 05 单图最终判断曾出现不一致。
- 分层诊断定位到 `layer2.0.conv2` 的第二个 64-channel group 出现 mismatch。

原因：

- `rtl/InBuf.sv` residual replay 捕获/回放逻辑存在隐式状态和复位不完整风险。

解决方法：

- 将 residual replay 逻辑改成同步、可复位、显式寄存器实现。
- 新增专门 testbench 验证 replay 行为。
- 重新 Vivado 生成 bit/hwh 后上板复测。

### 6.4 CPU 占用曾高于 10%

现象：

04 早期结果中 `cpu_percent_mean` 可能高于 10%，即使 `wait_mode=interrupt`。

定位：

- profile 字段显示 DMA wait 本身 CPU time 很低。
- 主要开销来自每次 iteration 重新分配 RX CMA buffer。

解决方法：

- 在 benchmark/driver 层复用 RX buffer。
- 将 profile 字段加入 04 报告，区分 DMA wait、buffer allocate、flush/invalidate、parse 开销。

最终结果：

- `cpu_percent_mean=5.827%`
- `passes_cpu_10percent=true`

## 7. 大模型辅助开发记录

本项目开发过程中使用大模型辅助完成了以下工作：

1. 辅助梳理旧 APU RTL 和 DMA wrapper 的模块职责。
2. 辅助编写和整理 PYNQ 测试脚本，形成六个 final tests。
3. 辅助分析上板报错，例如中断不可用、CIFAR-10 数据路径错误、BD 频率不匹配。
4. 辅助设计性能报告字段，区分 wall 带宽、硬件计数器带宽和 CPU 占用率。
5. 辅助定位 02 和 05 输出 bit 不一致问题，并形成 residual replay 修复记录。
6. 辅助整理文档、答辩材料和项目结构。

需要说明的是，大模型只作为开发和文档辅助工具。关键结论仍然基于源码审查、仿真、Vivado 生成和 PYNQ 上板测试结果。报告中引用的性能数据来自 `dma/reports/final/` 下的实际测试 JSON。

## 8. 心得体会与建议

### 8.1 技术收获

通过本项目，我对 SoC 上软硬件协同设计有了更具体的认识。单独实现一个计算核并不等于系统性能高，数据如何进入计算核、结果如何返回、CPU 是否被解放、总线和 DMA 是否正确配置，都会直接影响最终系统性能。

AXI-Lite 适合做控制面，但不适合大量搬运数据。AXI-Stream + AXI DMA 更适合构建高吞吐数据面。为了让 stream 能控制复杂硬件，需要在其上定义清晰的 packet/job 协议。

### 8.2 工程经验

本项目也暴露了 FPGA 工程中的一些常见问题：

- `.bit` 和 `.hwh` 必须匹配，否则 PYNQ driver 无法正确识别 IP 和 interrupt。
- Vivado BD 中频率 metadata 不一致会导致 validate 失败。
- Windows 下 Vivado 工程路径过长可能引发工具问题。
- 单图输出不一致时不能直接猜 RTL，需要先用软件 golden 和分层诊断定位。
- 性能指标必须分清纯传输 benchmark 和应用级 evaluate，不能混用。

### 8.3 后续改进方向

后续可以从以下方向继续改进：

1. 提高 PL 时钟频率，探索 75 MHz、100 MHz 下的 timing 和性能极限。
2. 优化 Python driver，减少每张图 job 构造和结果解析开销。
3. 将更多前后处理移入 PL，减少 PS 端应用开销。
4. 使用 scatter-gather DMA 或双 buffer，提高连续多图推理吞吐。
5. 完善 RTL 仿真覆盖，增加 packet error、timeout、backpressure、interrupt 等场景。
6. 进一步优化 APU 计算核本身，提高模型准确率和计算效率。

## 9. 参考文献

报告中可引用以下资料：

1. AMD/Xilinx, *AXI DMA LogiCORE IP Product Guide*.
2. AMD/Xilinx, *AXI Reference Guide*.
3. AMD/Xilinx, *Zynq-7000 SoC Technical Reference Manual*.
4. PYNQ Documentation, Overlay, MMIO, DMA and Buffer APIs.
5. AMBA AXI and ACE Protocol Specification.
6. 本项目源码：`rtl/`、`dma/rtl/`、`dma/pynq/`、`dma/final_tests/`。
7. 本项目设计文档：`docs/dma/design/`。
8. 本项目测试报告：`dma/reports/final/`。

## 附：可直接放入报告的结论段

本文完成了基于 PYNQ-Z2 的 APU + DMA 高性能数据流架构设计。相较于旧版 AXI-Lite/AHB/MMIO 逐字访问方案，新方案使用 AXI DMA 和 AXI-Stream 进行大块数据搬运，并通过自定义 `apu_dma` IP 将 stream job 翻译为 APU 内部 RAM 写入、计算启动和结果读回操作。实验结果表明，在 50 MHz PL 时钟下，DMA transport 的真实 wall 带宽达到 `380.825 MB/s`，CPU 占用率为 `5.827%`，满足传输带宽不低于 `200 MB/s` 且 CPU 占用率低于 `10%` 的验收要求。同时，DMA 单图推理结果与旧 MMIO 路径输出 SHA256 一致，CIFAR-10 100 张小样本评估 Top-1/Top-5 与旧方案一致，说明新数据通路在显著提升传输性能的同时保持了 APU 计算功能正确性。

