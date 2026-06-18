# APU Documentation Index

本文档是 `docs/` 的入口。当前有效主线是：

1. 基础 APU ASIC：`rtl/`、`tb/`、`data/`
2. 旧版 PYNQ MMIO/AHB 基线：`apuYjb/`
3. 最终 AXI-Stream + AXI-DMA 扩展：`dma/`

`soc`、`fpga`、`explore` 相关文档已经移动到 `docs/archive/`，只作为历史探索记录，不作为最终验收路线。

## Recommended Reading

| 目标 | 文档 |
| --- | --- |
| 快速理解项目结构 | [../README.md](../README.md) |
| 查看整理计划 | [PROJECT_CLEANUP_PLAN.md](PROJECT_CLEANUP_PLAN.md) |
| 理解基础 APU RTL | [design/final/README.md](design/final/README.md) |
| 理解旧版 PYNQ MMIO/AHB 基线 | [apuYjb/README.md](apuYjb/README.md) |
| 理解最终 DMA 支线 | [dma/README.md](dma/README.md) |
| 跑最终六个测试 | [dma/11_FINAL_SIX_TESTS.md](dma/11_FINAL_SIX_TESTS.md) |
| 判断性能指标是否满足要求 | [dma/08_PERFORMANCE_ACCEPTANCE.md](dma/08_PERFORMANCE_ACCEPTANCE.md) |
| 在 PYNQ 上运行和导出报告 | [dma/07_PYNQ_BRINGUP_AND_TEST.md](dma/07_PYNQ_BRINGUP_AND_TEST.md) |
| 用 Vivado 生成 DMA bit/hwh | [dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md](dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md) |

## Current Documents

### Base APU Design

| 文档 | 内容 |
| --- | --- |
| [design/final/README.md](design/final/README.md) | 基础 APU RTL 文档入口 |
| [design/final/01_SYSTEM_ARCHITECTURE.md](design/final/01_SYSTEM_ARCHITECTURE.md) | 系统结构、模块层次和运行阶段 |
| [design/final/02_PROGRAMMING_MODEL.md](design/final/02_PROGRAMMING_MODEL.md) | AHB 地址空间、RAM 控制权和启动完成协议 |
| [design/final/03_INSTRUCTION_AND_NETWORK.md](design/final/03_INSTRUCTION_AND_NETWORK.md) | 指令格式和网络映射 |
| [design/final/04_DATA_AND_MEMORY_LAYOUT.md](design/final/04_DATA_AND_MEMORY_LAYOUT.md) | 特征、权重、BN 参数和通道组布局 |
| [design/final/05_CONTROL_AND_TIMING.md](design/final/05_CONTROL_AND_TIMING.md) | Ctrl 状态机和周期时序 |
| [design/final/06_MODULE_CONTRACTS.md](design/final/06_MODULE_CONTRACTS.md) | RTL 模块接口合同 |
| [design/final/07_RESIDUAL_PATH.md](design/final/07_RESIDUAL_PATH.md) | residual/shortcut 数据路径 |
| [design/final/08_VERIFICATION_AND_REBUILD.md](design/final/08_VERIFICATION_AND_REBUILD.md) | 仿真、回归和 bit-exact 验证 |
| [design/final/09_ERRATA_AND_RISKS.md](design/final/09_ERRATA_AND_RISKS.md) | 已知问题、历史误判和剩余风险 |
| [design/final/10_RTL_REBUILD_BLUEPRINT.md](design/final/10_RTL_REBUILD_BLUEPRINT.md) | 从文档重建 RTL 的蓝图 |

### Design Notes

| 文档 | 内容 |
| --- | --- |
| [design/APU_DESIGN.md](design/APU_DESIGN.md) | APU 总体设计背景 |
| [design/APU_DESIGN_DEV1_CONV.md](design/APU_DESIGN_DEV1_CONV.md) | 普通卷积阶段设计记录 |
| [design/Ctrl_InBuf_Design.md](design/Ctrl_InBuf_Design.md) | Ctrl/InBuf 变量、地址和 residual replay 说明 |
| [design/AHB_RAM_SEL_128_129.md](design/AHB_RAM_SEL_128_129.md) | AHB RAM 片选专题 |
| [design/sta/APU_50MHZ_FIRST_STAGE_IMPLEMENTATION.md](design/sta/APU_50MHZ_FIRST_STAGE_IMPLEMENTATION.md) | 50 MHz 初步实现记录 |
| [design/sta/APU_50MHZ_TIMING_REVIEW.md](design/sta/APU_50MHZ_TIMING_REVIEW.md) | 50 MHz 时序审查 |

### PYNQ MMIO Baseline

| 文档 | 内容 |
| --- | --- |
| [apuYjb/README.md](apuYjb/README.md) | 旧版 `myDesign.bit/.hwh` 上板基线入口 |
| [apuYjb/01_ARCHITECTURE.md](apuYjb/01_ARCHITECTURE.md) | PYNQ MMIO 基线架构 |
| [apuYjb/02_ASSET_MANIFEST.md](apuYjb/02_ASSET_MANIFEST.md) | bit/hwh、模型、图片、参数清单 |
| [apuYjb/03_OVERLAY_AND_MMIO.md](apuYjb/03_OVERLAY_AND_MMIO.md) | overlay 与 MMIO 访问方式 |
| [apuYjb/04_DRIVER_AND_NETWORK_FLOW.md](apuYjb/04_DRIVER_AND_NETWORK_FLOW.md) | Python driver 和网络执行流程 |
| [apuYjb/05_DEPLOY_AND_RUN.md](apuYjb/05_DEPLOY_AND_RUN.md) | PYNQ 部署和运行 |
| [apuYjb/06_ACCURACY_AND_DEBUG.md](apuYjb/06_ACCURACY_AND_DEBUG.md) | 准确率与调试 |
| [apuYjb/07_BOUNDARY_AND_KNOWN_RISKS.md](apuYjb/07_BOUNDARY_AND_KNOWN_RISKS.md) | 边界和风险 |

### Final DMA Branch

| 文档 | 内容 |
| --- | --- |
| [dma/README.md](dma/README.md) | DMA 文档入口 |
| [dma/design/README.md](dma/design/README.md) | DMA 支线学习型设计文档入口 |
| [dma/design/00_TERMS_JOB_PACKET_HEADER.md](dma/design/00_TERMS_JOB_PACKET_HEADER.md) | job、packet、header、payload、beat、TLAST 概念解释 |
| [dma/design/00A_HARDWARE_SOFTWARE_CO_VIEW.md](dma/design/00A_HARDWARE_SOFTWARE_CO_VIEW.md) | 从硬件 RTL 和软件 driver 双视角理解 DMA 支线 |
| [dma/design/01_AXI_DMA_FOUNDATION.md](dma/design/01_AXI_DMA_FOUNDATION.md) | AXI-Lite、AXI4-MM、AXI-Stream、AXI DMA 基础 |
| [dma/design/02_SYSTEM_DATA_FLOW.md](dma/design/02_SYSTEM_DATA_FLOW.md) | 从 Python job 到 DDR、DMA、RTL、APU core、response 的完整数据流 |
| [dma/design/03_RTL_ARCHITECTURE.md](dma/design/03_RTL_ARCHITECTURE.md) | `dma/rtl/` 模块详解 |
| [dma/design/04_BLOCK_DESIGN.md](dma/design/04_BLOCK_DESIGN.md) | Vivado block design 结构详解 |
| [dma/design/05_REGISTERS_INTERRUPTS_AND_DEBUG.md](dma/design/05_REGISTERS_INTERRUPTS_AND_DEBUG.md) | 寄存器、中断、性能计数器和调试 |
| [dma/design/06_HARDWARE_BLOCK_DIAGRAM.md](dma/design/06_HARDWARE_BLOCK_DIAGRAM.md) | DMA 支线硬件框图和模块归属 |
| [dma/00_CURRENT_STATE_AND_WORK_PLAN.md](dma/00_CURRENT_STATE_AND_WORK_PLAN.md) | 当前状态和工作计划 |
| [dma/01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md](dma/01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md) | 文件和操作入口 |
| [dma/02_STAGE_A_BASELINE.md](dma/02_STAGE_A_BASELINE.md) | 旧 MMIO 基线 |
| [dma/04_STREAM_PACKET_PROTOCOL.md](dma/04_STREAM_PACKET_PROTOCOL.md) | AXI-Stream packet 协议 |
| [dma/05_RTL_IMPLEMENTATION_REVIEW.md](dma/05_RTL_IMPLEMENTATION_REVIEW.md) | DMA RTL 检查 |
| [dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md](dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md) | Vivado 生成与导出 |
| [dma/07_PYNQ_BRINGUP_AND_TEST.md](dma/07_PYNQ_BRINGUP_AND_TEST.md) | PYNQ 操作、测试和报告导出 |
| [dma/08_PERFORMANCE_ACCEPTANCE.md](dma/08_PERFORMANCE_ACCEPTANCE.md) | 性能验收口径 |
| [dma/09_FULL_NETWORK_DMA_JOB.md](dma/09_FULL_NETWORK_DMA_JOB.md) | 完整网络 DMA job |
| [dma/10_BOARD_RUN_SUMMARY.md](dma/10_BOARD_RUN_SUMMARY.md) | 板上运行结果汇总 |
| [dma/11_FINAL_SIX_TESTS.md](dma/11_FINAL_SIX_TESTS.md) | 六个最终测试 |
| [dma/sw/README.md](dma/sw/README.md) | 软件 golden、硬件对比和 InBuf 修复记录 |

### Simulation

| 文档 | 内容 |
| --- | --- |
| [sim/tb_top_student详解.md](sim/tb_top_student详解.md) | 基础 APU testbench 说明 |

## Archive

归档文档保留用于复查，不作为当前运行入口。

| 路径 | 内容 |
| --- | --- |
| [archive/README.md](archive/README.md) | 归档索引 |
| [archive/](archive/) | 历史 bug 定位、RTL 修复、旧评审记录 |
| [archive/soc/README.md](archive/soc/README.md) | 已弃用 SoC 支线文档 |
| [archive/fpga/README.md](archive/fpga/README.md) | 已弃用早期 FPGA/PL-only 文档 |
| [archive/explore/](archive/explore/) | PicoRV32/SoC 探索笔记 |
| [archive/reference/](archive/reference/) | 外部手册和参考资料 |

## Notes

- 当前最终报告以 `dma/final_tests/` 和 `docs/dma/` 为准。
- `soc/`、`fpga/`、`third_party/` 源码目录仍保留，不删除。
- 修改 RTL 或 Vivado Tcl 后需要重新生成 bit/hwh；只修改 Python 和文档不需要重新综合。
- Vivado 工程路径尽量保持短路径，避免路径过长导致构建失败。
