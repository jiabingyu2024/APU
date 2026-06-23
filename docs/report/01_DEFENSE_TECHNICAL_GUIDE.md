# APU + DMA 主线答辩技术指南

这份文档的目标不是替代源码，而是帮助你在面对老师技术提问时能讲清楚三件事：

1. 这个项目到底做了什么。
2. APU + DMA 主线是怎么工作的。
3. 六个 final 测试分别验证什么，结果应该怎么解释。

## 1. 一句话概括

本项目先实现了一个面向二值神经网络推理的 APU 硬件计算核，然后在 PYNQ-Z2 上完成两条验证路径：

- 旧路径：`myDesign.bit`，PS 通过 AXI-Lite/AHB/MMIO 逐字访问 APU 内部寄存器和存储空间。
- 新路径：`apu_dma.bit`，PS 使用 AXI DMA 将大块 job 数据从 DDR 搬到 PL，PL 内自定义 `apu_dma` IP 解析 job、写入 APU RAM、启动 APU、读回结果，再通过 DMA 写回 DDR。

汇报时可以这样说：

> 我的核心改进不是重写卷积计算阵列，而是把原来 CPU 逐字 MMIO 搬运数据的方式，升级成 AXI-Stream + AXI-DMA 的大块传输方式。原始 APU 计算核仍然负责二值卷积和 BN/激活，新增 DMA wrapper 负责协议解析、数据装载、运行调度、结果返回和性能计数。

## 2. 总体架构

```text
------------------------+                 +-------------------------+
| PS / ARM Linux Python |                 | PL / FPGA               |
|                        | AXI-Lite ctrl   |                         |
| final_tests / driver   |---------------> | AXI DMA + apu_dma regs  |
|                        |                 |                         |
| DDR job buffer         | AXI DMA MM2S    | axis_fifo_job           |
| PYNQ allocate buffer   |===============> | apu_dma_0/S_AXIS_JOB    |
|                        |                 |                         |
| DDR result buffer      | AXI DMA S2MM    | apu_dma_0/M_AXIS_RESULT |
| PYNQ allocate buffer   |<=============== | axis_fifo_result        |
+------------------------+                 +-------------------------+
                                                     |
                                                     v
                                           +--------------------+
                                           | Original APU core  |
                                           | WorkSheet/Ctrl     |
                                           | InBuf/FeatureProc  |
                                           | ComputeCoreGroup   |
                                           | SIMD               |
                                           +--------------------+
```

从 Vivado Block Design 角度看：

- `processing_system7_0`、`axi_dma_0`、`smartconnect_*`、`axis_fifo_*`、`axi_intc_0`、`proc_sys_reset_0` 是 Vivado/Xilinx IP。
- `apu_dma_0` 是你封装的自定义 IP。
- `apu_dma_0` 内部包含新增 `dma/rtl` wrapper，以及原始 `rtl/` 下的 APU 计算模块。

## 3. 旧版 MMIO 为什么慢

旧版 `myDesign` 的路径是：

```text
Python driver
  -> PYNQ MMIO write/read
  -> PS M_AXI_GP0
  -> AXI-to-AHB-Lite bridge
  -> APU AHB slave
  -> APU internal RAM/registers
```

它的特点是：

- CPU 需要频繁调用 Python MMIO 函数。
- 每次写入或读取通常只搬一个 32-bit word 或一小段 burst。
- CPU 需要轮询等待 APU 完成，`wait_mode=polling`。
- 数据搬运和等待都消耗 CPU time。

所以旧版的测试结果中，带宽只有 MB/s 以下量级，CPU 占用接近 100%。这不是 APU 卷积阵列本身一定很慢，而是 PS 到 PL 的数据通路太低效。

## 4. 新版 DMA 为什么快

新版 DMA 路径是：

```text
Python builds a job in DDR buffer
  -> cache flush
  -> AXI DMA MM2S reads DDR through HP port
  -> AXI-Stream sends job to apu_dma_0
  -> apu_dma_0 decodes packets and controls APU
  -> apu_dma_0 streams response
  -> AXI DMA S2MM writes result to DDR
  -> interrupt wakes Python
  -> cache invalidate and parse result
```

它的关键优势：

- 大块数据由 AXI DMA 搬运，不由 CPU 逐字搬运。
- PS 和 PL 之间的数据面走 AXI DMA + HP DDR port。
- 控制面仍然使用 AXI-Lite，但只用于配置 DMA、读状态和中断，不搬大块数据。
- 等待使用 interrupt，CPU 不需要长时间 polling。
- job buffer 是 PYNQ `allocate` 得到的连续物理内存，DMA 可以直接访问，避免中间拷贝。

“零拷贝”在本项目中的准确说法是：

> 软件直接在 DMA 可访问的 DDR buffer 中构造 job，DMA 直接从这个 buffer 读数据并把结果写回另一个 DMA buffer。CPU 仍然要做图像预处理、job 构造、cache flush/invalidate 和结果解析，但不再用 CPU 把大块参数和 feature 逐字写入 PL 寄存器。

## 5. Job、Packet、Header 是什么

这些不是 AXI DMA 官方固定术语，而是本项目为了让 APU 能通过 stream 被控制而定义的上层协议。

AXI DMA 只理解“从 DDR 读一段字节，变成 AXI-Stream”以及“把 AXI-Stream 写回 DDR”。它不知道什么是权重、BN、输入 feature、运行 APU、读取结果。

因此我在 DMA 数据流上定义了 packet 协议：

- `job`：一次完整 APU 推理任务，由多条 packet 组成。
- `packet`：job 内的一条命令，例如 LOAD、RUN、READ_RESULT、END_JOB。
- `header`：每个 packet 开头固定 4 个 64-bit beat，用来描述命令类型、目标 RAM、payload 长度、地址、数量、bank、command id 等。
- `payload`：LOAD 命令后面跟随的真实数据，例如输入 feature、weight、BN、instruction。

典型 job 顺序是：

```text
LOAD ACT input
LOAD WEIGHT bank0..63
LOAD BN bank0..63
LOAD INSTRUCTION
RUN
... 多个 stage 重复 ...
READ_RESULT ACT
END_JOB
```

硬件中对应关系：

- `axis_job_decoder.sv`：解析 header/payload。
- `apu_stream_loader.sv`：执行 LOAD，把 payload 写入 APU 内部 RAM。
- `apu_job_ctrl.sv`：调度 LOAD/RUN/READ_RESULT/END_JOB。
- `axis_result_streamer.sv`：把读取结果封装成 response packet。

## 6. Packet Header 为什么要 8 字节对齐

本项目 AXI-Stream 数据宽度是 64 bit，即每个 beat 是 8 byte。payload 的真实字节数可能不是 8 的倍数，比如 BN 和 instruction 是 32-bit 数据。DMA/AXIS 传输仍然按 64-bit beat 前进，所以要把 payload 占用空间补齐到 8 byte 边界。

代码中：

```text
padded_payload_bytes(bytes) = (bytes + 7) & ~7
```

意思是向上取整到 8 的倍数：

- 如果 `bytes=8`，加 7 得 15，清掉低 3 bit 后还是 8。
- 如果 `bytes=9`，加 7 得 16，清掉低 3 bit 后是 16。
- 如果 `bytes=15`，加 7 得 22，清掉低 3 bit 后是 16。

加 7 的原因是“向上取整”。`~7` 的作用是清掉低 3 bit，使结果一定是 8 的倍数。

## 7. 六个 final 测试的定位

最终汇报只使用 `dma/final_tests/` 下 6 个脚本。

### 01 `01_mydesign_benchmark.py`

目的：测旧版 `myDesign.bit` 的 MMIO/AHB 传输带宽基线。

测什么：

- PS->PL 写入带宽。
- PL->PS 读取带宽。
- CPU 占用率。

它不关心 CIFAR-10 分类准确率，只回答“旧传输通道有多慢”。

本地 final 报告里旧版典型结果：

- PS->PL 4096/8192 bytes 规模约 `0.78 MB/s`。
- PL->PS 4096/8192 bytes 规模约 `0.23 MB/s`。
- CPU 占用约 `95%~100%`。

答辩口径：

> 01 是旧接口传输层基线，用来证明 AXI-Lite/AHB/MMIO 逐字搬运不适合高吞吐数据通路。

### 02 `02_mydesign_inference.py`

目的：旧版 `myDesign.bit` 单图推理功能测试，同时保留旧输出格式。

输入：

- 图片：`apuYjb/image/cifar10_test_image.jpg`
- 权重：`apuYjb/model_best.pth.tar`
- APU 参数：`apuYjb/param`

输出：

- LogSoftmax 十分类结果。
- 预测类别。
- APU 输入/输出 SHA256。
- 增量传输统计。

本地 final 报告结果：

- `prediction=0`
- `class=plane`
- `apu_output_sha256=a236f489...c345`
- 推理时间约 `2586 ms`
- 传输带宽约 `0.150 MB/s`
- CPU 占用约 `98.7%`

答辩口径：

> 02 用来证明旧版硬件功能是可运行的，同时作为单图输出对齐基线。

### 03 `03_mydesign_evaluate.py --samples 100`

目的：旧版 `myDesign.bit` 在 CIFAR-10 测试集小样本上的端到端评估。

为什么不是全量：

- CIFAR-10 全测试集是 10000 张。
- 旧版 MMIO 单图很慢，全量耗时过长。
- 汇报阶段用 `--samples 100` 得到可复现实验数据。

本地 final 报告结果：

- `samples=100`
- `top1_percent=21.0`
- `top5_percent=95.0`
- 平均单图推理约 `2478 ms`
- 传输带宽约 `0.156 MB/s`
- CPU 占用约 `100%`

答辩口径：

> 03 是旧版应用级效果基线，和 06 对比可以说明 DMA 方案在完整推理流程中的速度提升。

### 04 `04_apu_dma_benchmark.py`

目的：DMA 传输通道的核心验收测试。

推荐命令：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py \
  --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
```

为什么 04 是核心验收：

- 它专门测 DMA transport，不混入 CIFAR-10 数据集读取、图像预处理、PyTorch 外层循环等应用开销。
- `wall_mbps_mean` 是真实端到端 DMA transport 带宽。
- `cpu_percent_mean` 是传输期间 CPU 占用。
- `wait_mode` 必须是 `interrupt`，否则 CPU 占用不具备验收意义。

本地 final 报告结果：

- `clock_mhz=50.0`
- `wait_mode=interrupt`
- `wall_mbps_mean=380.825 MB/s`
- `hardware_mbps_mean=396.946 MB/s`
- `cpu_percent_mean=5.827%`
- `passes_200mbps_wall=true`
- `passes_cpu_10percent=true`

答辩口径：

> 技术要求中的“传输带宽 >=200 MB/s”和“CPU 占用率 <10%”主要看 04。我的 50 MHz DMA transport 实测 wall 带宽约 380.8 MB/s，CPU 占用约 5.83%，满足验收要求。

### 05 `05_apu_dma_inference.py`

目的：新版 `apu_dma.bit` 单图推理功能测试，对齐 02 的输入、权重和输出。

输入与 02 相同：

- 图片：`apuYjb/image/cifar10_test_image.jpg`
- 权重：`apuYjb/model_best.pth.tar`
- APU 参数：`apuYjb/param`

本地 final 报告结果：

- `prediction=0`
- `class=plane`
- `apu_output_sha256=a236f489...c345`
- 推理时间约 `147 ms`

关键意义：

- 05 的 APU output SHA256 和 02 一致，说明 DMA 路径没有改变推理功能。
- 02 和 05 同样输出 `plane`，说明新旧路径在单图分类结果上对齐。

答辩口径：

> 05 不是纯传输带宽验收，而是证明 DMA wrapper 接入后，APU 的实际推理输出和旧 MMIO 路径一致。

### 06 `06_apu_dma_evaluate.py --samples 100`

目的：新版 `apu_dma.bit` 在 CIFAR-10 小样本上的端到端评估。

本地 final 报告结果：

- `samples=100`
- `top1_percent=21.0`
- `top5_percent=95.0`
- 平均单图推理约 `108.8 ms`
- 应用级 transfer wall 带宽约 `7.55 MB/s`

为什么 06 的带宽远低于 04：

- 06 是完整应用流程，不是纯 DMA transport。
- 它包含数据集读取、图像预处理、PyTorch 调度、逐图构造 job、结果解析、Top-1/Top-5 统计、Python 循环开销。
- 每张图的有效 DMA 数据量较小，外层软件开销被放大。
- 04 使用大 job 和 repeats 聚合，更接近 DMA 通道吞吐上限。

答辩口径：

> 06 用来看完整推理流程是否能跑通、准确率是否与旧版一致、端到端速度是否提升。验收“DMA 带宽 >=200 MB/s”和“CPU <10%”不看 06，主要看 04。

## 8. 六个测试之间的结论关系

| 对比 | 旧版 | DMA 版 | 说明 |
| --- | --- | --- | --- |
| 传输通道性能 | 01 | 04 | 核心性能验收 |
| 单图功能正确性 | 02 | 05 | 证明新旧输出对齐 |
| 应用级评估 | 03 | 06 | 证明完整流程速度提升且精度一致 |

最终结论可以这样组织：

- 功能：05 与 02 单图输出 SHA256 一致，03 与 06 的 Top-1/Top-5 一致，说明 DMA 接入没有破坏 APU 功能。
- 性能：04 的 wall bandwidth 超过 200 MB/s，CPU 占用低于 10%，说明 DMA 数据通路满足验收。
- 对比：旧版 01/02/03 中 CPU 接近满占用、带宽低；DMA 版 04/05/06 显著改善传输效率和端到端速度。

## 9. 老师可能追问的问题

### Q1：AXI-Lite 和 AXI-Stream 的区别是什么？

AXI-Lite 是低吞吐控制总线，适合读写寄存器，比如启动、状态、配置。它没有 burst，数据宽度和事务能力有限。

AXI-Stream 是流式数据接口，只表达 `TVALID/TREADY/TDATA/TKEEP/TLAST` 这类流握手，不带地址，适合连续数据。AXI DMA 负责在 DDR 的地址空间和 AXI-Stream 之间转换。

本项目中：

- AXI-Lite 用于配置 `axi_dma_0`、读取 `apu_dma_0` 状态和中断控制。
- AXI-Stream 用于传输 APU job 和 response。

### Q2：AXI DMA 做了什么？

AXI DMA 是 Xilinx IP，负责：

- MM2S：从 DDR 读 job buffer，输出 AXI-Stream。
- S2MM：接收 AXI-Stream response，写回 DDR result buffer。

它不理解 APU 指令和权重含义，只负责搬字节。APU 语义由 `apu_dma_0` 内部 RTL 解释。

### Q3：为什么需要自定义 packet 协议？

因为 AXI-Stream 本身没有地址，也没有“写哪个 APU RAM”“启动几条 instruction”“读多少结果”的语义。packet 协议把这些语义编码到 header 中，硬件 decoder 再把它翻译成 APU 内部 RAM 写、core start、result read。

### Q4：为什么 04 的 `hardware_mbps_mean` 和 `wall_mbps_mean` 不完全一样？

`hardware_mbps_mean` 根据 PL 内部 `busy_cycles` 和 `--clock-mhz` 计算，反映硬件数据面忙碌期间的吞吐。

`wall_mbps_mean` 根据 Python 端实际 wall time 计算，包含 DMA 配置、cache flush/invalidate、等待、结果解析等开销。

验收带宽主要看 `wall_mbps_mean`，因为它更接近真实系统端到端传输。

### Q5：为什么 `--clock-mhz` 要和 bitstream 一致？

硬件计数器记录的是周期数。要把周期数换算成秒，需要知道实际 PL 时钟频率。如果 50 MHz bit 却传 `--clock-mhz 25`，`hardware_mbps_mean` 会算错一倍。`wall_mbps_mean` 不依赖这个参数。

### Q6：为什么 DMA 版 accuracy 和旧版一样？

因为 DMA 改的是数据搬运和调度方式，不改变原始 APU 的二值卷积、BN、激活和输出逻辑。03 与 06 的 Top-1/Top-5 一致，02 与 05 的单图 SHA256 一致，说明 DMA wrapper 没有改变计算语义。

### Q7：为什么 Top-1 只有 21%？

这个指标是当前 APU/模型/量化/测试配置下的小样本结果，重点不是追求软件模型最高准确率，而是验证硬件路径对齐。因为旧版和 DMA 版用同一输入、同一权重、同一参数，且结果一致，所以它能作为硬件功能一致性的证据。

### Q8：如果中断不可用会怎样？

如果 PYNQ 无法从 `.hwh` 识别中断或 UIO 没创建成功，driver 可能退化为 polling 或直接报错。CPU `<10%` 的验收必须建立在 interrupt wait 上。之前遇到过 `DMA interrupts are unavailable`，需要检查 hwh/bit 中 interrupt controller、PS IRQ_F2P、AXI DMA interrupt、apu_dma irq 是否正确连接。

### Q9：为什么路径太长会影响 Vivado？

Vivado 在 Windows 下对工程路径、IP cache、generated files 的路径长度比较敏感。项目中 Vivado Tcl 建议从较短路径运行，避免深层目录导致综合、IP package 或 implementation 失败。

### Q10：修改 Python 需要重新综合吗？

不需要。修改 `dma/final_tests`、`dma/pynq`、`dma/sw` 这类 Python 文件，只需要重新上传到板子运行。

需要重新 Vivado 的情况：

- 修改 `rtl/*.sv`
- 修改 `dma/rtl/*.sv`
- 修改会影响 block design 或 IP packaging 的 Tcl
- 修改 PL 频率、AXI 位宽、中断连接、地址映射

## 10. 答辩时建议强调的贡献

1. 完成旧 MMIO/AHB 路径到 AXI-Stream + AXI-DMA 路径的升级。
2. 设计了 job/packet/header 协议，让 stream 数据能表达 APU 加载、运行、读回结果的语义。
3. 新增 DMA wrapper RTL，包含 decoder、loader、job controller、result streamer、AXI-Lite regs、performance counters。
4. 在 Vivado BD 中完成 PS、DDR HP port、AXI DMA、AXIS FIFO、自定义 IP、中断的系统集成。
5. 建立六个 final 测试，对旧方案和 DMA 方案做功能、性能、应用级对比。
6. 定位并修复过 `InBuf` residual replay 导致的个别 bit 不一致问题，重新验证输出对齐。
7. 50 MHz DMA transport 达到 `wall_mbps_mean=380.825 MB/s`，CPU 占用 `5.827%`，满足赛道验收要求。

