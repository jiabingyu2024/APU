# Archive

本目录保存历史探索、旧方案、问题定位和参考资料。归档内容用于复查，不作为当前项目的默认运行入口。

当前最终路线请看：

- [../design/final/README.md](../design/final/README.md)：基础 APU RTL。
- [../apuYjb/README.md](../apuYjb/README.md)：旧版 PYNQ MMIO/AHB 基线。
- [../dma/README.md](../dma/README.md)：最终 DMA 支线。

## Archived Branches

| 路径 | 内容 | 当前状态 |
| --- | --- | --- |
| [soc/](soc/README.md) | PicoRV32 + APU SoC 探索文档 | 已弃用，只保留记录 |
| [fpga/](fpga/README.md) | 早期 PL-only/PYNQ-Z2 上板探索文档 | 已弃用，只保留记录 |
| [explore/](explore/) | PicoRV32/SoC 方案探索笔记 | 已归档 |
| [reference/](reference/) | 外部手册、参考资料 | 已归档 |

## Historical Debug Notes

根目录下的若干 Markdown 是历史 bug 定位和 RTL 修复记录，例如 residual、AHB 数据布局、layer mismatch 等。它们可能描述的是修复前行为；若与当前设计文档冲突，以 `docs/design/final/` 和当前 `rtl/` 为准。
