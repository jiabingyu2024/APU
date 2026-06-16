# DMA Performance Acceptance

本项目的 DMA 性能验收对应以下要求：

- 将 AXI-Lite/AHB MMIO 数据搬运升级为 AXI-Stream + AXI-DMA。
- 实现低拷贝/零拷贝方向的数据通路，避免用 CPU 逐字搬运大块数据。
- 设计可流水运行的数据通路。
- DMA 传输带宽达到 `>= 200 MB/s`。
- DMA 功能正常，CPU 占用率 `< 10%`。
- 给出 AXI-Lite/AHB 与 DMA 的性能对比报告。

## Primary Acceptance Test

带宽和 CPU 占用率的主验收脚本是：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py \
  --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
```

原因：

- 04 只测 DMA transport，最接近“传输带宽”和“CPU 等待开销”的技术指标。
- 06 是 CIFAR-10 端到端 evaluate，会包含数据集读取、图像预处理、Python 循环、结果解析和统计输出，不适合直接作为纯 DMA 带宽验收口径。

## Report Fields

04 的最终报告位于：

```text
dma/reports/final/04_apu_dma_benchmark.json
```

关键字段：

| 字段 | 含义 | 用途 |
| --- | --- | --- |
| `wall_mbps_mean` | 按真实 wall time 计算的端到端 DMA transport 带宽 | 主要带宽验收字段 |
| `hardware_mbps_mean` | 按硬件 busy cycle 和 `--clock-mhz` 计算的硬件内部带宽 | 说明硬件数据面能力 |
| `cpu_percent_mean` | `process_time / wall_time * 100` | CPU 占用率验收字段 |
| `wait_mode` | `interrupt` 或 `polling` | CPU 验收必须使用 interrupt |
| `passes_200mbps_wall` | `wall_mbps_mean >= 200` | 带宽是否通过 |
| `passes_cpu_10percent` | `cpu_percent_mean < 10` | CPU 是否通过 |

如果报告包含 profile 字段，还应看：

| 字段 | 含义 |
| --- | --- |
| `profile_dma_wait_cpu_seconds_mean` | DMA 等待期间消耗的 CPU time |
| `profile_dma_wait_wall_seconds_mean` | DMA 等待的 wall time |
| `profile_rx_allocate_cpu_seconds_mean` | 接收 buffer 分配消耗的 CPU time |
| `profile_tx_flush_cpu_seconds_mean` | TX cache flush CPU time |
| `profile_rx_flush_cpu_seconds_mean` | RX cache flush CPU time |
| `profile_invalidate_parse_cpu_seconds_mean` | invalidate 和结果解析 CPU time |

## How To Read CPU Usage

CPU `<10%` 的目标是证明 DMA 传输期间 CPU 没有忙等搬运数据。因此：

- `wait_mode` 必须是 `interrupt`。
- `polling` 结果只能说明功能可跑，不能用于 CPU `<10%` 验收。
- 如果 `cpu_percent_mean` 偏高，应先看 profile 字段，区分是 DMA 等待本身高，还是 Python/CMA buffer 分配、cache 维护、结果解析高。

已定位过的一类问题是：每次迭代重新分配 PYNQ CMA RX buffer 会显著抬高 CPU 占用率。这属于 Python driver/benchmark 层开销，不是 DMA wait 忙等。当前代码已支持复用 RX buffer；更新板上 Python 后需要重新跑 04 生成最新报告。

## Why Test 6 Is Lower Than Test 4

06 的命令：

```bash
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

06 的带宽和 CPU 占用率通常低于 04，原因是它测的是应用端到端流程：

- CIFAR-10 数据集读取。
- 输入图片预处理和二值化。
- Python 循环调度多张图片。
- 每张图片构造 job、解析输出、统计 Top-1/Top-5。
- 打印和写报告。

这些工作不是 AXI-DMA 数据通路本身。因此最终报告中可以同时给出 04 和 06，但验收“传输带宽 >= 200 MB/s、CPU < 10%”应以 04 为主。

## Frequency Rule

`--clock-mhz` 必须与 bitstream 实际 PL FCLK 一致：

- 50 MHz bit：`--clock-mhz 50`
- 25 MHz bit：`--clock-mhz 25`

这个参数影响 `hardware_mbps_mean`，不影响 wall time 真实测量。修改 `APU_DMA_PL_FREQ_MHZ` 并重新生成 bit/hwh 后，必须同步修改 04 的 `--clock-mhz` 参数。

## Comparison Report

最终报告建议按以下结构对比：

| 对比 | 旧 MMIO/AHB | 新 DMA | 说明 |
| --- | --- | --- | --- |
| 传输带宽 | 01 | 04 | 核心性能对比 |
| 单图推理 | 02 | 05 | 功能和输出对齐 |
| 小样本评估 | 03 | 06 | 应用端到端对比 |

结论应明确区分：

- 传输层性能：看 01 vs 04。
- 单图功能正确性：看 02 vs 05。
- 应用级效果：看 03 vs 06。
