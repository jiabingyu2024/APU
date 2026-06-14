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

当前已完成协议软件测试、DMA RTL初版、完整BD生成Tcl、零拷贝PYNQ驱动和板上测试脚本。
Vivado HDL编译、综合、实现、bitstream和板上数据仍待用户在GUI/PYNQ执行。正式架构与阶段门槛见
[`docs/dma/00_CURRENT_STATE_AND_WORK_PLAN.md`](../docs/dma/00_CURRENT_STATE_AND_WORK_PLAN.md)。
预计文件和 Vivado/PYNQ 完整实施顺序见
[`docs/dma/01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md`](../docs/dma/01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md)。
实际操作从
[`docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md`](../docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md)
继续。
