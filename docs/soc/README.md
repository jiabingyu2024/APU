# RISC-V SoC + APU 实施文档索引

本目录记录从独立 APU 演进到 PicoRV32 控制的全自主 PL SoC 的设计决策、RTL 接口、
固件流程和每阶段验证证据。当前只覆盖无需 Vivado 的 RTL 仿真工作，不包含上板、XDC、
时钟 IP、bitstream 和 ARM PS 板级控制流程。

## 文档索引

| 文档 | 内容 | 当前状态 |
| --- | --- | --- |
| [01_SOC_SPEC.md](01_SOC_SPEC.md) | 功能边界、地址空间、寄存器、时钟复位和验收条件 | 阶段 1 已冻结 |
| [02_RTL_ARCHITECTURE.md](02_RTL_ARCHITECTURE.md) | 模块划分、PicoRV32 native 总线、数据流和握手时序 | 阶段 1 已实现 |
| [03_STAGE1_BRINGUP_LOG.md](03_STAGE1_BRINGUP_LOG.md) | 工具版本、构建命令、日志、问题和结论 | 已通过 |
| [04_STAGE2_APU_BRIDGE.md](04_STAGE2_APU_BRIDGE.md) | native-to-AHB 桥、地址转换、状态机、MMIO 测试和阶段结果 | 已通过 |
| [05_STAGE3_MINIMAL_APU_RUN.md](05_STAGE3_MINIMAL_APU_RUN.md) | 最小真实卷积、CPL 轮询、尾写延迟和 RAM read priming | 已通过 |
| [06_FULL_NETWORK_PREBOARD.md](06_FULL_NETWORK_PREBOARD.md) | 模型 ROM、12-op 固件驱动、完整 golden 对拍和 UART 顶层 | 已通过 |
| [07_VIVADO_BOARD_REMAINING.md](07_VIVADO_BOARD_REMAINING.md) | 当前唯一剩余的 Vivado、XDC、时序和上板清单 | 待上板 |

上层路线参考：

- [../explore/RISCV_SOC_APU_PROJECT_GUIDE.md](../explore/RISCV_SOC_APU_PROJECT_GUIDE.md)
- [../explore/PICORV32_CLONE_TO_APU_INTEGRATION.md](../explore/PICORV32_CLONE_TO_APU_INTEGRATION.md)
- [../design/final/02_PROGRAMMING_MODEL.md](../design/final/02_PROGRAMMING_MODEL.md)

## 当前完成度

```text
[完成] PicoRV32 官方 test_ez
[完成] RV32IMC 裸机 C 编译、链接、反汇编、HEX 生成
[完成] PicoRV32 + 64 KiB RAM + native interconnect
[完成] 仿真 console、Timer、default slave
[完成] RAM byte/half/word、M 扩展、Timer、非法地址自检
[完成] native-to-APU-AHB bridge 独立单元测试
[完成] RISC-V 驱动 APU RAM_CTRL/RAM_SEL
[完成] Act/Out/Weight/BN/WorkSheet 写入和读回
[完成] 非法 APU byte store 拦截和 fault 记录
[完成] RISC-V 写 APU_READY、有限时轮询 CPL、处理中断清除和尾写延迟
[完成] 最小 3x3 真实卷积，1024 个 64-bit word 全量检查
[完成] 90880-word 模型镜像和 512 KiB model ROM
[完成] RISC-V 自主装载并执行完整 12-op 网络
[完成] 最终 8x8x256 输出与 golden bit-exact 对拍
[完成] 可综合 UART TX、console 背压和通用 PL-only 板级顶层
[本阶段排除] Vivado 综合、实现、上板和 ARM PS 板级处理
```

## 快速运行

在项目根目录执行：

```bash
make soc-toolchain-check
make soc-firmware
make soc-bridge-check
make soc-uart-check
make soc-check
```

`make soc-check` 会先运行 bridge 单测，再运行 CPU + APU 集成固件。成功终点是打印
`SOC PREBOARD PASS`，随后以退出码 0 主动结束仿真。当前完整回归约 3,984,895 个
SoC 周期，测试平台设置 20,000,000 周期硬超时，任何未响应请求都不会无限运行。
