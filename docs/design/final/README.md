# APU 最终设计文档索引

## 1. 文档定位

本目录是 `dev1` 当前已验证 RTL 的唯一最终设计基线。目标不是描述一个理想化
CNN 加速器，而是准确记录仓库中已经通过 layer1、layer2、layer3 bit-exact
回归的实现合同，使读者或代码生成模型能够仅依据本文档重新实现等价 RTL。

事实优先级如下：

1. 本目录中的规范性描述。
2. 当前 `rtl/`、`tb/`、`scripts/compare_outputs.py` 的已验证行为。
3. `docs/archive/` 中的历史审查和修复证据。
4. `docs/design/` 旧文档中的阶段性描述。

历史文档可能包含修复前结论。遇到冲突时，以本目录为准。

## 2. 阅读顺序

| 文件 | 内容 | 主要用途 |
| --- | --- | --- |
| [01_SYSTEM_ARCHITECTURE.md](01_SYSTEM_ARCHITECTURE.md) | 设计边界、层次、数据通路、时钟复位 | 建立整机模型 |
| [02_PROGRAMMING_MODEL.md](02_PROGRAMMING_MODEL.md) | AHB、寄存器、RAM 片选、启动完成协议 | 重建外部接口 |
| [03_INSTRUCTION_AND_NETWORK.md](03_INSTRUCTION_AND_NETWORK.md) | 指令格式、网络映射、批次与容量 | 重建指令调度 |
| [04_DATA_AND_MEMORY_LAYOUT.md](04_DATA_AND_MEMORY_LAYOUT.md) | 二值语义、特征/权重/BN 布局 | 避免通道和端序错误 |
| [05_CONTROL_AND_TIMING.md](05_CONTROL_AND_TIMING.md) | Ctrl 状态机、计数器、地址、逐拍流水 | 重建控制器 |
| [06_MODULE_CONTRACTS.md](06_MODULE_CONTRACTS.md) | 每个 RTL 模块的接口和行为合同 | 逐模块生成 RTL |
| [07_RESIDUAL_PATH.md](07_RESIDUAL_PATH.md) | residual/shortcut 路径和 InBuf replay | 处理最易错路径 |
| [08_VERIFICATION_AND_REBUILD.md](08_VERIFICATION_AND_REBUILD.md) | 回归、断言、重建顺序、验收条件 | 验证重新生成的 RTL |
| [09_ERRATA_AND_RISKS.md](09_ERRATA_AND_RISKS.md) | 历史误判、已修 bug、未消除风险 | 防止重复引入旧 bug |

## 3. 当前验收状态

基线提交：`7422f04`，日期：2026-06-10。

标准命令：

```bash
CCACHE_DISABLE=1 make check
```

必须达到：

| 检查点 | 期望 |
| --- | --- |
| `layer1.1_tanh3` | 0 bit mismatch |
| `layer2.1_tanh3` | 0 bit mismatch |
| `layer3.0_tanh1` | 0 bit mismatch |
| `layer3.0_tanh3` | 0 bit mismatch |
| `layer3.1_tanh1` | 0 bit mismatch |
| `layer3.1_bn3` | 0 bit mismatch |

## 4. 规范关键词

- **必须**：重建 RTL 为保持兼容必须满足。
- **当前实现**：描述已通过回归的代码行为，可能不是理想架构。
- **建议重构**：允许改善实现，但必须通过全部兼容性测试。
- **禁止推断**：现有证据不足，不能从局部通过推广到其他配置。

## 5. 设计边界

当前基线只保证文档列出的二值 ResNet 固定网络：空间尺寸 32/16/8，通道数
64/128/256，卷积核 3x3，主路径 stride 1/2，以及两条下采样 residual 指令。
参数虽然以 `parameter` 和指令字段表达，但不能据此宣称任意尺寸、任意通道、
1x1 或全部 16 条 worksheet 均已验证。

