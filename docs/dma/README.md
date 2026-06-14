# DMA 赛道文档

本目录记录基于 `apuYjb` 的 PS+PL 架构升级路线。目标数据面为
AXI-Stream + AXI DMA，控制面保留少量 AXI-Lite 寄存器。

## 文档索引

1. [当前状态与工作计划](00_CURRENT_STATE_AND_WORK_PLAN.md)
2. [实施目录、文件清单与完整操作流程](01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md)
3. [阶段 A：旧 MMIO 基线冻结与测量](02_STAGE_A_BASELINE.md)
4. [阶段 B：独立 AXI DMA Loopback](03_STAGE_B_DMA_LOOPBACK.md)
5. [阶段 C：DMA Stream Job Packet协议](04_STREAM_PACKET_PROTOCOL.md)
6. [阶段 D/E：RTL实现与审查](05_RTL_IMPLEMENTATION_REVIEW.md)
7. [Vivado GUI建工程、生成bit和导出Overlay](06_VIVADO_GUI_BUILD_AND_EXPORT.md)
8. [PYNQ无USB-TTL Bring-up与测试](07_PYNQ_BRINGUP_AND_TEST.md)
9. [性能验收与报告口径](08_PERFORMANCE_ACCEPTANCE.md)
10. [完整网络DMA Job迁移](09_FULL_NETWORK_DMA_JOB.md)

机器可读阶段产物：`stage1_spec_extraction.json`、`stage4_rtl_architecture.json`和
`stage5_rtl_gen.json`。
