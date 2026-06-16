# Final Six Tests

最终汇报只使用本目录下六个编号脚本。其它 smoke、diagnose、benchmark 底层脚本只用于开发定位，不作为最终测试入口。

在 PYNQ 板上进入项目目录：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
```

运行旧版 MMIO/AHB 基线：

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100
```

运行 DMA 扩展：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

## Test Meaning

| 编号 | 脚本 | 使用 overlay | 目的 |
| --- | --- | --- | --- |
| 01 | `01_mydesign_benchmark.py` | `apuYjb/myDesign.bit/.hwh` | 旧 MMIO/AHB 传输带宽基线 |
| 02 | `02_mydesign_inference.py` | `apuYjb/myDesign.bit/.hwh` | 旧 MMIO/AHB 单图推理 |
| 03 | `03_mydesign_evaluate.py` | `apuYjb/myDesign.bit/.hwh` | 旧 MMIO/AHB CIFAR-10 小样本评估 |
| 04 | `04_apu_dma_benchmark.py` | `dma/overlay/apu_dma.bit/.hwh` | DMA 传输带宽和 CPU 占用率验收 |
| 05 | `05_apu_dma_inference.py` | `dma/overlay/apu_dma.bit/.hwh` | DMA 单图推理 |
| 06 | `06_apu_dma_evaluate.py` | `dma/overlay/apu_dma.bit/.hwh` | DMA CIFAR-10 小样本评估 |

## Output

- 汇报 JSON 统一写入 `dma/reports/final/`。
- 底层采样 CSV/summary 写入 `dma/reports/raw/`。
- 02 和 05 会保留单图推理输入/输出 `.npy`，用于和软件 golden 或板上结果对齐。
- 03 和 06 的 `--samples` 用于限制评估图片数量，避免误跑完整 10000 张 CIFAR-10 测试集。

## Acceptance Note

验收“传输带宽 >= 200 MB/s、CPU 占用率 < 10%”时，优先看 04 的结果。06 是完整应用流程，包含数据集读取、预处理、Python 循环和结果解析，不能直接等同于纯 DMA 传输能力。
