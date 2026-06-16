# APU DMA Branch

`dma/` 是当前项目的最终扩展支线，目标是把旧版 AXI-Lite/AHB MMIO 数据搬运升级为 AXI-Stream + AXI-DMA，并在 PYNQ 上给出可复查的功能和性能报告。

旧版 `apuYjb/myDesign.bit/.hwh` 不放在本目录，它只作为 MMIO/AHB 对比基线。当前真实 DMA overlay 位于 `dma/overlay/apu_dma.bit` 和 `dma/overlay/apu_dma.hwh`。

## Directory Map

```text
dma/
|-- rtl/             APU DMA wrapper、AXIS job decoder、loader、result streamer、寄存器
|-- vivado/          APU DMA IP 封装、BD 创建、bit/hwh 导出的 Tcl
|-- pynq/            PYNQ driver、DMA job 构造、smoke 和完整网络 wrapper
|-- benchmark/       MMIO baseline 与 DMA transport benchmark 的底层实现
|-- final_tests/     最终六个汇报测试脚本
|-- sw/              软件 golden、硬件对比、InBuf bit mismatch 定位记录
|-- tools/           PYNQ Jupyter 上传/执行、job image 辅助工具
|-- overlay/         当前 apu_dma.bit / apu_dma.hwh
`-- reports/         板上导出的 raw/final JSON、CSV、npy 报告
```

## Final Test Entry

最终汇报只使用 `dma/final_tests/` 下六个编号脚本：

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100

python3 dma/final_tests/04_apu_dma_benchmark.py --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

说明：

- 01/02/03 使用旧版 `apuYjb/myDesign.bit/.hwh`，作为 AXI-Lite/AHB MMIO 基线。
- 04/05/06 使用 `dma/overlay/apu_dma.bit/.hwh`，作为 AXI-Stream + AXI-DMA 方案。
- 04 是带宽和 CPU 占用率验收主口径。
- 06 是应用级端到端评估，包含 Python 数据集、预处理、调度和结果解析，吞吐通常低于 04。

## Main Documents

- [../docs/dma/README.md](../docs/dma/README.md)：DMA 文档入口。
- [../docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md](../docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md)：Vivado 生成 bit/hwh。
- [../docs/dma/07_PYNQ_BRINGUP_AND_TEST.md](../docs/dma/07_PYNQ_BRINGUP_AND_TEST.md)：PYNQ 上传、运行、导出报告。
- [../docs/dma/08_PERFORMANCE_ACCEPTANCE.md](../docs/dma/08_PERFORMANCE_ACCEPTANCE.md)：性能验收口径。
- [../docs/dma/11_FINAL_SIX_TESTS.md](../docs/dma/11_FINAL_SIX_TESTS.md)：最终六个测试。

## Notes

- 修改 `dma/pynq/`、`dma/benchmark/`、`dma/final_tests/` 或文档，不需要重新 Vivado 综合。
- 修改 `rtl/`、`dma/rtl/` 或 `dma/vivado/` 后，需要重新封装 IP、综合、实现并导出新的 bit/hwh。
- PL 频率通过 `APU_DMA_PL_FREQ_MHZ` 控制；生成 50 MHz overlay 后，测试 04 的 `--clock-mhz` 也应写 50。
- 独立 DMA loopback 路线已经不作为当前交付项；不要把不存在的 loopback bit/hwh 当成必跑测试。
