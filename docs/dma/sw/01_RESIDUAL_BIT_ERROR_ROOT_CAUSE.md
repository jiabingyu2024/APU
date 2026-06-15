# 个别 bit 不一致的 RTL 根因审查

日期：2026-06-15

本文记录修改前的定位证据。后续 RTL 修复见 [02_INBUF_REPLAY_FIX.md](02_INBUF_REPLAY_FIX.md)。bitstream 尚未重新综合。

## 结论

当前输出 bit 不一致的首个故障点是 `layer2.0.conv2 + downsample residual`。普通卷积路径在进入该层前保持逐位正确。

根因高度集中在 `rtl/InBuf.sv` 的 residual shortcut 重放逻辑：第一个 64 通道输出组直接读取 shortcut，结果完全正确；第二个 64 通道输出组依赖 `InBuf` 临时缓存重放，全部 880 个错误 bit 都出现在该组。

因此这不是 JPEG、checkpoint、参数导出、输入打包、DMA 输出解包、通道组顺序或普通卷积计算错误。也不是仅最后一个 SRAM word 未写完。

## 板上定位过程

使用的输入、checkpoint 和参数与最终测试 02/05 完全一致：

- `apuYjb/image/cifar10_test_image.jpg`
- `apuYjb/model_best.pth.tar`
- `apuYjb/param/*.txt`

DMA 五个真实执行阶段读回结果：

| 阶段输出 | mismatch / total |
|---|---:|
| `layer2.1.conv2` | 1721 / 32768 |
| `layer3.0.conv1` | 990 / 16384 |
| `layer3.0.conv2` | 1012 / 16384 |
| `layer3.1.conv1` | 953 / 16384 |
| `layer3.1.conv2` | 436 / 16384 |

继续对前八层做前缀运行，每次重新下载同一个 `apu_dma.bit` 以复位控制状态：

| 层输出 | mismatch / total |
|---|---:|
| `layer1.0.conv1` | 0 / 65536 |
| `layer1.0.conv2` | 0 / 65536 |
| `layer1.1.conv1` | 0 / 65536 |
| `layer1.1.conv2` | 0 / 65536 |
| `layer2.0.conv1` | 0 / 32768 |
| `layer2.0.conv2` residual | 880 / 32768 |
| `layer2.1.conv1` | 1301 / 32768 |
| `layer2.1.conv2` | 1721 / 32768 |

`layer2.0.conv2` 再按物理 64 通道组统计：

```text
group 0, channels 0..63:    0 mismatch
group 1, channels 64..127: 880 mismatch
```

这项证据非常关键。主 residual 计算、shortcut 地址和第一组 shortcut 数据均能得到逐位正确结果；故障只在第二组需要复用 shortcut 时出现。

## RTL 原因

相关文件：[InBuf.sv](../../../rtl/InBuf.sv)

`InBuf` 使用 `count_top=38/152` 和固定计数点缓存 shortcut，供后续输出组重放：

- 第 53 行：根据尺寸选择固定周期 38 或 152。
- 第 55 至 56 行：`fromram`、`temp1`、`temp2` 保存重放状态。
- 第 58 和 73 行：这些保存状态由不完整的 `always_comb` 块赋值。
- 第 78、84 行：只在 `count==18/36/37` 时捕获数据。
- 第 160、170 行：只在 `count>20/40` 后切换到缓存数据。

存在两个直接问题：

1. `fromram/temp1/temp2` 在 `always_comb` 中没有默认赋值，也没有覆盖全部分支。为了“保持上次值”，综合器只能推断锁存器。这些状态没有显式时钟边界和复位语义。
2. shortcut 捕获与重放依赖硬编码计数点，没有和 `FeatureProcessor -> InBuf` 的同步读延迟建立显式 valid 对齐。任一地址、SRAM 或输入选择信号相差一拍，第二输出组就会复用相邻或旧 shortcut word。

第一个输出组直接使用 SRAM 数据，因此不经过这条有问题的 replay 路径并保持 0 mismatch。第二输出组使用 `temp1`，与板上错误分组完全对应。

`dma/vivado/package_apu_dma_ip.tcl` 第 29 行确认 DMA IP 直接打包同一个 `rtl/InBuf.sv`。myDesign 旧路径也实例化该模块，所以两条硬件路径都可能出现 residual 错误；wrapper 和执行分段不同会让最终错误掩码不同。

## 为什么最终只表现为少量 bit

`InBuf` 并非让整个 residual 失效，而是让第二输出组中的部分 shortcut word 取错。只有累加结果因此跨过 BN 阈值的通道才会发生二值翻转。

这些早期错误继续进入后续二值卷积，错误数量会变化，不会保持固定比例。因此最终层只看到约 410/430 个错误 bit，但首次 residual 层已经有 880 个错误 bit。

## 已排除项

- APU 输入：02、05 与软件参考均为 0 / 65536 mismatch。
- 权重：12 个主卷积和 2 个 downsample 权重与 checkpoint 逐位一致。
- BN：方向位完全一致，阈值导出误差小于 1 个整数计数。
- 普通卷积：前五层板上输出逐位一致。
- 输出位序：通道组反序会将最终误差扩大到约 8200 bit。
- 单纯尾 word 未写回：最终错误分散在 202/256 和 205/256 个 64-bit word 中。

## 次要 RTL 风险

完成握手仍有独立风险，但不是当前 880-bit 首次分叉的主因：

- `Ctrl.sv` 在置 `oComputeDone` 后，最后一个输出 word 还依赖 IDLE 中的延迟写回脉冲。
- `WorkSheet.sv` 第 90 至 91 行看到 `iComputeDone` 后立即置 `oWorkSheetDone`。
- `apu_dma_core.sv` 第 144 行直接令 `core_done = worksheet_done`。

这意味着外部控制器可能在尾写真正落入 SRAM 前观察到完成。当前错误遍布整层而非只在最后 word，所以它不是本次主因；后续修复 residual 后仍应单独验证该时序。

## 修改前建议的波形确认点

下一步修改 RTL 前，应在 `layer2.0.conv2` 的一个空间点上同时观察：

```text
state, count, cut_num, res_flag
oActReadEn, oOutReadEn, oInputBufSelect
ActData, OutData, InBufData
fromram, temp1, temp2
oWeightAddr, oAccInstr, ComputeCoreData
```

重点比较输出组 0 的 shortcut 拍和输出组 1 的 replay 拍。预期会看到组 1 的 `InBufData` 与组 0 对应 shortcut word 不一致或相差一拍。

## 复现命令

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
python3 dma/sw/diagnose_dma_stages.py
python3 dma/sw/diagnose_dma_prefixes.py
python3 dma/sw/diagnose_dma_prefixes.py --prefix 6
python3 dma/sw/diagnose_bit_errors.py
```

在修复并重新综合之前，软件参考分类 `plane` 仍是 02/05 的对齐标准。
