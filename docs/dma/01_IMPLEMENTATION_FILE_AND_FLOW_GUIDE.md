# DMA 优化实施目录、文件清单与完整操作流程

## 1. 先建立正确的工程概念

这条支线最终会保留两个彼此独立的 Overlay：

| Overlay | 作用 | APU 接口 | 是否保留 |
|---|---|---|---|
| `apuYjb/myDesign.bit/.hwh` | 旧 MMIO/AHB 基线 | `APU_0`，PS GP0 经 AXI-to-AHB bridge | 原样保留 |
| `dma/overlay/apu_dma.bit/.hwh` | 新 DMA 方案 | 新 `APU_DMA_0`，AXI-Stream 数据面 | 新建 |

不要在旧 `myDesign` 工程上直接覆盖并继续使用同名 bit/hwh。正确做法是新建 DMA 工程、
新 IP 名称和新 Overlay 名称。这样出现错误时可以随时切回旧方案做 A/B 对比。

最终 `APU_DMA_0` 不直接实例化旧 AHB `APU_0`，而是复用其已经验证的叶子计算模块。
原因是旧 `APU_0` 的数据入口只有 32-bit AHB，并且上板版内部包含绝对地址 `hsel` 译码；
如果 DMA 仍绕回这条路径，带宽和地址耦合都会成为风险。

## 2. 预计最终项目结构

```text
APU/
├── rtl/                              # 现有 APU 叶子 RTL，原则上只读复用
│   ├── WorkSheet.sv
│   ├── Ctrl.sv
│   ├── InBuf.sv
│   ├── FeatureProcessor.sv
│   ├── ComputeCoreGroup.sv
│   ├── ComputeCore.sv
│   ├── WeightSRAM.sv
│   ├── WeightBuffer.sv
│   ├── SIMD.sv
│   ├── AdderTree.sv
│   ├── Multiplier.sv
│   └── Accumulator.sv
├── apuYjb/                           # 旧 Overlay 和驱动，基线只读
│   ├── myDesign.bit
│   ├── myDesign.hwh
│   ├── myDesign.tcl
│   └── apu_driver.py
├── dma/
│   ├── rtl/                          # 新 APU_DMA_0 的可综合 RTL
│   │   ├── apu_dma_pkg.sv
│   │   ├── apu_dma_top.sv
│   │   ├── apu_dma_core.sv
│   │   ├── axis_job_decoder.sv
│   │   ├── apu_stream_loader.sv
│   │   ├── apu_job_ctrl.sv
│   │   ├── axis_result_streamer.sv
│   │   ├── apu_dma_axil_regs.sv
│   │   └── apu_dma_perf_counters.sv
│   ├── tb/                           # 新流接口的自检验证
│   │   ├── tb_axis_job_decoder.sv
│   │   ├── tb_apu_stream_loader.sv
│   │   ├── tb_axis_result_streamer.sv
│   │   ├── tb_apu_dma_top.sv
│   │   ├── axis_source_bfm.sv
│   │   ├── axis_sink_bfm.sv
│   │   ├── filelist_dma.f
│   │   └── tests/                    # 合法包、短包、背压、复位、完整网络
│   ├── tools/
│   │   ├── build_job_image.py
│   │   ├── decode_result_image.py
│   │   └── compare_dma_output.py
│   ├── vivado/                       # PC/Vivado 工程侧
│   │   ├── create_dma_project.tcl
│   │   ├── package_apu_dma_ip.tcl
│   │   ├── create_dma_bd.tcl
│   │   ├── build_dma_bitstream.tcl
│   │   ├── report_dma_design.tcl
│   │   ├── constraints/
│   │   │   └── dma_timing.xdc
│   │   ├── ip_repo/                  # package_ip 生成物
│   │   ├── project/                  # Vivado 生成目录，不作为源文件权威版本
│   │   └── reports/                  # utilization/timing/DRC 原始报告
│   ├── overlay/                      # 上板必须成套携带
│   │   ├── apu_dma.bit
│   │   ├── apu_dma.hwh
│   │   └── build_manifest.json
│   ├── pynq/                         # PYNQ Linux/Python 交互侧
│   │   ├── apu_dma_driver.py
│   │   ├── dma_job.py
│   │   ├── dma_buffers.py
│   │   ├── dma_errors.py
│   │   ├── test_dma_loopback.py
│   │   ├── test_apu_dma_smoke.py
│   │   ├── inference_dma.py
│   │   └── evaluate_cifar10_dma.py
│   ├── benchmark/                    # 性能测试和报告生成
│   │   ├── benchmark_mmio.py
│   │   ├── benchmark_dma_raw.py
│   │   ├── benchmark_apu_e2e.py
│   │   ├── monitor_cpu.py
│   │   ├── generate_report.py
│   │   └── configs/
│   │       └── benchmark_sizes.json
│   ├── reports/                      # 板上测试 CSV/JSON/图表
│   │   ├── raw/
│   │   ├── figures/
│   │   └── final/
│   ├── Makefile
│   └── README.md
└── docs/dma/                         # 设计、操作和验收文档
```

这是预计结构，不要求第一天创建全部文件。文件应随着阶段推进落地，禁止先放空壳后无法
判断哪些部分真正完成。

## 3. 原有文件如何处理

### 3.1 原则上不修改

| 文件或目录 | 处理方式 | 原因 |
|---|---|---|
| `apuYjb/myDesign.bit` | 不修改 | 旧性能基线 |
| `apuYjb/myDesign.hwh` | 不修改 | 必须与旧 bit 配套 |
| `apuYjb/myDesign.tcl` | 不修改 | 保留旧 BD 的可追溯性 |
| `apuYjb/apu_driver.py` | 不修改 | 保留 MMIO 对比基线 |
| `rtl/Top_student.sv` | 首版不修改 | 避免影响现有仿真与 SoC 线 |
| `rtl/ahb_slave*.sv` | DMA 版不使用 | 仅属于旧 AHB 数据面 |
| `rtl/addr_map.sv` | DMA 版不使用 | 旧寄存器和 RAM window 译码 |
| `rtl/ram_mux.sv` | DMA 版不直接使用 | 新 loader 直接产生 RAM 访问控制 |

### 3.2 直接复用为 Vivado 源文件

新 `apu_dma_core.sv` 会实例化现有计算叶子模块。Vivado 工程可以直接引用根目录 `rtl/`
下的文件，不需要复制一份：

```text
WorkSheet.sv
Ctrl.sv
InBuf.sv
FeatureProcessor.sv
ComputeCoreGroup.sv
ComputeCore.sv
WeightSRAM.sv
WeightBuffer.sv
SIMD.sv
AdderTree.sv
Multiplier.sv
Accumulator.sv
```

是否还需要其他现有模块，应以 `apu_dma_core.sv` 的实际实例层次和 Vivado elaboration 为准。
如果后续发现现有叶子模块本身存在 DMA 无关 bug，才单独修改，并重新跑旧 AHB 与新 DMA
两条回归，不能顺手重构。

### 3.3 需要新建而不是修改旧文件

- 新建 `dma/rtl/apu_dma_core.sv`，从 `Top_student.sv` 提取协议无关的计算与 SRAM 集成；
- 新建 `dma/rtl/apu_dma_top.sv`，作为封装为 `APU_DMA_0` 的顶层；
- 新建 `dma/pynq/apu_dma_driver.py`，不把 DMA 逻辑塞进旧 `apu_driver.py`；
- 新建 `dma/vivado/*.tcl`，不覆盖旧 `myDesign.tcl`；
- 新 bit/hwh 使用 `apu_dma` 名称，不覆盖 `myDesign`。

## 4. 新 RTL 文件分别负责什么

| 文件 | 主要职责 | 输入/输出 |
|---|---|---|
| `apu_dma_pkg.sv` | packet opcode、状态码、宽度和版本常量 | 被全部 DMA RTL 引用 |
| `apu_dma_top.sv` | `APU_DMA_0` 顶层、时钟复位和模块连接 | AXIS slave/master + AXI-Lite slave |
| `apu_dma_core.sv` | APU 计算模块和 feature/weight/BN/worksheet RAM 集成 | 内部 RAM load/read 接口、start/done |
| `axis_job_decoder.sv` | 解析 job header、检查长度和 `TLAST` | DMA MM2S 的 AXI-Stream |
| `apu_stream_loader.sv` | 将 payload 写入指定 RAM/bank/address | decoder 命令 + 64-bit payload |
| `apu_job_ctrl.sv` | 执行 `LOAD/RUN/READ/END`，处理 timeout 和恢复 | command、APU done、result request |
| `axis_result_streamer.sv` | 从结果 RAM 读数据并输出 AXI-Stream | RAM read + DMA S2MM AXIS |
| `apu_dma_axil_regs.sv` | 版本、状态、错误、中断、计数器寄存器 | PS GP0 AXI-Lite |
| `apu_dma_perf_counters.sv` | 统计流字节、有效周期、停顿周期、任务周期 | AXIS handshake、job start/done |

首版采用单一 `FCLK_CLK0=100 MHz`，AXI DMA stream、`APU_DMA_0` 和 APU 计算核处在同一
时钟域。这样首版 RTL 不需要自行实现 CDC。若后续提高 APU 或 DMA 频率，必须在模块边界
增加 AXIS Clock Converter，并重新定义复位和计数器时钟域。

## 5. Vivado 工程侧负责什么

### 5.1 Vivado 侧的职责

Vivado 侧负责：

1. 编译 `dma/rtl/` 和复用的 `rtl/` 叶子模块；
2. 将 `apu_dma_top` 打包为自定义 IP `APU_DMA_0`；
3. 建立 PS7、AXI DMA、SmartConnect、FIFO、复位和中断连接；
4. 将 DMA memory mapped master 接到 PS HP 端口；
5. 分配 AXI-Lite 控制地址；
6. 综合、实现、检查时序和资源；
7. 生成匹配的 `.bit` 和 `.hwh`。

Vivado 不负责解析模型参数文本，也不负责调用推理。参数打包由 PC/PYNQ Python 工具完成，
DMA 只负责搬运已经排好格式的二进制 job buffer。

### 5.2 首版 Block Design 中的 IP

```text
processing_system7_0
axi_dma_0
smartconnect_ctrl             # GP0 -> DMA/APU_DMA AXI-Lite
smartconnect_mm2s             # DMA MM2S master -> PS S_AXI_HP0
smartconnect_s2mm             # DMA S2MM master -> PS S_AXI_HP1
axis_data_fifo_mm2s           # 可选但推荐，解耦 MM2S 与 APU_DMA
axis_data_fifo_s2mm           # 可选但推荐，解耦 APU_DMA 与 S2MM
xlconcat_irq
proc_sys_reset_0
APU_DMA_0
```

建议首版 AXI DMA 使用 Simple DMA 模式，同时启用 MM2S、S2MM 和中断。Scatter-Gather
不是达到 200 MB/s 的必要条件，而且会增加 descriptor 和驱动复杂度；在 Simple DMA、聚合
job 和中断等待无法满足 CPU 指标时，再把 SG 作为第二阶段优化。

### 5.3 Block Design 连接关系

控制路径：

```text
PS M_AXI_GP0
  -> SmartConnect
     -> axi_dma_0/S_AXI_LITE
     -> APU_DMA_0/S_AXI_CTRL
```

发送数据路径：

```text
PS DDR
  <- PS S_AXI_HP0
  <- axi_dma_0/M_AXI_MM2S

axi_dma_0/M_AXIS_MM2S
  -> AXIS Data FIFO
  -> APU_DMA_0/S_AXIS_JOB
```

接收数据路径：

```text
APU_DMA_0/M_AXIS_RESULT
  -> AXIS Data FIFO
  -> axi_dma_0/S_AXIS_S2MM

axi_dma_0/M_AXI_S2MM
  -> PS S_AXI_HP1
  -> PS DDR
```

中断路径：

```text
axi_dma_0/mm2s_introut ----+
axi_dma_0/s2mm_introut ----+-> xlconcat -> PS IRQ_F2P
APU_DMA_0/irq_error -------+
```

时钟复位：

```text
PS FCLK_CLK0 = 100 MHz
  -> DMA AXI-Lite/MM2S/S2MM
  -> SmartConnect/FIFO
  -> APU_DMA_0

PS FCLK_RESET0_N
  -> proc_sys_reset
  -> interconnect_aresetn/peripheral_aresetn
```

### 5.4 Vivado 文件的使用顺序

```text
package_apu_dma_ip.tcl
  -> 生成/更新 dma/vivado/ip_repo/APU_DMA

create_dma_project.tcl
  -> 新建独立 Vivado 工程并加入 IP repository

create_dma_bd.tcl
  -> 创建 PS7 + AXI DMA + HP + IRQ + APU_DMA_0 Block Design

build_dma_bitstream.tcl
  -> validate -> synth -> impl -> bitstream

report_dma_design.tcl
  -> 导出 timing/utilization/DRC/clock/interconnect 报告
```

即使用户最终在 GUI 中执行，Tcl 仍然是工程权威来源。GUI 修改验证有效后，应同步回 Tcl，
否则工程不能重建。

### 5.5 生成 bitstream 后必须取得的文件

```text
apu_dma.bit
apu_dma.hwh
timing_summary.rpt
utilization.rpt
drc.rpt
clock_interaction.rpt
build_manifest.json
```

`apu_dma.bit` 与 `apu_dma.hwh` 必须来自同一次构建并使用同一文件名主干。manifest 记录
Vivado 版本、Git commit、时钟、地址、SHA256 和构建时间。

## 6. PYNQ 交互侧负责什么

### 6.1 PYNQ 侧的职责

PYNQ Linux/Python 负责：

1. 加载 `apu_dma.bit/.hwh`；
2. 从 HWH 获取 `axi_dma_0` 和 `APU_DMA_0`；
3. 分配 CMA 连续物理内存；
4. 在 DMA buffer 中原位构造 job；
5. 先提交接收缓冲区，再发送 job；
6. 使用中断/异步等待完成并处理 timeout；
7. invalidate 接收 buffer 后解析结果；
8. 将结果交给 PyTorch 后处理；
9. 记录带宽、CPU、延迟、错误码和硬件计数器。

### 6.2 PYNQ 文件分别负责什么

| 文件 | 作用 |
|---|---|
| `dma_job.py` | 定义 header/opcode，计算 packet 长度，在 buffer 中原位写 job |
| `dma_buffers.py` | `pynq.allocate`、复用、flush/invalidate 和释放 |
| `dma_errors.py` | DMA 状态位和 `APU_DMA_0` 错误码翻译 |
| `apu_dma_driver.py` | Overlay、DMA、控制寄存器、提交、等待和结果读取 |
| `test_dma_loopback.py` | 只验 DDR-DMA-AXIS-DMA-DDR，不运行 APU |
| `test_apu_dma_smoke.py` | 最小已知任务和错误恢复 |
| `inference_dma.py` | 单图完整推理 |
| `evaluate_cifar10_dma.py` | 数据集准确率和稳定性测试 |

### 6.3 驱动调用顺序

```python
overlay = Overlay("apu_dma.bit")
driver = APUDMADriver(overlay)

tx = driver.allocate_tx(max_job_bytes)
rx = driver.allocate_rx(max_result_bytes)

job_bytes = driver.build_job_inplace(tx, input_tensor, parameters)
driver.submit_receive(rx, expected_result_bytes)  # 必须先接收
driver.submit_send(tx, job_bytes)
driver.wait(timeout_s=...)
result = driver.parse_result_inplace(rx)
```

真正的零拷贝要求 `build_job_inplace()` 直接写 `pynq.allocate` 返回的 NumPy view。下面这种
写法不算完整零拷贝：

```python
temporary_list -> np.array -> bytes -> copy into DMA buffer
```

参数文件可以在程序初始化时解析一次并缓存为已打包 NumPy 数组，不能在每张图执行期间
重新读取 24 个文本文件。

### 6.4 CPU 占用率为什么依赖中断

以下做法会提高 CPU 占用率：

- Python 循环读取完成寄存器；
- 无 sleep 的 `while dma_not_done`；
- 每个小 payload 单独提交一次 DMA；
- 每张图重新解析参数文本；
- 发送前反复创建临时 NumPy/bytes 对象。

驱动应优先使用当前 PYNQ 版本支持的中断或异步等待接口。如果板上 PYNQ DMA 驱动不支持
所需中断等待，则需要在 `apu_dma_driver.py` 中使用 UIO 中断，或者升级/补充驱动；不能用
忙轮询实现后仍宣称 CPU<10%。

## 7. PC、Vivado 和 PYNQ 板卡之间如何协作

| 工作 | 执行位置 | 主要输入 | 主要输出 |
|---|---|---|---|
| RTL 编写与仿真 | PC | `rtl/`、`dma/rtl/`、golden | 仿真日志和波形 |
| 参数/job 格式生成 | PC或PYNQ | `apuYjb/param/` | 二进制 job |
| IP 打包与 BD | Vivado/PC | RTL、Tcl | `.xpr/.bd` |
| 综合实现 | Vivado/PC | BD、RTL、XDC | bit/hwh 和报告 |
| Overlay 加载 | PYNQ | bit/hwh | PL 配置完成 |
| DMA 驱动和推理 | PYNQ Linux | Overlay、参数、图片 | 分类结果 |
| 板上性能测试 | PYNQ Linux | 测试脚本 | CSV/JSON |
| 报告汇总 | PC或PYNQ | CSV/JSON、Vivado reports | Markdown/图表 |

PS 在这条路线中必须运行 Linux 和 Python。它负责配置 DMA 和任务，但不再逐字搬运数据。
因此这条路线与之前“ARM 完全禁用”的纯 PL SoC 路线是互斥的验收方向。

## 8. 从零到完成的实际执行流程

### 阶段 A：保存旧基线

1. 确认旧 `myDesign.bit/.hwh` 可以加载；
2. 固定一张测试图和对应旧 APU 原始输出；
3. 记录旧 MMIO 输入、权重、输出搬运耗时；
4. 记录旧 Top-1/Top-5 和软件版本；
5. 保存 checksum 和原始 CSV。

完成标志：后续任何时候都能重跑旧 Overlay，并得到相同输出。

### 阶段 B：先做独立 DMA loopback

1. 建立只含 PS7、AXI DMA、AXIS FIFO/loopback 的临时 BD；
2. 连接 HP0/HP1、GP0 控制和 DMA 中断；
3. 生成 loopback bit/hwh；
4. 使用 CMA buffer 发送随机数据并原样接收；
5. 测量不同大小下带宽和 CPU。

完成标志：连续 1000 次数据一致，大块带宽 >=200 MB/s，DMA 等待窗口 CPU<10%。

这一阶段不含 APU。若这里不达标，应先修 DMA/HP/中断，不能进入 APU 调试。

### 阶段 C：冻结 job packet

1. 定义 header 字段和大小端；
2. 定义 input/weight/BN/instruction 的地址单位；
3. 定义 `RUN/READ_RESULT/END_JOB`；
4. 定义 result header、错误码和 sequence ID；
5. 生成合法/非法 packet 样例。

完成标志：同一个 job 可以被 Python 工具和 RTL testbench 一致解析。

### 阶段 D：实现流式 loader 和结果输出

1. 编写 decoder；
2. 编写 feature loader；
3. 编写 weight/BN/instruction loader；
4. 编写 result streamer；
5. 加入随机 `TREADY` backpressure；
6. 验证短包、错 `TLAST`、复位和恢复。

完成标志：RAM 内容与旧 MMIO 装载后的内容逐字一致。

### 阶段 E：接入真实 APU 计算核

1. 从现有 `Top_student.sv` 提取协议无关集成为 `apu_dma_core.sv`；
2. 复用现有计算叶子模块；
3. loader 获得 RAM 所有权时禁止计算核访问同一 RAM；
4. `RUN` 后切换 RAM 所有权并产生单周期 APU ready；
5. 完成后 result streamer 读取结果；
6. 与旧 MMIO/golden 做 bit-exact 对拍。

完成标志：完整网络输出逐字相同，而不仅是最终分类类别相同。

### 阶段 F：建立最终 Vivado DMA Overlay

1. package `APU_DMA_0`；
2. Tcl 创建独立工程和 BD；
3. 连接 AXI DMA、HP、GP、IRQ、时钟复位；
4. validate BD；
5. 综合并检查 RAM 推断；
6. 实现并检查 `WNS >= 0, TNS = 0`；
7. 生成 `apu_dma.bit/.hwh` 和报告。

完成标志：Tcl 可从空目录重建同一设计，bit/hwh 成套输出。

### 阶段 G：PYNQ 驱动与完整推理

1. 加载新 Overlay；
2. 校验 IP 名称、地址、DMA 通道和中断；
3. 跑最小 smoke test；
4. 跑完整单图并保存中间/最终输出；
5. 连续运行 1000 次；
6. 接入 CIFAR-10 评估。

完成标志：无 hang、DMA error、错帧，结果与旧路径 bit-exact。

### 阶段 H：流水和批处理优化

1. 参数解析和预打包只做一次；
2. 多个 packet 聚合为单个 job；
3. 使用 TX/RX ping-pong buffer；
4. 按计算段批量处理多张图片，使同一层权重加载一次服务 N 张图；
5. 统计 DMA stall、APU busy 和总周期，确认真正发生重叠。

完成标志：不仅 raw DMA 达标，实际 APU job 也具有稳定吞吐提升。

### 阶段 I：最终报告

1. 固定测试环境和版本；
2. 预热后重复测试；
3. 输出 min/avg/P95/P99/max；
4. 比较 MMIO 与 DMA 的带宽、CPU、延迟和资源；
5. 报告 Top-1/Top-5，不隐藏当前准确率基线；
6. 附原始 CSV/JSON 和 Vivado 报告。

完成标志：第三方按文档可以重新生成 bit、运行脚本并得到同口径结果。

## 9. 每个阶段预计产生哪些文件

| 阶段 | 新建/更新文件 |
|---|---|
| A 基线 | `benchmark_mmio.py`、`reports/raw/mmio_*.csv` |
| B loopback | `test_dma_loopback.py`、临时 loopback Tcl、`dma_raw_*.csv` |
| C 协议 | `apu_dma_pkg.sv`、`dma_job.py`、packet 文档和样例 |
| D 流接口 | decoder/loader/streamer RTL、对应 TB |
| E APU 接入 | `apu_dma_core.sv`、`apu_job_ctrl.sv`、完整顶层 TB |
| F Vivado | 4个主要 Tcl、XDC、IP repository、bit/hwh、实现报告 |
| G PYNQ | driver、buffer/error模块、smoke/inference/evaluate脚本 |
| H 优化 | batch/ping-pong 驱动逻辑和硬件性能计数器 |
| I 报告 | benchmark脚本、原始数据、图表和最终对比文档 |

## 10. 实施过程中谁操作什么

可以由代码和脚本准备的部分：

- 新 RTL、仿真文件和 packet 工具；
- Vivado 工程/IP/BD Tcl；
- PYNQ 驱动、功能测试和 benchmark；
- 文档、检查清单和报告模板。

需要用户在 Vivado/板卡上完成或确认的部分：

- 使用本机 Vivado 生成并查看工程；
- 检查 IP repository 和 BD 中的接口自动识别；
- 执行综合、实现和 bitstream；
- 将成套 bit/hwh 放到 PYNQ；
- 在真实 PYNQ 系统运行板上脚本；
- 将板上 CSV/JSON 和 Vivado 报告带回项目供最终分析。

正常协作顺序是：先提供阶段脚本和验收命令，用户只在必须接触真实 Vivado GUI 或板卡时
操作；每次板上反馈都保留原始日志，不依靠口头描述判断通过。

## 11. 完成整条支线的最终交付物

```text
1. 可综合、可仿真的 APU_DMA_0 RTL
2. 可从空目录重建的 Vivado Tcl 工程
3. apu_dma.bit + apu_dma.hwh + build manifest
4. PYNQ 零拷贝 DMA 驱动
5. loopback、smoke、完整网络和稳定性测试
6. 原始性能 CSV/JSON
7. Vivado timing/utilization/DRC 报告
8. AXI-Lite 与 DMA 性能对比报告
9. CPU<10% 和带宽>=200 MB/s 的测量证据
10. 已知限制、准确率状态和复现步骤
```

这十项全部具备，才能认为 DMA 支线完成。只有 AXI DMA 出现在 Block Design 中、或者单次
传输成功，都不能视为完成高性能数据流架构验收。
