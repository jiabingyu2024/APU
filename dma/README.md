# DMA 赛道工作区

本目录用于“赛道二：高性能数据流架构”的新增工程，不覆盖 `apuYjb/` 原始
PS+PL Overlay，也不复用 `soc/` 纯 PL 路线。

计划中的目录边界如下：

```text
dma/
  rtl/          AXI-Stream 适配、任务控制、性能计数器及 APU DMA wrapper
  tb/           AXI-Stream、任务协议和端到端自检测试
  vivado/       Block Design Tcl、IP 打包和工程生成脚本
  pynq/         Overlay 驱动、零拷贝缓冲区和功能测试
  benchmark/    AXI-Lite/DMA 对比与 CPU 占用率测试脚本
  reports/      工具生成的原始结果，不手工伪造
```

当前阶段仅完成现状审查和工作计划。正式架构与阶段门槛见
[`docs/dma/00_CURRENT_STATE_AND_WORK_PLAN.md`](../docs/dma/00_CURRENT_STATE_AND_WORK_PLAN.md)。

