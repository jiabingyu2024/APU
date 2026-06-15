# APU DMA 文档索引

当前 DMA 支线只维护真实 `apu_dma.bit/.hwh` 这条路径，不再维护独立 loopback overlay。
旧 `apuYjb/myDesign.bit/.hwh` 仅作为 AXI-Lite/AHB MMIO 基线。

建议阅读顺序：

1. [当前状态和下一步](00_CURRENT_STATE_AND_WORK_PLAN.md)
2. [文件和操作入口](01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md)
3. [旧 MMIO 基线](02_STAGE_A_BASELINE.md)
4. [Packet 协议](04_STREAM_PACKET_PROTOCOL.md)
5. [RTL 与 Vivado 检查](05_RTL_IMPLEMENTATION_REVIEW.md)
6. [Vivado 生成和导出](06_VIVADO_GUI_BUILD_AND_EXPORT.md)
7. [PYNQ 上板、远程操作和测试命令](07_PYNQ_BRINGUP_AND_TEST.md)
8. [性能验收口径](08_PERFORMANCE_ACCEPTANCE.md)
9. [完整网络 DMA Job](09_FULL_NETWORK_DMA_JOB.md)
10. [板上运行结果汇总](10_BOARD_RUN_SUMMARY.md)
11. [六个最终汇报测试](11_FINAL_SIX_TESTS.md)

已删除的独立 loopback 路线不再作为当前交付项；如果以后需要恢复纯 DMA loopback，
应重新生成对应 bit/hwh 后再单独建文档。
