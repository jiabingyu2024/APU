# dev1 Layer3 输出不一致审查与修复准备日志

## 1. 审查信息

- 日期：2026-06-09
- 分支：`dev1`
- 前置状态：layer1 普通卷积已通过；layer2 residual 修复后完整 layer1+layer2 对拍通过
- 审查目标：验证 layer3 是否能够正确输出；若失败，记录问题、证据和后续修复准备
- 本轮约束：只审查和记录，不做 RTL 修复

关联文件：

- `rtl/Ctrl.sv`
- `rtl/InBuf.sv`
- `tb/tb_top_student.sv`
- `docs/archive/DEV1_LAYER2_RESIDUAL_FIX_LOG.md`
- `docs/archive/DEV1_LAYER2_RESIDUAL_MISMATCH_REVIEW.md`

## 2. 最终结论

当前 layer3 不能正确输出。

失败不是最终 `8x8x256` dump 的单纯四组顺序问题，因为第一条 layer3 指令 `layer3.0.conv1` 执行后已经与 golden 全图不一致；枚举每像素四个 64-channel 组的全部排列，仍无法得到 0 mismatch。

关键结论：

```text
第一失败点：layer3.0.conv1
直接对拍：7907 bit mismatch / 512 lines mismatch
最佳 64-channel 四组重排后：7739 bit mismatch / 512 lines mismatch
```

因此，不能把当前 layer3 失败归因于“最终读回顺序还没 swap”。需要继续定位 layer3 的 128->256 普通卷积输入布局、读地址、权重组顺序或多输入/多输出 group 控制。

## 3. 正确的 layer3 TB 执行方式

layer3 不能像 layer1/layer2 那样把所有权重一次性装入 WeightSRAM。

原因：

```text
WeightSRAM 每个 bank 深度 = 256 个 64-bit word
layer3.0.conv1: 128 x 3 x 3 x 256
  每个输出 64-channel 组需要 2*9 个 64-bit 输入组权重
  共 4 个输出组
  TB 写入时会超出单批 wAddr 累计容量
```

因此 layer3 的正确执行模式是：

1. 初始输入写入 ActSRAM。
2. 装入并执行 layer1+layer2 的 8 条指令，得到 `layer2.1_tanh3`。
3. layer3 每个 op 覆盖 `wAddr=0`、`bnAddr=0`、`worksheet_waddr=0`。
4. 每个 layer3 op 后调用一次 `run_apu()`。
5. 按复位以来累计完成的指令数判断最终输出 SRAM。

本次验证采用的指令序列：

| 累计指令号 | op | 运行方式 | 输出 RAM_SEL | 输出尺寸 | golden |
| ---: | --- | --- | ---: | --- | --- |
| 1..8 | layer1.0/layer1.1/layer2.0/layer2.1 | 一批执行 | 128 | `16x16x128` | `layer2.1_tanh3_output.txt` |
| 9 | `layer3.0.conv1` | 单 op | 129 | `8x8x256` | `layer3.0_tanh1_output.txt` |
| 10 | `layer3.0.conv2_combined` | 单 op | 128 | `8x8x256` | `layer3.0_tanh3_output.txt` |
| 11 | `layer3.1.conv1` | 单 op | 129 | `8x8x256` | `layer3.1_tanh1_output.txt` |
| 12 | `layer3.1.conv2` | 单 op | 128 | `8x8x256` | `layer3.1_bn3_output.txt` |

注意：仓库当前没有 `data/data_flow/layer3.1_tanh3_output.txt`，最终 layer3.1 conv2 可用的 0/1 golden 是 `layer3.1_bn3_output.txt`。

## 4. TB 配置问题修正

审查中发现一个容易误导的 TB 配置错误：

```systemverilog
// layer1/layer2 的 8 条指令已经写入 WorkSheet
// 但没有先 run_apu()
// 随后 layer3 又覆盖 worksheet 地址 0 并 run_apu()
```

`WorkSheet.totalInstrCount` 在写指令时递增，不按地址覆盖自动去重。若前 8 条 layer1/layer2 指令写入后不执行，随后写 layer3 worksheet0，会导致 `totalInstrCount` 统计被污染。这样得到的 layer3 结果不能用于判断 RTL。

修正后的验证方式是：

```systemverilog
// 1. 装入 layer1/layer2 8 条指令
run_apu(); // 先执行到 layer2.1_tanh3

// 2. layer3 每个 op 覆盖 worksheet0 并单独执行
conv_layer(..., wAddr=0, bnAddr=0, worksheet_waddr=0);
run_apu();
```

## 5. 验证命令与观测文件

仿真命令：

```bash
CCACHE_DISABLE=1 make run
```

仿真完成脉冲：

```text
486020   cpl_data: 0    // layer1+layer2 batch
1257590  cpl_data: 0    // layer3.0.conv1
1603650  cpl_data: 0    // layer3.0.conv2_combined
1934350  cpl_data: 0    // layer3.1.conv1
2265050  cpl_data: 0    // layer3.1.conv2
```

中间 dump：

```text
build/sim/layer3.0_tanh1_hw.txt
build/sim/layer3.0_tanh3_hw.txt
build/sim/layer3.1_tanh1_hw.txt
build/sim/data_out.txt
```

每个 dump 均为 512 行 32-bit，对应 `8x8x256`。

## 6. 对拍结果

对拍时已把 golden 中带空格的 `0 1` token 格式归一化为 32-bit 字符串。

| 硬件输出 | golden | 直接 bit mismatch | 直接 line mismatch | 最佳四组重排 bit mismatch | 最佳四组重排 line mismatch |
| --- | --- | ---: | ---: | ---: | ---: |
| `layer3.0_tanh1_hw.txt` | `layer3.0_tanh1_output.txt` | 7907 | 512 | 7739 | 512 |
| `layer3.0_tanh3_hw.txt` | `layer3.0_tanh3_output.txt` | 8319 | 512 | 7639 | 512 |
| `layer3.1_tanh1_hw.txt` | `layer3.1_tanh1_output.txt` | 8392 | 512 | 5868 | 512 |
| `data_out.txt` | `layer3.1_bn3_output.txt` | 6693 | 512 | 3709 | 512 |

第一条 layer3 指令的首行差异示例：

```text
layer3.0_tanh1 line 0:
  hw     = 11000010000010100110110011001110
  golden = 00100111110011101000001010101110
  diff   = 16 bit
```

如果只是最终 `256-channel` 四个 64-channel 组输出顺序错误，那么 `layer3.0.conv1` 的每像素四组排列中应存在一种排列能大幅收敛到 0 mismatch。实际最佳排列仍然全 512 行 mismatch，因此当前问题不是 dump adapter 单点能修复。

## 7. 当前可疑方向

### 7.1 layer2 输出到 layer3 输入的 128-channel 存储契约

layer2 修复中已经确认：

```text
128-channel 硬件 SRAM 顺序与 golden 的低/高 64-channel 组顺序相反
```

TB 对 layer2 对拍时通过 `swap_channel_groups=1` 把硬件 SRAM dump 转成 golden 顺序。但真实硬件继续执行 layer3 时，layer3 读取的是未转换的 SRAM 原始顺序。

如果 layer3 的权重/golden 生成默认输入 channel 顺序是 golden 顺序，而 RTL 实际读到的是硬件原始顺序，则 `layer3.0.conv1` 会从第一条指令开始全图错误。这与当前“layer3.0.conv1 首项即全图 mismatch”的现象一致。

这还不是最终定论，因为需要进一步做隔离实验：

1. 将 `layer2.1_tanh3_output.txt` 按 golden 顺序直接写入 ActSRAM，只跑 `layer3.0.conv1`。
2. 将同一输入按硬件 128-channel 原始顺序写入 ActSRAM，只跑 `layer3.0.conv1`。
3. 比较哪一种输入顺序能匹配 `layer3.0_tanh1_output.txt`。

若 golden 顺序通过，则 layer3 计算本身基本正确，主问题是 layer2->layer3 内部 SRAM channel order 契约未统一。

### 7.2 Ctrl 对 4 个输入 group、4 个输出 group 的地址/写回控制

layer3.0.conv1 是普通卷积：

```text
16x16x128 -> 8x8x256
in groups  = 2
out groups = 4
totalRound = 8
```

这比 layer2 的 `128-channel` 场景多了 4 个输出组。需要重点检查：

- `round` 与 `t` 的遍历顺序是否等价于 golden 的 output-channel group 顺序；
- `cut_num/totalRound` 到 Feature SRAM 地址的映射是否正确；
- `oBNAddr` 是否按 4 个输出组循环；
- 写回地址是否按 `cut_num / totalRound1` 或 `cut_num / input_groups` 正确压缩；
- WeightSRAM 地址在 4 个输出组之间的跳转是否与参数文件布局一致。

### 7.3 InBuf replay 对 layer3 residual 的风险

`layer3.0.conv2_combined` 是 residual，`InBuf.sv` 当前存在硬编码：

```systemverilog
assign count_top=(in_hw==3'b100)?38:152;
```

这意味着：

```text
layer2 residual in_hw=16 -> count_top=38
layer3 residual in_hw=8  -> count_top=152
```

同时 replay 逻辑依赖 `36/37/40/38` 等 magic cycle 和组合 latch。虽然当前第一失败点已经在 `layer3.0.conv1`，但 residual 阶段仍然是后续必须修的高风险点。

## 8. 后续修复准备建议

建议按以下顺序推进，不要先改 InBuf replay：

1. 先做 `layer3.0.conv1` 隔离输入顺序实验，确认 layer2->layer3 的 128-channel 输入顺序是否是第一根因。
2. 若输入顺序实验通过，冻结全网络内部 SRAM channel group 顺序，决定 RTL 写回顺序和 golden/TB adapter 是否统一。
3. 若两种输入顺序都不通过，继续在 `layer3.0.conv1` 上记录 accumulator 整数输出，对比 `layer3.0_conv1_output.txt`，定位是输入地址、权重地址、BN/SIMD 还是写回顺序。
4. 在普通 layer3 conv1 通过后，再修 `layer3.0.conv2_combined` residual，重点处理 `InBuf.sv` replay 的硬编码与 latch。
5. 扩展 TB dump 任务支持明确的 256-channel group reorder mode，而不是复用 `swap_channel_groups` 这个 128-channel 二组交换参数。

## 9. 本轮未做事项

- 未修复 layer3 RTL。
- 未修改 `rtl/InBuf.sv`。
- 未修改 `rtl/Ctrl.sv` 的 layer3 地址或 round 控制。
- 未确认 256-channel 四组的最终规范顺序。
- 未完成 `layer3.0.conv1` 的 canonical/hardware-order 输入隔离实验。

## 10. 结论

layer2 修复已经让完整 layer1+layer2 达到 0 mismatch，但 layer3 仍失败。

当前最强证据是：

```text
layer3.0.conv1 是第一失败点；
失败覆盖全部 512 行；
四个 64-channel 组任意重排仍不能通过；
因此 layer3 不是最终 dump 顺序单点问题。
```

下一轮修复应从 `layer3.0.conv1` 开始，不要先修 residual。优先验证 layer2 输出进入 layer3 时的 128-channel 内部 SRAM 顺序契约；如果该实验排除，再进入 Ctrl/Weight/BN/写回地址的逐周期定位。
