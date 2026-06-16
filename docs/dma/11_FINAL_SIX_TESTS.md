# Final Six Tests

最终汇报只使用 `dma/final_tests/` 下六个编号脚本。其它 smoke、diagnose、unit test 和临时 benchmark 只用于开发定位。

板上运行目录：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
```

## Commands

旧版 `myDesign.bit/.hwh`，作为 AXI-Lite/AHB MMIO 基线：

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100
```

新版 `apu_dma.bit/.hwh`，作为 AXI-Stream + AXI-DMA 方案：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py \
  --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

如果重新生成的是 25 MHz overlay，则测试 04 改成 `--clock-mhz 25`。这个参数必须和 Vivado 里实际 FCLK 频率一致，否则 `hardware_mbps_mean` 会被算错。

## Test Matrix

| 编号 | 脚本 | 路线 | 主要用途 | 报告 |
| --- | --- | --- | --- | --- |
| 01 | `01_mydesign_benchmark.py` | 旧 MMIO/AHB | 旧传输带宽基线 | `dma/reports/final/01_mydesign_benchmark.json` |
| 02 | `02_mydesign_inference.py` | 旧 MMIO/AHB | 单图推理和旧输出格式对齐 | `dma/reports/final/02_mmio_inference.json` |
| 03 | `03_mydesign_evaluate.py` | 旧 MMIO/AHB | CIFAR-10 小样本评估 | `dma/reports/final/03_mmio_evaluate.json` |
| 04 | `04_apu_dma_benchmark.py` | DMA | 传输带宽和 CPU 占用率验收 | `dma/reports/final/04_apu_dma_benchmark.json` |
| 05 | `05_apu_dma_inference.py` | DMA | 单图推理和 DMA 输出验证 | `dma/reports/final/05_dma_inference.json` |
| 06 | `06_apu_dma_evaluate.py` | DMA | CIFAR-10 小样本端到端评估 | `dma/reports/final/06_dma_evaluate.json` |

## Output Rules

- 六个最终 summary JSON 都放在 `dma/reports/final/`。
- 01 和 04 的底层采样 CSV/summary 同时保存在 `dma/reports/raw/`。
- 02 和 05 会保存推理输入/输出 `.npy`，用于复查 bit-level 或 class-level 对齐。
- 03 和 06 必须使用 `--samples` 控制样本数量，最终报告建议 `--samples 100`，避免误跑完整 10000 张。

## Acceptance Reading

性能指标按以下口径解释：

- `>= 200 MB/s`：主要看 04 的 `wall_mbps_mean`，同时可报告 `hardware_mbps_mean` 作为硬件内部计数器口径。
- `CPU < 10%`：主要看 04 的 DMA transport benchmark；如果报告里包含 profile 字段，应区分 `dma_wait`、buffer 分配、flush/invalidate 和 Python 解析开销。
- 06 的带宽通常远低于 04，这是正常现象，因为 06 是完整应用流程，不是纯传输 benchmark。

功能指标按以下口径解释：

- 02 和 05 对应同一张 `apuYjb/image/cifar10_test_image.jpg`。
- 03 和 06 对应 CIFAR-10 测试集的前 `--samples` 张。
- 若 05 与软件 golden 或 02 出现个别 bit 不一致，应先运行 `dma/sw/` 下的 golden/diagnose 脚本定位，不要直接修改 RTL。
