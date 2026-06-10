# dev1 Layer3 输出修复日志

## 1. 修复信息

- 日期：2026-06-10
- 分支：`dev1`
- 触发文档：`docs/archive/DEV1_LAYER3_OUTPUT_MISMATCH_REVIEW.md`
- 目标：layer3 全部输出 bit-exact，并保证 layer1、layer2 和完整流程不回归
- 约束：按用户要求未创建 skill backup 目录

## 2. 最终结论

本次失败由 TB 契约问题和一个 RTL 边界语义问题叠加造成，并非 layer3
卷积地址、权重遍历或 residual replay 全局错误。

1. TB 在前 4 条 layer1 后提前 `run_apu()`，随后却把 layer2 指令写到
   worksheet 4..7；下一批仍从 worksheet 0 开始，实际不会按预期执行 layer2。
2. 256-channel SRAM 每像素四个 64-channel 组的物理顺序为 `3,2,1,0`，
   原 dump 未转换为 golden 的 `0,1,2,3` 顺序。
3. 修正以上 TB 问题后，layer3.0 两个 op 已 0 mismatch；layer3.1.conv1
   仅剩 2 bit，最终输出剩 21 bit。
4. layer3.1.conv1 的 16384 个 accumulator 整数全部与 golden 一致。两处
   bit 错误均满足 `accumulator == threshold == 1086`，且 BN 方向位为 0。
5. RTL 原逻辑对方向位 0 使用 `~(acc > threshold)`，等价于 `acc <= threshold`；
   golden 语义要求严格小于，因此等值点输出错误。

## 3. RTL 修复

文件：`rtl/SIMD.sv`

修复前：

```systemverilog
temp = acc > threshold;
out  = direction ? temp : ~temp;
```

其中反向分支实际为 `acc <= threshold`。

修复后：

```systemverilog
out = direction ? (acc > threshold) : (acc < threshold);
```

正向和反向均使用严格比较，`acc == threshold` 时输出 0，匹配参数生成侧语义。

## 4. TB 与回归修复

- layer1+layer2 的 8 条指令恢复为同一 worksheet batch 后统一启动。
- 增加 `+LAYER1_ONLY` 检查点，单独验证 layer1 最终输出。
- 在完整流程中增加 layer2 输出 dump。
- dump task 改为接受 `channel_groups=1/2/4`，按像素逆转 SRAM 中的
  64-channel 组，统一输出为 golden channel order。
- 新增 `scripts/compare_outputs.py`，对六个检查点统计 bit/line mismatch。
- 新增 `make check`，自动运行完整流程、layer1-only 和全部对拍。

## 5. 验证结果

命令：

```bash
CCACHE_DISABLE=1 make check
```

结果：

| 检查点 | bit mismatch | line mismatch |
| --- | ---: | ---: |
| `layer1.1_tanh3` | 0 | 0 / 2048 |
| `layer2.1_tanh3` | 0 | 0 / 1024 |
| `layer3.0_tanh1` | 0 | 0 / 512 |
| `layer3.0_tanh3` | 0 | 0 / 512 |
| `layer3.1_tanh1` | 0 | 0 / 512 |
| `layer3.1_bn3` | 0 | 0 / 512 |

完整流程完成脉冲共 5 次：layer1+layer2 batch 一次，layer3 四个 op 各一次。

## 6. 未纳入本次修复的风险

Verilator 仍报告既有 warning，包括 `Ctrl.sv` 读地址组合 latch、`InBuf.sv`
replay latch、若干宽度和 TB `INITIALDLY` warning。本次 bit-exact 回归证明这些
warning 未阻塞当前固定网络，但它们仍不适合作为 ASIC signoff 状态，应另立任务处理。

## 7. 变更文件

- `rtl/SIMD.sv`
- `tb/tb_top_student.sv`
- `scripts/compare_outputs.py`
- `Makefile`
- `docs/archive/DEV1_LAYER3_OUTPUT_FIX_LOG.md`
- `doc/rtl_changes.json`
