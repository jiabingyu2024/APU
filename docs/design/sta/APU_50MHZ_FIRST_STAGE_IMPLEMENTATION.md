# APU 50MHz 第一阶段优化完成记录

日期：2026-06-15

## 已完成修改

本次只做第一阶段低风险优化，未改功能接口，未增加流水拍数：

- `rtl/AdderTree.sv`
  - 将默认 `P_INNUM=64` 的 64 路线性累加改为平衡组合 popcount 树。
  - 保留非 64 参数的通用 fallback。
- `rtl/FeatureProcessor.sv`
  - 将地址生成中的动态 `/`、`%`、`*` 改为 case/shift 结构。
  - `iDepth`、`inHW` 只按已验证 shape 8/16/32、1/2/4 做固定展开。
- `rtl/ComputeCoreGroup.sv`
  - 将 `weightWriteSelect != i` 的 64 路重复比较改为一次 one-hot 解码后分发。

## 设计意图

这些改动只减少组合深度和扇出，不改变：

- 输出语义
- 指令协议
- `Ctrl` 的相位
- `InBuf` residual replay 时序
- `make check` 的 golden 对拍结果

## 验证结果

已通过：

- `verilator --lint-only -Wall -Wno-fatal rtl/AdderTree.sv`
- `verilator --lint-only -Wall -Wno-fatal rtl/FeatureProcessor.sv`
- `CCACHE_DISABLE=1 make check`
- `CCACHE_DISABLE=1 verilator --binary --timing -Wno-fatal --top-module tb_inbuf_replay ...`

结果：

- `tb/tb_top_student.sv` 六个 checkpoint 全部 `PASS`
- `tb/tb_inbuf_replay.sv` 输出 `TB_INBUF_REPLAY_PASS`

## 后续建议

如果 50MHz 仍然收敛困难，下一步优先看：

1. `SIMD` threshold 读口是否仍是关键路径
2. `FeatureProcessor` 的 BRAM 读地址到数据输出路径
3. `ComputeCore` 组合 popcount 是否仍需更细的分组或加拍

