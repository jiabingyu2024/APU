# PPT 制作规划

这份文档用于辅助制作答辩 PPT。建议总页数控制在 18 到 24 页。每页只放最关键的文字，详细解释放在口头讲。

## 总体结构

建议分为七个部分：

1. 项目简介
2. 项目来源与目标
3. 系统架构
4. 主要代码与模块解析
5. 遇到的问题和解决方案
6. 成果展示
7. 项目展望

## 第 1 页：标题页

标题：

```text
基于 PYNQ-Z2 的 APU + AXI-DMA 高性能数据流架构设计
```

副标题：

```text
赛道二：高性能数据流架构
```

页面元素：

- 项目名
- 姓名/学号/班级
- 指导老师
- 日期

口头讲法：

> 本项目围绕一个二值神经网络 APU 推理核展开，主要工作是把原本 AXI-Lite/AHB/MMIO 的低效数据搬运路径升级为 AXI-Stream + AXI-DMA 数据通路，并在 PYNQ-Z2 上完成对比测试和性能验收。

## 第 2 页：项目背景

页面文字：

```text
背景：
- APU 计算核已经可以完成二值神经网络推理
- 原始上板路径使用 PS 逐字 MMIO/AHB 访问
- 功能可跑，但传输带宽低、CPU 占用高

目标：
- 使用 AXI-Stream + AXI-DMA 重构数据通路
- 保持 APU 计算结果正确
- 提升传输带宽并降低 CPU 占用
```

建议图片：

- 左侧放旧 MMIO 简图。
- 右侧放 DMA 数据流简图。

口头讲法：

> 原始 APU 的问题不在于不能计算，而是数据进出方式太慢。CPU 通过 MMIO 逐字搬运大量参数和 feature，性能被软件和控制总线限制。因此我的优化重点是系统数据通路，而不是重写卷积阵列。

## 第 3 页：赛道要求与完成情况

页面放表格：

| 要求 | 完成情况 |
| --- | --- |
| AXI-Lite 升级为 AXI-Stream + AXI-DMA | 已完成 |
| 零拷贝高效传输 | 使用 PYNQ DMA buffer |
| 流水线数据通路 | MM2S -> apu_dma -> S2MM |
| 带宽 >= 200 MB/s | 380.825 MB/s |
| CPU < 10% | 5.827% |
| 性能测试报告 | 6 个 final tests |

口头讲法：

> 这页直接对应赛道验收要求。需要强调带宽和 CPU 占用来自 04 号 DMA transport benchmark，不是 06 号完整 CIFAR-10 evaluate，因为二者测试口径不同。

## 第 4 页：项目目录与主线

页面文字：

```text
基础 APU：
- rtl/
- apuYjb/

DMA 主线：
- dma/rtl/
- dma/pynq/
- dma/final_tests/
- dma/vivado/
- dma/reports/final/

弃用探索：
- fpga/
- soc/
- third_party/
```

口头讲法：

> 项目里有一些历史探索目录，但最终汇报主线是 APU + DMA。`rtl/` 是基础计算核，`apuYjb/` 是旧版 PYNQ 验证路径，`dma/` 是最终 DMA 扩展。

## 第 5 页：旧方案架构

建议画图：

```text
Python
  -> PYNQ MMIO
  -> AXI-Lite / GP port
  -> AXI-to-AHB bridge
  -> APU AHB slave
  -> APU RAM/registers
```

页面文字：

```text
旧方案特点：
- 控制和数据都走 MMIO/AHB
- CPU 逐字写入参数和 feature
- CPU polling 等待完成
- 带宽低，CPU 占用高
```

口头讲法：

> AXI-Lite 或 AHB 这类接口适合做寄存器控制，不适合搬大量神经网络参数。旧方案每次访问粒度太小，Python 和 MMIO 调用开销被放大。

## 第 6 页：新 DMA 总体架构

建议放图：

- 使用 `docs/dma/design/apu_dma_hardware_block_diagram.png`。
- 或画简化框图。

页面文字：

```text
新方案：
PS 构造 job buffer
AXI DMA MM2S 发送 job stream
apu_dma_0 解析并控制 APU
AXI DMA S2MM 写回 result buffer
interrupt 唤醒 PS
```

口头讲法：

> 新方案把大块数据搬运交给 AXI DMA。PS 只做 job 构造、DMA 配置和中断等待；PL 中的 `apu_dma_0` 负责把 stream 解释成 APU 能理解的动作。

## 第 7 页：哪些是 Vivado IP，哪些是自己写的 RTL

页面放两栏：

Vivado/Xilinx IP：

```text
processing_system7_0
axi_dma_0
smartconnect_ctrl/mm2s/s2mm
axis_fifo_job/result
axi_intc_0
xlconcat_irq
proc_sys_reset_0
```

自定义 RTL：

```text
apu_dma_0
  dma/rtl/*
  rtl/WorkSheet.sv
  rtl/Ctrl.sv
  rtl/InBuf.sv
  rtl/FeatureProcessor.sv
  rtl/ComputeCoreGroup.sv
  rtl/SIMD.sv
```

口头讲法：

> AXI DMA、PS、SmartConnect、FIFO 和中断控制器是 Xilinx IP；真正跟 APU 业务语义相关的是我封装的 `apu_dma_0`。这个 IP 内部既包含新增 DMA wrapper，也包含原始 APU 计算核。

## 第 8 页：Job / Packet / Header 概念

页面文字：

```text
AXI DMA 只搬字节，不理解 APU 语义

本项目定义：
- job：一次完整 APU 推理任务
- packet：job 中的一条命令
- header：packet 元信息
- payload：LOAD 命令携带的数据
```

建议图：

```text
job
 ├─ LOAD ACT packet
 ├─ LOAD WEIGHT packet
 ├─ LOAD BN packet
 ├─ LOAD INSTRUCTION packet
 ├─ RUN packet
 ├─ READ_RESULT packet
 └─ END_JOB packet
```

口头讲法：

> 这些不是 AXI DMA 官方固定术语，是我在 stream 上定义的上层协议。它解决的问题是：stream 没有地址和命令语义，而 APU 需要知道写哪个 RAM、启动几条指令、读多少结果。

## 第 9 页：Packet Header 结构

页面文字：

```text
每个 packet：
4 个 64-bit header beat + payload

header 字段：
magic / version / opcode / target
sequence_id / payload_bytes
address / element_count
arg0 / command_id
```

建议补充：

```text
payload 需要 8 byte 对齐：
(bytes + 7) & ~7
```

口头讲法：

> 因为 AXI-Stream 数据宽度是 64 bit，所以每拍 8 字节。payload 真实长度可能不是 8 的倍数，因此要向上补齐到 8 字节边界，硬件和软件才能按 beat 统一推进。

## 第 10 页：DMA RTL 模块分解

页面放模块图：

```text
S_AXIS_JOB
  -> axis_job_decoder
  -> apu_job_ctrl
  -> apu_stream_loader
  -> apu_dma_core
  -> axis_result_streamer
  -> M_AXIS_RESULT

apu_dma_perf_counters -> apu_dma_axil_regs
```

页面文字：

```text
decoder：解析协议
loader：写 APU RAM
job_ctrl：调度 LOAD/RUN/READ_RESULT
core：封装原始 APU
streamer：返回 response
regs/counters：状态、中断、性能计数
```

口头讲法：

> 我把 DMA wrapper 拆成多个职责明确的状态机。decoder 不直接写 RAM，loader 不负责 job 调度，job controller 统一处理命令顺序和错误，这样更容易调试。

## 第 11 页：Vivado Block Design

建议图片：

- Vivado BD 截图。
- 或 `docs/dma/design/06_HARDWARE_BLOCK_DIAGRAM.md` 中的 top-level 图。

页面文字：

```text
控制面：
PS M_AXI_GP0 -> SmartConnect -> AXI DMA / apu_dma / AXI INTC

数据面：
DDR -> HP0 -> AXI DMA MM2S -> apu_dma
apu_dma -> AXI DMA S2MM -> HP1 -> DDR

中断：
DMA + apu_dma irq -> AXI INTC -> PS IRQ_F2P
```

口头讲法：

> 这页要讲清楚控制面和数据面分离。控制面只配置寄存器；数据面通过 HP port 和 AXI DMA 搬大块数据。

## 第 12 页：PYNQ 软件流程

页面文字：

```text
1. 加载 overlay
2. 分配 TX/RX DMA buffer
3. 将输入、权重、BN、instruction 打包成 job
4. flush TX buffer
5. 启动 S2MM 和 MM2S
6. interrupt 等待完成
7. invalidate RX buffer
8. 解析 response，得到 APU 输出
```

建议图：

```text
build job -> dma send/recv -> wait irq -> parse response
```

口头讲法：

> 软件侧不是简单调用 DMA 发送数组，而是直接在 DMA buffer 中组织一整个网络的 job。这样减少了 Python 循环里反复配置小传输的开销。

## 第 13 页：六个 Final Tests 总览

页面放表格：

| 编号 | 脚本 | 作用 |
| --- | --- | --- |
| 01 | `01_mydesign_benchmark.py` | 旧 MMIO 传输基线 |
| 02 | `02_mydesign_inference.py` | 旧单图推理 |
| 03 | `03_mydesign_evaluate.py` | 旧 CIFAR-10 小样本 |
| 04 | `04_apu_dma_benchmark.py` | DMA 传输验收 |
| 05 | `05_apu_dma_inference.py` | DMA 单图推理 |
| 06 | `06_apu_dma_evaluate.py` | DMA CIFAR-10 小样本 |

口头讲法：

> 这六个脚本是最终汇报口径。01 对 04 看传输性能，02 对 05 看单图功能，03 对 06 看应用级 evaluate。

## 第 14 页：功能正确性结果

页面放表格：

| 对比 | MMIO | DMA |
| --- | --- | --- |
| 单图类别 | plane | plane |
| APU 输出 SHA256 | `a236f489...c345` | `a236f489...c345` |
| 100 张 Top-1 | 21.0% | 21.0% |
| 100 张 Top-5 | 95.0% | 95.0% |

口头讲法：

> DMA 改的是数据通路，不应该改变 APU 计算语义。单图 SHA256 一致和小样本准确率一致，是功能正确性的核心证据。

## 第 15 页：性能结果

页面放核心数据：

```text
旧 MMIO/AHB：
- PS->PL 约 0.78 MB/s
- PL->PS 约 0.23 MB/s
- CPU 约 95%~100%

新 DMA：
- wall_mbps_mean = 380.825 MB/s
- hardware_mbps_mean = 396.946 MB/s
- cpu_percent_mean = 5.827%
- wait_mode = interrupt
```

建议图：

- 柱状图：旧 PS->PL、旧 PL->PS、新 DMA wall bandwidth。
- 柱状图：旧 CPU、新 DMA CPU。

口头讲法：

> 04 是性能验收的主脚本。它说明 DMA transport 在 50 MHz 下已经超过 200 MB/s，而且 CPU 占用低于 10%。

## 第 16 页：为什么 04 和 06 带宽不同

页面文字：

```text
04：纯 DMA transport benchmark
- 大 job
- repeats 聚合
- 更接近通道吞吐上限
- 用于带宽和 CPU 验收

06：完整应用 evaluate
- 数据集读取
- 图像预处理
- Python 循环
- job 构造
- 结果解析和统计
- 用于应用级效果展示
```

口头讲法：

> 06 的带宽低是正常的，因为它不是纯 DMA 通道测试。验收带宽看 04，应用端到端速度看 06。

## 第 17 页：问题 1：中断不可用

页面文字：

```text
现象：
Interrupt s2mm_introut not created
DMA interrupts are unavailable

原因：
bit/hwh 或 BD 中 interrupt 连接不完整

解决：
DMA irq + apu_dma irq -> xlconcat -> axi_intc -> PS IRQ_F2P
导出匹配的 bit/hwh
```

口头讲法：

> CPU <10% 的关键是 interrupt wait。如果中断不可用，driver 只能 polling 或报错，因此必须把 hwh 中的中断连接和实际 bitstream 对齐。

## 第 18 页：问题 2：频率 metadata 不匹配

页面文字：

```text
现象：
FREQ_HZ does not match

原因：
FCLK 改为 50 MHz，但自定义 IP 接口 metadata 仍是旧频率

解决：
Tcl 参数化 PL 频率
统一 package IP 与 create BD 的 FREQ_HZ
```

口头讲法：

> Vivado validate 不只看连线，也看接口 metadata。PL 频率调整时，PS FCLK、AXI/AXIS 接口和自定义 IP metadata 必须一致。

## 第 19 页：问题 3：个别 bit 输出不一致

页面文字：

```text
现象：
02 与 05 单图结果曾出现个别 bit mismatch

定位：
layer2.0.conv2
第二个 64-channel output group

根因：
InBuf residual replay 状态不够显式

修复：
同步寄存器化 replay capture/replay
新增 tb_inbuf_replay 验证
```

口头讲法：

> 这个问题说明不能只看最终类别，要做分层诊断。通过对齐软件 golden 和中间层输出，最终定位到 residual replay，而不是 DMA packet 或权重加载错误。

## 第 20 页：代码解析重点

页面列源码路径：

```text
协议：
dma/pynq/dma_job.py
dma/rtl/apu_dma_pkg.sv

硬件主线：
dma/rtl/axis_job_decoder.sv
dma/rtl/apu_stream_loader.sv
dma/rtl/apu_job_ctrl.sv
dma/rtl/apu_dma_core.sv
dma/rtl/axis_result_streamer.sv

系统集成：
dma/vivado/create_apu_dma_project.tcl

测试：
dma/final_tests/
```

口头讲法：

> 如果老师要求看代码，我建议先从协议常量和 job builder 讲起，再讲 RTL 中 decoder、loader、job controller 三个核心状态机，最后讲 Vivado BD 如何把它们接到 AXI DMA。

## 第 21 页：成果总结

页面文字：

```text
完成：
- 基础 APU 上板验证
- AXI-Stream + AXI-DMA 数据通路
- 自定义 APU DMA packet 协议
- Vivado Tcl 自动创建 BD
- PYNQ driver 与 6 个 final tests
- 旧 MMIO 与新 DMA 性能对比

结果：
- DMA wall bandwidth: 380.825 MB/s
- CPU usage: 5.827%
- 单图输出与旧方案 SHA256 一致
- CIFAR-10 100 张 Top-1/Top-5 与旧方案一致
```

口头讲法：

> 项目达到了赛道二的关键验收指标，同时保留了功能一致性证据和性能对比报告。

## 第 22 页：项目展望

页面文字：

```text
后续优化：
- 探索 75/100 MHz timing 极限
- 减少 Python job 构造开销
- 引入双 buffer 或 scatter-gather DMA
- 将更多预处理/后处理放入 PL
- 增加 RTL 仿真覆盖
- 优化 APU 模型准确率
```

口头讲法：

> 目前 DMA 通道已经满足验收，但完整应用性能仍受 Python 和逐图调度影响。后续可以通过双 buffer、SG DMA 和硬件化更多流程进一步提升端到端吞吐。

## 第 23 页：结束页

页面文字：

```text
谢谢老师
欢迎提问
```

可放一张最终架构图或核心性能结果。

口头讲法：

> 我的汇报到这里结束，欢迎老师提问。

## 备用页 A：六个测试命令

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100

python3 dma/final_tests/04_apu_dma_benchmark.py \
  --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

使用场景：

> 老师问结果如何复现时，展示这一页。

## 备用页 B：验收字段解释

```text
wall_mbps_mean：
真实 wall time 计算的 DMA transport 带宽，主验收字段

hardware_mbps_mean：
硬件 busy cycle + clock_mhz 计算的内部带宽

cpu_percent_mean：
process_time / wall_time * 100

wait_mode：
必须是 interrupt，CPU <10% 才有意义
```

使用场景：

> 老师追问性能指标怎么得到时，展示这一页。

## 备用页 C：为什么不删除 soc/fpga 目录

页面文字：

```text
soc/fpga/third_party 是探索支线
当前汇报主线不使用
保留用于记录尝试过程和工程追溯
最终测试、报告和验收只引用 dma 主线
```

使用场景：

> 老师或同学问项目目录里为什么还有其他支线时，说明这是历史探索，不影响最终主线。

