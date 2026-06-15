# 六个最终汇报测试

只使用以下六个编号脚本作为最终汇报入口：

```text
01_mydesign_benchmark.py  旧 myDesign MMIO 传输带宽
02_mydesign_inference.py  旧 myDesign 单图推理 + 传输统计
03_mydesign_evaluate.py   旧 myDesign 限量 CIFAR-10 评估 + 传输统计
04_apu_dma_benchmark.py   新 apu_dma.bit DMA 传输带宽
05_apu_dma_inference.py   新 apu_dma.bit 单图推理 + 传输统计
06_apu_dma_evaluate.py    新 apu_dma.bit 限量 CIFAR-10 评估 + 传输统计
```

板上运行目录：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
```

建议汇报参数：

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 10
python3 dma/final_tests/04_apu_dma_benchmark.py --clock-mhz 25 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 10
```

第 3、6 项默认只评估 10 张，使用 `--samples` 调整数量，避免误跑完整 10000 张。
单图与评估结果保存在 `dma/reports/final/`，传输 benchmark 仍保存在
`dma/reports/raw/`。
