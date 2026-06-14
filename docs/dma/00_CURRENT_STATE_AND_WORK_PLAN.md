# APU DMA 当前状态和下一步

## 当前结论

截至 2026-06-14，真实 APU DMA overlay 已能在 PYNQ-Z2 上运行：

- `dma/overlay/apu_dma.bit` 与 `dma/overlay/apu_dma.hwh` 已上传到板上；
- HWH 已正确解析出 `axi_intc_0`，DMA 两路中断均可由 PYNQ 创建 interrupt 对象；
- ACT RAM smoke test 使用 interrupt wait 通过；
- 真实 loader DMA benchmark 可运行并生成 CSV/JSON；
- 完整网络 aggregate DMA job 可以执行并返回 256x8x8 输出；
- 旧 AXI-Lite/AHB MMIO 基线脚本 `benchmark_mmio.py` 已同步到板上，但完整默认测量被中断，尚未取得最终 JSON。

当前尚未验收通过：

- `wall_mbps_mean >= 200`：25 MHz 版本实测约 159 MB/s；
- `cpu_percent_mean < 10`：25 MHz 版本 `repeats=256` 实测约 14%；
- 完整网络 bit-exact 稳定性：同一零输入重复运行输出 SHA 不一致；
- 旧 MMIO 基线完整报告：需要重新跑较短或完整参数。

## 当前板上实测结果

真实 DMA loader，`repeats=256, iterations=5, warmup=1, clock_mhz=25`：

```text
wait_mode: interrupt
job_bytes: 34078752
hardware_mbps_mean: 198.47
wall_mbps_mean: 159.46
cpu_percent_mean: 14.18
passes_200mbps_wall: false
passes_cpu_10percent: false
```

完整网络零输入执行：

```text
full_job_used_bytes: 386528
response_used_bytes: 2112
output_shape: (1, 256, 8, 8)
hardware_error: none
```

重复稳定性测试显示输出不稳定：

```text
same zero input, same bit/hwh, 5 runs -> 5 different output SHA-256 values
```

## 已定位并修正的问题

### PYNQ 中断不可用

旧 BD 连接为：

```text
DMA/APU irq -> xlconcat -> PS IRQ_F2P[2:0]
```

板上 Linux 只暴露第一路 fabric UIO，导致 `s2mm_introut` 对应 IRQ 找不到 UIO。

已改为：

```text
DMA/APU irq -> xlconcat -> axi_intc_0 -> PS IRQ_F2P
```

`axi_intc_0/S_AXI` 已挂到 GP0 控制总线，地址为 `0x41800000`。

### PYNQ interrupt event loop

`apu_dma_driver.py` 原来反复 `asyncio.run()`，PYNQ interrupt Future 会绑定到错误事件循环。
已改为复用当前默认 event loop。

### 性能报告频率口径

`benchmark_apu_dma_transport.py` 原来按 100 MHz 计算硬件带宽。当前 bit 是 25 MHz，
已增加 `--clock-mhz`，默认 `25.0`。

## 下一步

1. 重新跑旧 MMIO 基线，建议先用较短参数：

```bash
python3 dma/benchmark/benchmark_mmio.py --warmup 1 --iterations 5
```

2. 若要通过 `>=200 MB/s`，生成 100 MHz 版本 `apu_dma.bit/.hwh`，再用：

```bash
python3 dma/pynq/test_apu_dma_smoke.py --require-interrupts
python3 dma/benchmark/benchmark_apu_dma_transport.py --clock-mhz 100 --repeats 256 --warmup 1 --iterations 5
```

3. 完整网络稳定性需要继续查 RTL/RAM 所有权/计算核复位或 run 完成判定。
