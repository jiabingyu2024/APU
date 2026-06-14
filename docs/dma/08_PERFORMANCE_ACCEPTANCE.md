# DMA 性能验收和报告口径

## 1. 当前需要报告的数据

1. 旧 AXI-Lite/AHB MMIO 基线：`dma/benchmark/benchmark_mmio.py`
2. 真实 APU DMA loader：`dma/benchmark/benchmark_apu_dma_transport.py`
3. 完整网络 DMA wrapper：`dma/pynq/inference_dma.py`

当前不再维护独立 DMA loopback overlay，因此 loopback 不作为必跑验收项。

## 2. 带宽口径

墙钟口径：

```text
wall MB/s = 有效 job bytes / wall_seconds / 1e6
```

硬件计数器口径：

```text
hardware MB/s = job bytes / (busy_cycles / (clock_mhz * 1e6)) / 1e6
```

`benchmark_apu_dma_transport.py` 的 `--clock-mhz` 必须与 bitstream 实际 FCLK 一致。
当前 25 MHz bit 使用默认 `--clock-mhz 25`。

## 3. CPU 口径

```text
CPU% = process_time / wall_time * 100
```

只接受 `wait_mode: interrupt` 的结果。`--allow-polling` 只能说明功能通路可跑，
不能用于 CPU<10%。

## 4. 当前实测

25 MHz bit，`repeats=256, warmup=1, iterations=5`：

```text
wait_mode: interrupt
hardware_mbps_mean: 198.47
wall_mbps_mean: 159.46
cpu_percent_mean: 14.18
```

结论：

- 中断已可用；
- 硬件数据面接近 25 MHz 64-bit 理论上限；
- wall 带宽和 CPU 尚未达最终验收。

## 5. 最终通过条件

- `test_apu_dma_smoke.py --require-interrupts` 通过；
- 真实 loader `wall_mbps_mean >= 200`；
- 真实 loader `cpu_percent_mean < 10`；
- 完整网络同一输入重复运行输出 SHA 一致；
- 完整网络输出与旧 MMIO/golden bit-exact；
- Vivado `WNS >= 0`、`TNS = 0`、DRC 无 error。
