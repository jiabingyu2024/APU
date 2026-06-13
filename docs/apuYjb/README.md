# apuYjb 文档索引

`apuYjb/` 是一套面向 PYNQ-Z2 的 **PS + PL 混合推理资料**：Python/PyTorch 运行在
ARM Cortex-A9 上，PS 通过 AXI GP0、AXI-to-AHB bridge 和 MMIO 控制 PL 中的 APU。

> 重要边界：这套资料依赖 ARM、Linux、PYNQ 和 PyTorch，不能在 ARM reset 或停止时钟后
> 继续运行。要求“ARM 完全禁用”时，应使用 `docs/fpga/` 中的纯 PL PicoRV32 方案。

## 建议阅读顺序

1. [01_ARCHITECTURE.md](01_ARCHITECTURE.md)
   - 系统分工、完整数据流、PS 与 PL 的职责边界。
2. [02_ASSET_MANIFEST.md](02_ASSET_MANIFEST.md)
   - `apuYjb/` 每类文件的用途、实际入口和配套关系。
3. [03_OVERLAY_AND_MMIO.md](03_OVERLAY_AND_MMIO.md)
   - Vivado Block Design、地址空间、寄存器、RAM 选择与启动握手。
4. [04_DRIVER_AND_NETWORK_FLOW.md](04_DRIVER_AND_NETWORK_FLOW.md)
   - 张量打包、参数装载、指令编码和五段 APU 执行流程。
5. [05_DEPLOY_AND_RUN.md](05_DEPLOY_AND_RUN.md)
   - 在 PYNQ Linux 上部署、单图推理、CIFAR-10 评估和输出判断。
6. [06_ACCURACY_AND_DEBUG.md](06_ACCURACY_AND_DEBUG.md)
   - Top-1/Top-5 偏低的定位顺序、golden 对比方法和故障现象表。
7. [07_BOUNDARY_AND_KNOWN_RISKS.md](07_BOUNDARY_AND_KNOWN_RISKS.md)
   - 当前资料不能证明的内容、已确认风险及与当前 RTL 的兼容边界。

## 两条上板路线不要混用

| 项目 | `apuYjb/myDesign.bit` | `fpga/output/riscv_apu_pynq_z2.bit` |
|---|---|---|
| 控制处理器 | Zynq PS 内 ARM | PL 内 PicoRV32 |
| 软件环境 | PYNQ Linux + Python + PyTorch | 裸机 RISC-V 固件 |
| APU 访问路径 | PS AXI GP0 -> AHB -> APU | PicoRV32 总线 -> APU |
| 是否需要 HWH | 需要，供 PYNQ 解析 Overlay | 不需要 |
| ARM 禁用后 | 立即停止工作 | 设计目标是继续独立工作 |
| 验证方式 | Python 分类结果 | LED + PL UART + 固件自检 |

## 当前状态摘要

- `inference_ps.py` 和 `evaluate_cifar10_ps.py` 实际使用 `apu_driver.py`。
- `apu_driver_full.py` 带超时和残留 `CPL` 检查，但目前没有接入入口脚本。
- 旧 Overlay 地址为 `0x43C00000-0x43C0FFFF`，实例名为 `APU_0`，FCLK 为 100 MHz。
- 当前驱动执行 12 条卷积/残差指令，分 5 次启动 APU。
- 当前驱动最终输出解包没有执行 256 通道 group `3,2,1,0` 重排，这是已确认风险。
- `apuYjb/param/` 与当前 RTL 回归参数不是同一套，不能交叉替换。

更完整的静态审查证据见
[`docs/archive/APUYJB_PYNQ_RTL_BLOCK_DESIGN_REVIEW.md`](../archive/APUYJB_PYNQ_RTL_BLOCK_DESIGN_REVIEW.md)。
