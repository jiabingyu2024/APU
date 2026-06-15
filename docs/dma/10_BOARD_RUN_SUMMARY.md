# 板上运行结果汇总

## 1. 文件版本

板上路径：

```text
/home/xilinx/jupyter_notebooks/APUdma
```

已验证的 overlay：

```text
dma/overlay/apu_dma.bit
SHA256 D923AAAEF2EF0DBF5C2BAE6D86D96BC4F91036A46C73277FBB4A18F033F00924

dma/overlay/apu_dma.hwh
SHA256 901F534907BE6428A1DEF739D38DAF902DE127C843F0F6A44682ABC3583D3608
```

HWH 解析结果包含：

```text
axi_dma_0
axi_intc_0
apu_dma_0
```

中断：

```text
axi_dma_0/mm2s_introut -> axi_intc_0 index 0
axi_dma_0/s2mm_introut -> axi_intc_0 index 1
apu_dma_0/irq          -> axi_intc_0 index 2
```

## 2. 已通过

PC 侧协议测试：

```text
python -m unittest discover -s dma/tests -p "test_*.py" -v
Ran 9 tests: OK
```

板上 ACT RAM smoke：

```text
python3 dma/pynq/test_apu_dma_smoke.py --require-interrupts
APU DMA smoke test PASS
wait_mode: interrupt
```

真实 loader benchmark 可运行并生成：

```text
dma/reports/raw/apu_dma_transport_samples.csv
dma/reports/raw/apu_dma_transport_summary.json
```

完整网络 wrapper 入口可运行：

```text
ApuDmaNetwork.execute()
APUDriver.execute_apu_network()
```

## 3. 当前性能结果

`repeats=16`：

```text
clock_mhz: 25.0
job_bytes: 2129952
hardware_mbps_mean: 198.47
wall_mbps_mean: 40.76
cpu_percent_mean: 57.52
```

`repeats=256`：

```text
clock_mhz: 25.0
job_bytes: 34078752
hardware_mbps_mean: 198.47
wall_mbps_mean: 159.46
cpu_percent_mean: 14.18
```

`repeats=384/512` 在当前板上 CMA 连续内存分配失败。

## 4. 完整网络稳定性

零输入重复运行不稳定：

```text
same instance, 5 runs -> 5 unique output SHA-256 values
new instance, 3 runs  -> 3 unique output SHA-256 values
```

硬件没有报错：

```text
last_error: 0
completed_jobs: 1
error_jobs: 0
response flags: 0
```

结论：DMA 搬运、packet、中断、返回通路可用；完整 APU 计算路径还没有达到
bit-exact 稳定。

## 5. 旧 MMIO 基线

旧基线文件存在：

```text
apuYjb/myDesign.bit
SHA256 6DC85F3FE828147FA9ABF2E45C822A1CEE0F81A7F35CA4CD6F654BA7AE93A323

apuYjb/myDesign.hwh
SHA256 597925900453597BE79ACFD59C9F56E35CDD8E45A845583C3839320B142A3799
```

`benchmark_mmio.py` 已上传到板上。默认长测被中断，尚未形成最终
`mmio_transfer_summary.json`。建议先跑：

```bash
python3 dma/benchmark/benchmark_mmio.py --warmup 1 --iterations 5
```

旧 MMIO 完整推理已在 2026-06-15 完成 10 样本短测：

```text
latency_ms_mean: 2517.25
cpu_percent_mean: 100.63
top1_percent: 10.0
top5_percent: 100.0
```

同一第 0 样本两次运行的 raw SHA 不一致，因此旧 MMIO 路径当前也未达到可作为 golden 的
重复稳定性。
