# 02/05 软件理想输出对齐说明

RTL 根因审查见 [01_RESIDUAL_BIT_ERROR_ROOT_CAUSE.md](01_RESIDUAL_BIT_ERROR_ROOT_CAUSE.md)。
RTL 修复与重新综合指南见 [02_INBUF_REPLAY_FIX.md](02_INBUF_REPLAY_FIX.md)。

## 对齐范围

这套软件参考只用于比较：

- `dma/final_tests/02_mydesign_inference.py`
- `dma/final_tests/05_apu_dma_inference.py`

两者的共同输入和参数为：

- 图片：`apuYjb/image/cifar10_test_image.jpg`
- 图片 SHA256：`f65f3c5a08208d134ec71b920355b5b1736177b23ba22dad28c288d17805d26d`
- checkpoint：`apuYjb/model_best.pth.tar`
- checkpoint SHA256：`008a6afb2b7633f8df5e65fc45feefc6811ca79ff41a5090e393830f69314b8e`
- APU 中间层参数：`apuYjb/param/*.txt`
- 预处理：`Resize(32) -> ToTensor -> ImageNet Normalize`
- 二值约定：正数为 0，负数为 1

不使用 `data/param_files`、`data/data_flow` 或 RTL TB 固定向量。这些属于另一条验证路径，不能作为 02/05 当前 JPEG 的理想输出。

## 软件参考组成

`dma/sw/ideal_inference.py` 完整执行以下流程：

1. 使用 checkpoint 的 `conv1 + bn1 + Hardtanh` 生成 `(1,64,32,32)` APU 输入。
2. 使用 `apuYjb/param` 的 12 层二值卷积、残差卷积和导出阈值计算 `(1,256,8,8)` APU 理想输出。
3. 使用 checkpoint 的 `AvgPool2d(8) + fc + bn3 + LogSoftmax` 生成最终分类结果。

程序会逐位验证导出的 12 个卷积权重和 2 个下采样权重是否等于 checkpoint 中的 `weight < 0`。当前全部为 0 mismatch。BN 方向位也与 checkpoint 的 gamma 符号完全一致，导出阈值与 checkpoint 推导值的误差小于 1 个整数计数。因此软件参考和 02/05 使用的是同一套权重与阈值。

## 2026-06-15 理想结果

```text
Ideal LogSoftmax:
[-0.102142, -9.408523, -15.653604, -6.720624, -2.345401,
 -21.873140, -16.090515, -15.705318, -13.545016, -16.032824]

Ideal prediction: 0 (plane)
Ideal APU input SHA256:
698df7862645dd6b34f31c15865550aa695ea8fe69e3d5cfc6bb8b4a012e6dce
Ideal APU output SHA256:
a236f489b1f93b1df7d9f801b436f70b644ab3874329ff13b2f979b7fd97c345
```

结果文件：`dma/sw/output/ideal_inference.json`、`ideal_apu_input.npy` 和 `ideal_apu_output.npy`。

## 板上对比结果

02 和 05 在板上采集到的 APU 输入哈希均与理想输入完全一致，65,536 位中 mismatch 为 0。因此差异不来自 JPEG、预处理、checkpoint 首层或输入打包。

| 测试 | 最终类别 | 与理想 APU 输出差异 | 输出 SHA256 |
|---|---:|---:|---|
| 02 myDesign MMIO | plane | 410 / 16,384 bit | `4b3240e0...be23` |
| 05 apu_dma | deer | 430 / 16,384 bit | `f9e964a2...ae5` |

02 与 05 的 APU 输出彼此相差 276 / 16,384 bit。对 DMA 输出尝试 64 通道组反序、组内反序以及两者组合，差异都扩大到约 8,200 bit，因此当前问题不是简单的输出通道组反序。

## 当前判断

- 软件理想分类为 `plane`，02 的最终分类与理想一致，但 APU 输出仍有 410 位差异，不能认定 myDesign 已逐位正确。
- 05 的 APU 输出与理想有 430 位差异，并使最终分类从 `plane` 翻转为 `deer`。
- 两条硬件路径收到完全相同的 APU 输入，却返回不同的 APU 输出，问题位于 APU 执行、分段状态保存/恢复、DMA job 执行或输出读回之后，不在 PS 图像预处理。
- 结合此前同一输入重复运行输出哈希变化的现象，硬件执行存在非确定性。应优先检查复位、完成握手、阶段间 RAM 所有权切换、写完成后启动时序，以及 DMA wrapper 对 APU 状态寄存器的控制。

## 复现命令

PC 生成理想输出：

```powershell
python dma\sw\ideal_inference.py
```

板上运行并采集：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/sw/compare_hardware.py
```

02/05 会在 `dma/reports/final/` 保存 JSON、实际 APU 输入 NPY 和实际 APU 输出 NPY。
