# DMA 支线工作区

本目录只维护真实 `apu_dma.bit/.hwh` 的 APU DMA 路线。旧
`apuYjb/myDesign.bit/.hwh` 不放在这里，只作为 MMIO/AHB 基线由
`dma/benchmark/benchmark_mmio.py` 调用。

当前保留的主要入口：

```text
dma/
  rtl/          APU DMA wrapper、AXIS job decoder、loader、streamer、寄存器
  vivado/       package IP、创建 APU DMA BD、综合实现、导出 overlay 的 Tcl
  pynq/         PYNQ driver、job 构造、smoke、完整网络 wrapper
  benchmark/    旧 MMIO 基线和真实 APU DMA loader benchmark
  tools/        辅助脚本，包括 Jupyter 远程执行脚本
  overlay/      当前真实 APU DMA overlay: apu_dma.bit / apu_dma.hwh
  reports/      板上运行产生的 CSV/JSON
```

已删除独立 DMA loopback 路线。当前仓库没有
`dma/overlay/loopback/apu_dma_loopback.bit`，因此不要再把 loopback 作为必跑项。

实际操作见：

- `docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md`
- `docs/dma/07_PYNQ_BRINGUP_AND_TEST.md`
- `docs/dma/10_BOARD_RUN_SUMMARY.md`
