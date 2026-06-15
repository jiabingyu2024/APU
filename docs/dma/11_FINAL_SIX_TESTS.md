# 六个最终汇报测试

最终汇报只使用 `dma/final_tests/` 下的六个编号脚本。smoke、协议单元测试和临时调试脚本
用于开发定位，不计入这六项。

## 运行命令

```bash
cd /home/xilinx/jupyter_notebooks/APUdma

python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100

python3 dma/final_tests/04_apu_dma_benchmark.py \
  --clock-mhz 25 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

第 3、6 项默认和建议参数都是 10 张。脚本会同时打印 CIFAR-10 完整测试集数量和本次实际
测试范围，避免误跑 10000 张。

## 输出约定

- 01、04：传输基准原始 CSV/JSON 保存在 `dma/reports/raw/`；
- 六项汇报 summary 统一保存在 `dma/reports/final/`；
- 02、05 保留原 `inference_ps.py` 的推理时间、LogSoftmax、预测索引和类别输出；
- 03、06 保留原 `evaluate_cifar10_ps.py` 的 Top-1、Top-5、样本数和平均推理时间输出；
- 单图和评估仅在原输出末尾追加传输字节、带宽、CPU 和等待方式。

## 2026-06-15 板测结果

| 编号 | 测试 | 关键结果 | 状态 |
|---:|---|---|---|
| 01 | myDesign MMIO 传输 | 8192 B：写 0.694 MB/s，读 0.225 MB/s | 通过 |
| 02 | myDesign 单图 | 2628.9 ms，传输 0.147 MB/s，预测 plane | 通过 |
| 03 | myDesign 10 图 | Top-1 10%，Top-5 100%，2603.6 ms/图，0.148 MB/s | 通过 |
| 04 | APU DMA 传输 | wall 159.55 MB/s，hardware 198.47 MB/s，CPU 14.11% | 通过，性能门槛未通过 |
| 05 | APU DMA 单图 | 131.9 ms，wall 6.54 MB/s，hardware 63.29 MB/s，预测 deer | 通过，结果未与旧版对齐 |
| 06 | APU DMA 10 图 | Top-1 10%，Top-5 100%，115.0 ms/图，wall 6.89 MB/s | 通过，bit-exact 未通过 |

“通过”表示脚本和硬件流程完整执行并生成结果，不代表最终性能或 bit-exact 验收通过。
