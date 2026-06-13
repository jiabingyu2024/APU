# 准确率与分层调试

## 1. 如何理解当前现象

若程序能稳定完成，但出现约 `Top-1 20%`、`Top-5 90%`，说明“APU 可启动并完成”不等于
“bit-exact 正确”。Top-5 较高表示正确类别经常仍在前五名，优先怀疑系统性通道置换、参数
版本不一致、符号编码或模型前后端不配套，而不是单纯 MMIO 完全失效。

这只是故障特征判断，不能仅凭两个准确率数字确定根因。

## 2. 推荐定位顺序

### 第一步：确认 checkpoint 真的匹配

`resnet_binary_ps.py` 使用 `load_state_dict(..., strict=False)`，并且不打印 missing/unexpected
keys。即使部分层没有加载，也可能显示“成功加载模型权重”。应在诊断版本中记录这两类 key，
确认 ARM 的 `conv1/bn1/fc/bn3` 均来自预期 checkpoint。

### 第二步：确认 APU 输入 bit-exact

固定一张 CIFAR-10 样本，保存 `packed_input`，与软件导出或 RTL TB 的 `input_binary.txt` 对比。
首个 word 就不一致时，检查：

- 图像是否完全相同；
- Normalize 参数是否与训练一致；
- `eval()` 是否已调用；
- NCHW -> NHWC 和 bit 0/1 符号定义是否一致。

### 第三步：逐层找首个 mismatch

不要直接比较最终分类。按以下顺序将仿真/硬件中间结果与 `data_flow/` 对比：

```text
layer1.0 -> layer1.1 -> layer2.0 -> layer2.1 -> layer3.0 -> layer3.1
```

首个不一致节点最有价值：

- conv 首次错：检查 weight 排列、64-bit 拼接、地址和卷积控制；
- conv 对但 BN 错：检查 BN 参数、阈值、有符号比较；
- 主支路对但 combine 错：检查 resident 权重和 residual SRAM；
- 只有最终 NCHW 错：检查输出 group/channel 重排。

### 第四步：检查最终 256 通道 group 顺序

当前驱动按 MMIO 地址顺序直接解释每个像素的四个 64-channel group。当前 RTL 的验证合同
要求反向解释物理 group。可用单个像素做诊断：分别统计或打印 channel `0..63`、`64..127`、
`128..191`、`192..255`，检查它们是否按整组 `3,2,1,0` 置换。

如果只做 group 重排就能让最终 APU tensor 与 golden bit-exact，一般可以在驱动解包层修复；
如果第一层已经 mismatch，仅修改最终解包不会让分类正确。

### 第五步：确认参数 bundle

`apuYjb/param` 与当前仓库 `data/param_files` 的 27 个共同文件内容全部不同，而 37 个共同
`data_flow` 文件相同。不能把两套参数交叉替换后继续用原 golden 做结论。必须确定：

```text
checkpoint -> 参数导出脚本 -> param -> RTL/TB golden -> bitstream
```

来自同一个版本链。

## 3. 故障现象对照

| 现象 | 优先检查 |
|---|---|
| 卡死且 CPU 占用低 | `CPL` 无 timeout、HSEL/HREADY、APU reset/clock |
| `CPL` 正常但全零 | RAM owner、RAM_SEL、最终 bank、参数是否写入 |
| 每张图输出几乎相同 | 输入未更新、旧 `CPL`、参数/feature RAM 写失败 |
| 低层就错 | 权重格式、地址、32/64-bit word 顺序 |
| 只在 channel 块上错 | 64-channel group 顺序 |
| APU 输出对但 logits 错 | checkpoint 的 FC/BN、0/1 到 -1/+1 转换 |
| 低频正确、高频随机错 | post-route timing 未收敛 |
| Top-5 高、Top-1 低 | 通道置换、部分层/参数版本不匹配 |

## 4. 每次实验应记录

为了让结果可复现，每次板测至少记录：

- bit、HWH、checkpoint 的 SHA-256；
- `apu_driver.py` 的 git commit 或 checksum；
- 输入样本索引和标签；
- packed input 前若干 word；
- 最终 raw SRAM 前若干 word；
- 首个 mismatch 的层名、word index、expected/actual；
- Top-1、Top-5、样本数和平均耗时；
- Vivado post-route WNS/TNS 与实际 APU 时钟。

## 5. 不能采用的判断方式

- LED 或 `CPL=1` 只能证明控制流完成，不能证明数值正确。
- 单张图片预测正确不能证明通道和参数合同正确。
- shape 正确不能证明 channel 顺序正确。
- 参数文件行数相同不能证明内容或编码相同。
- Vivado 生成 bit 不能替代时序 signoff。
