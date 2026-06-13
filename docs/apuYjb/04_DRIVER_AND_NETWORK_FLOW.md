# 驱动、数据排布与网络执行

## 1. 二值编码

ARM 前端产生 `1x64x32x32` 张量后执行：

```python
x_binary_01 = x.sign().add(-1).div(-2).int().float()
```

编码关系为：

| 浮点符号 | 写入 APU 的 bit |
|---|---:|
| 正值 | 0 |
| 负值 | 1 |
| 0 | 转整数后为 0 |

从 APU 读回后执行 `float_bit * (-2) + 1`，即 `0 -> +1`、`1 -> -1`。

## 2. 输入打包

输入由 NCHW 转成 NHWC，再按 channel 连续展开。每 32 个 channel bit 组成一个 32-bit MMIO
word。代码中的先按 MSB 构造、再 reverse，最终效果是：

```text
NHWC stream 的第 0 个 bit -> MMIO word bit[0]
NHWC stream 的第 31 个 bit -> MMIO word bit[31]
```

64 通道的每个像素对应两个 32-bit word。完整输入共：

```text
32 * 32 * 64 / 32 = 2048 word = 8192 byte
```

## 3. 输出解包

驱动从 Act SRAM (`RAM_SEL=128`) 的地址 0 读取 512 个 word，按输入打包的逆过程恢复 NHWC，
再转为 `1x256x8x8` NCHW。

当前实现只做 bit 顺序和 NHWC/NCHW 变换，没有对每个像素的四个 64-channel group 做
物理到逻辑重排。当前 RTL/TB 合同要求物理 group `3,2,1,0` 恢复为逻辑 `0,1,2,3`。
若该合同适用于生成 `myDesign.bit` 的硬件，最终 FC 会接收到分组置换后的通道，这是低
Top-1 的首要检查项。

## 4. 32-bit 指令格式

| Bit | 字段 | 含义 |
|---:|---|---|
| `[31:30]` | `op` | 普通卷积/残差 resident 操作类型 |
| `[29:28]` | `ks` | kernel size 编码 |
| `[27:25]` | `lihw` | `log2(input H/W)` |
| `[24:21]` | `lic` | `log2(input channels)` |
| `[20:17]` | `loc` | `log2(output channels)` |
| `[16:15]` | `s1` | 主路径 stride |
| `[14:13]` | `s2` | residual/第二路径控制 |
| `[12:5]` | `wa` | weight RAM 基地址字段 |
| `[4:0]` | `bna` | BN RAM 基地址字段 |

驱动将指令写入 `RAM_SEL=130` 的 worksheet。字段宽度有限，任何网络扩展都必须先检查
通道数、地址和 stride 是否可编码。

## 5. 参数装载规则

普通卷积每个输出 channel 对应一个 weight RAM slice；输出 channel 每 64 个为一组。
驱动按 `group -> slice` 遍历，将每个 slice 的数据写入相同内部 offset。

普通卷积每 slice/group 权重 word 数：

```text
lwc = 2 * kernel_size^2 * max(input_channels / 64, 1)
```

resident 残差卷积为：

```text
lwcr = (2 * kernel_size^2 + 1) * max(input_channels / 64, 1)
```

额外的 `+1` word 用于组合 residual 路径所需数据。BN 参数按每输出 channel 一个 32-bit
word 写入 64 个 BN slice。

## 6. 五次启动、十二条指令

| APU 启动段 | Worksheet 指令 | 层 | 输入/输出规模 |
|---:|---:|---|---|
| 1 | 0..7 | layer1.0 两层、layer1.1 两层、layer2.0 两层、layer2.1 两层 | `64x32x32 -> 128x16x16` |
| 2 | 0 | `layer3.0.conv1` | `128x16x16 -> 256x8x8` |
| 3 | 0 | `layer3.0.conv2 + downsample residual` | `256x8x8 -> 256x8x8` |
| 4 | 0 | `layer3.1.conv1` | `256x8x8 -> 256x8x8` |
| 5 | 0 | `layer3.1.conv2` | `256x8x8 -> 256x8x8` |

layer3 参数不能与前八层同时驻留，所以后四条指令每次都从 weight/BN/worksheet 地址 0
重新加载并单独运行。总计仍是 12 条网络指令。

## 7. 最终读回为什么选择 Act SRAM

驱动最后写 `RAM_SEL=128`，而不是定义但未使用的 `OUT_RAM_SEL=129`。这是基于当前 12 条
累计执行后结果回到 Act SRAM 的 ping-pong 奇偶关系。改变指令总数、单段边界或 SRAM
切换规则后，最终结果可能落在另一个 bank，不能机械沿用 selector 128。

驱动在正式读回前还执行一次地址 0 的 dummy read。代码本身没有证明该读取是否必需；
它可能用于适配同步 RAM/bridge 首次读延迟。重新设计 MMIO wrapper 时应通过波形确认，
不能在无验证的情况下删除或依赖它。
