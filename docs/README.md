# APU 文档索引

本页按用途整理 `docs/` 下的设计、仿真和历史文档。第一次阅读建议先看“推荐阅读
路径”；定位具体问题时可直接使用后面的分类索引。

## 文档权威级别

发生描述冲突时，按以下优先级判断：

1. [`design/final/`](design/final/README.md)：当前已验证 RTL 的规范基线。
2. 当前 `rtl/`、`tb/` 和 `scripts/compare_outputs.py` 的实际行为。
3. `design/` 下的模块专题和阶段性设计总结。
4. `archive/` 下的历史审查、故障定位和修复记录。

`archive/` 中部分判断描述的是修复前代码，不能直接作为当前实现合同。

## 推荐阅读路径

### 快速理解项目

1. [项目根 README](../README.md)：目录结构、环境、编译和标准回归。
2. [最终设计文档总览](design/final/README.md)：设计边界、文档顺序和验收状态。
3. [系统架构](design/final/01_SYSTEM_ARCHITECTURE.md)：整机模块层次和主数据通路。
4. [编程模型](design/final/02_PROGRAMMING_MODEL.md)：AHB 地址空间、RAM 控制权和启动完成协议。
5. [验证规范](design/final/08_VERIFICATION_AND_REBUILD.md)：testbench 流程和 bit-exact 验收标准。

### 深入理解 Ctrl 与数据通路

1. [指令格式与网络映射](design/final/03_INSTRUCTION_AND_NETWORK.md)
2. [数据表示与存储布局](design/final/04_DATA_AND_MEMORY_LAYOUT.md)
3. [控制微架构与周期时序](design/final/05_CONTROL_AND_TIMING.md)
4. [Ctrl 与 InBuf 详细设计](design/Ctrl_InBuf_Design.md)
5. [Residual 路径专题](design/final/07_RESIDUAL_PATH.md)

## 最终设计基线

| 文档 | 简介 |
| --- | --- |
| [总索引](design/final/README.md) | 最终文档定位、推荐顺序、验证状态和适用边界 |
| [01 系统架构](design/final/01_SYSTEM_ARCHITECTURE.md) | 顶层层次、参数、时钟复位、运行阶段和整机数据流 |
| [02 编程模型与外部接口](design/final/02_PROGRAMMING_MODEL.md) | AHB 协议约束、地址空间、32/64 bit 适配、启动与完成 |
| [03 指令格式与网络映射](design/final/03_INSTRUCTION_AND_NETWORK.md) | 32 bit 指令字段、Ctrl 派生量和已验证网络指令 |
| [04 数据表示与存储布局](design/final/04_DATA_AND_MEMORY_LAYOUT.md) | 二值编码、Feature/Weight/BN 布局及通道组顺序 |
| [05 控制微架构与周期时序](design/final/05_CONTROL_AND_TIMING.md) | Ctrl 状态机、循环计数、地址生成和逐拍流水 |
| [06 RTL 模块合同](design/final/06_MODULE_CONTRACTS.md) | Top、AHB、存储、控制、计算和 SIMD 的接口行为合同 |
| [07 Residual 路径](design/final/07_RESIDUAL_PATH.md) | 主支路、shortcut、双 SRAM 角色和 InBuf replay |
| [08 验证规范与回归](design/final/08_VERIFICATION_AND_REBUILD.md) | 标准命令、testbench 流程、断言和 RTL 重建验收 |
| [09 勘误与风险](design/final/09_ERRATA_AND_RISKS.md) | 已修问题、历史误判、剩余风险和结论适用边界 |
| [10 RTL 重建蓝图](design/final/10_RTL_REBUILD_BLUEPRINT.md) | 从规范重新实现 RTL 的顺序、接口骨架和阶段目标 |

## 设计专题

| 文档 | 简介 | 使用场景 |
| --- | --- | --- |
| [APU 总体设计](design/APU_DESIGN.md) | APU 目标、顶层结构、AHB 接口和主要模块 | 建立较完整的系统背景 |
| [dev1 普通卷积设计总结](design/APU_DESIGN_DEV1_CONV.md) | 普通卷积阶段的数据流、并行度和阶段性验证结论 | 追溯普通卷积实现演进 |
| [Ctrl 与 InBuf 详细设计](design/Ctrl_InBuf_Design.md) | 英文变量释义，H/W/Cin/Cout 循环，权重映射和延迟控制 | 阅读或修改 `Ctrl.sv`、`InBuf.sv` |
| [AHB RAM_SEL 128/129](design/AHB_RAM_SEL_128_129.md) | ActSRAM 与 OutSRAM 的 AHB 片选规则 | 编写 AHB 搬运或 TB 代码 |

## 仿真文档

| 文档 | 简介 |
| --- | --- |
| [tb_top_student.sv 详解](sim/tb_top_student详解.md) | testbench 的装载、发指令、启动、轮询和结果导出流程 |

运行方式和输出检查点另见项目根目录的[快速上手](../README.md#快速上手)。

## 探索与进阶方案

| 文档 | 简介 |
| --- | --- |
| [RISC-V 全自主 SoC + APU 实施指南](explore/RISCV_SOC_APU_PROJECT_GUIDE.md) | 面向大三课程项目的 PicoRV32 选型、SoC 架构、总线桥、裸机工具链、模型搬运、FPGA 上板和分阶段验收路线 |
| [PicoRV32 克隆后学习与接入 APU](explore/PICORV32_CLONE_TO_APU_INTEGRATION.md) | 克隆后的阅读顺序、官方测试、第三方 IP 管理、CPU+BRAM 最小系统、native 总线、AHB bridge 和逐步接入现有 APU 的操作手册 |

## 历史问题与修复记录

以下文档用于追溯 bug 现象、定位证据和修复过程，不代表当前规范：

| 文档 | 记录内容 |
| --- | --- |
| [CTRL 接口与残差适配](archive/CTRL.md) | 早期 Ctrl 接口变更和 residual 适配记录 |
| [RTL Bug 审查与修复](archive/RTL_BUG_REVIEW_AND_FIX_LOG.md) | 多模块集成问题总表和修复记录 |
| [Layer1.0 输出不一致](archive/LAYER1_0_OUTPUT_MISMATCH_REVIEW.md) | Layer1.0 mismatch 初始审查 |
| [Layer1.0 启动后近似全零](archive/LAYER1_0_ALL_ZERO_AFTER_RUN_REVIEW.md) | 全零现象和波形证据 |
| [dev1 Layer1.0 部分不一致](archive/DEV1_LAYER1_0_PARTIAL_MISMATCH_REVIEW.md) | SRAM 写入与 TB 读回问题定位 |
| [dev1 Layer2 residual mismatch](archive/DEV1_LAYER2_RESIDUAL_MISMATCH_REVIEW.md) | Layer2 残差输出不一致审查 |
| [dev1 Layer2 residual 修复](archive/DEV1_LAYER2_RESIDUAL_FIX_LOG.md) | Layer2 残差时序和 RTL 修复过程 |
| [dev1 Layer3 mismatch](archive/DEV1_LAYER3_OUTPUT_MISMATCH_REVIEW.md) | Layer3 输出问题和正确执行方式 |
| [dev1 Layer3 修复](archive/DEV1_LAYER3_OUTPUT_FIX_LOG.md) | Layer3 RTL 修复及结果 |
| [仿真输出目录整理](archive/SIM_OUTPUT_PATH_CLEANUP.md) | 输出统一迁移到 `build/sim/` 的记录 |

## 按问题跳转

| 我想解决的问题 | 入口 |
| --- | --- |
| APU 为什么不结束或 completion 不推进 | [控制与时序](design/final/05_CONTROL_AND_TIMING.md)、[验证规范](design/final/08_VERIFICATION_AND_REBUILD.md) |
| 权重地址为何这样递增 | [数据与存储布局](design/final/04_DATA_AND_MEMORY_LAYOUT.md)、[Ctrl/InBuf 设计](design/Ctrl_InBuf_Design.md) |
| residual 为什么需要 replay | [Residual 路径](design/final/07_RESIDUAL_PATH.md)、[Ctrl/InBuf 设计](design/Ctrl_InBuf_Design.md) |
| AHB 如何选择 ActSRAM/OutSRAM | [编程模型](design/final/02_PROGRAMMING_MODEL.md)、[RAM_SEL 专题](design/AHB_RAM_SEL_128_129.md) |
| 修改一个 RTL 模块前要确认什么 | [模块合同](design/final/06_MODULE_CONTRACTS.md)、[勘误与风险](design/final/09_ERRATA_AND_RISKS.md) |
| 如何重新实现或重构 RTL | [RTL 重建蓝图](design/final/10_RTL_REBUILD_BLUEPRINT.md) |
