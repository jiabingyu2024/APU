# 03 指令格式与网络映射

## 1. 指令格式

每条指令 32 bit，无独立 valid 位。WorkSheet 通过已写入条数确定序列长度。

| 位域 | 字段 | 当前语义 |
| --- | --- | --- |
| `[31:30]` | `calc_type` | `00` 普通卷积；`01` residual combined；`11` 被 Ctrl 当无效 |
| `[29:28]` | `kernel_size` | 数值 `3` 表示 3x3；其他值按 1x1 路径处理 |
| `[27:25]` | `logInHW` | 输入主路径 H/W 的 log2：5/4/3 |
| `[24:21]` | `logInC` | 主路径输入通道 log2：6/7/8 |
| `[20:17]` | `logOutC` | 输出通道 log2：6/7/8 |
| `[16:15]` | `stride1` | 主卷积步长；当前数值 1 或 2 |
| `[14:13]` | `stride2` | shortcut 步长；当前 residual 使用 2 |
| `[12:5]` | `wAddr` | 每个 WeightSRAM bank 的 64-bit 基地址 |
| `[4:0]` | `bnAddr` | 每个 SIMD channel 的参数 entry 基地址 |

打包公式：

```text
inst = calc_type<<30 | kernel_size<<28 | logInHW<<25 |
       logInC<<21 | logOutC<<17 | stride1<<15 |
       stride2<<13 | wAddr<<5 | bnAddr
```

如果字段宽度或拼接顺序改变，Ctrl 的组合解码会整体错位，且不会产生非法指令
异常，因此必须原样保持。

## 2. Ctrl 派生量

当前只显式支持以下编码：

```text
logInHW 3/4/5 -> in_hw_num 8/16/32
logInC  6/7/8 -> totalRound1 1/2/4
logOutC 6/7/8 -> totalRound2 1/2/4
```

定义：

```text
in_groups    = totalRound1 = Cin/64
out_groups   = totalRound2 = Cout/64
totalRound   = in_groups*out_groups
cyclePerTime = kernel_size==3 ? 9 : 1

normal output_hw = input_hw / stride1
residual output_hw = input_hw
timePerRound = output_hw*output_hw
```

`round/t` 在代码中主要用于总迭代次数和结束判断，真正的数据线性索引是
`cut_num`。不要根据变量名把当前循环误写为标准三层嵌套。

## 3. 已验证网络指令

| 序号 | op | shape | type | `wAddr` | `bnAddr` | 指令字 |
| ---: | --- | --- | ---: | ---: | ---: | --- |
| 1 | layer1.0 conv1 | 32x32x64 -> 32x32x64 | normal s1 | 0 | 0 | `0x3ACC8000` |
| 2 | layer1.0 conv2 | 32x32x64 -> 32x32x64 | normal s1 | 9 | 1 | `0x3ACC8121` |
| 3 | layer1.1 conv1 | 32x32x64 -> 32x32x64 | normal s1 | 18 | 2 | `0x3ACC8242` |
| 4 | layer1.1 conv2 | 32x32x64 -> 32x32x64 | normal s1 | 27 | 3 | `0x3ACC8363` |
| 5 | layer2.0 conv1 | 32x32x64 -> 16x16x128 | normal s2 | 36 | 4 | `0x3ACF0484` |
| 6 | layer2.0 residual | 16x16x128 -> 16x16x128 | residual | 54 | 6 | `0x78EEC6C6` |
| 7 | layer2.1 conv1 | 16x16x128 -> 16x16x128 | normal s1 | 92 | 10 | `0x38EE8B8A` |
| 8 | layer2.1 conv2 | 16x16x128 -> 16x16x128 | normal s1 | 128 | 14 | `0x38EE900E` |
| 9 | layer3.0 conv1 | 16x16x128 -> 8x8x256 | normal s2 | 0 | 0 | `0x38F10000` |
| 10 | layer3.0 residual | 8x8x256 -> 8x8x256 | residual | 0 | 0 | `0x7710C000` |
| 11 | layer3.1 conv1 | 8x8x256 -> 8x8x256 | normal s1 | 0 | 0 | `0x37108000` |
| 12 | layer3.1 conv2 | 8x8x256 -> 8x8x256 | normal s1 | 0 | 0 | `0x37108000` |

序号 11、12 指令字段相同，但在两次启动前装载不同权重和 SIMD 参数。

## 4. 执行批次

### 4.1 Layer1-only 回归

装入指令 1..4，一次启动，结果位于 ActSRAM。该模式由 TB plusarg
`+LAYER1_ONLY` 触发。

### 4.2 Layer1+Layer2

指令 1..8 必须从 worksheet 0..7 连续写入并一次启动。原因不是计算上不能拆批，
而是当前 WorkSheet 完成后从地址 0 重新发射；若第二批仍写地址 4..7，地址 0
保留旧指令，计数与实际有效地址不一致。

### 4.3 Layer3

先完成指令 1..8。之后每个 layer3 op：

1. 写新权重到 WeightSRAM 地址 0 起始。
2. 写新参数到 SIMD entry 0 起始。
3. 覆盖 worksheet 地址 0。
4. 单独启动一次。

四次启动后 ping-pong 继续按第 9..12 条累计，而不是每批从第 1 条重新开始。

## 5. 权重驻留范围

普通 3x3 每输出组的 bank 深度消耗：

| Cin | 输入组 | 64-bit word/输出组/bank |
| ---: | ---: | ---: |
| 64 | 1 | 9 |
| 128 | 2 | 18 |
| 256 | 4 | 36 |

当前前 8 条指令的地址区间：

| op | bank 地址区间 |
| --- | --- |
| l1.0 c1 | 0..8 |
| l1.0 c2 | 9..17 |
| l1.1 c1 | 18..26 |
| l1.1 c2 | 27..35 |
| l2.0 c1，2 输出组 | 36..53 |
| l2.0 residual，2 输出组 | 54..91 |
| l2.1 c1，2 输出组 | 92..127 |
| l2.1 c2，2 输出组 | 128..163 |

Layer3 普通 128->256 占 72 word/bank；256->256 占 144 word/bank；layer3
residual combined 占 152 word/bank。单个 op 均可放入 256 深度，但全部 op 不能
同时驻留。

## 6. 普通指令的线性执行序列

WeightAddr 对每个有效主路径项连续递增。`cut_num` 每完成 9 个主路径项加 1。
真正的数据顺序由 FeatureProcessor 的计数器决定：kernel 外层，输入组内层。
对一个像素，其逻辑顺序为：

```text
for output_group in physical_order:
  for kernel_pos in 0..8:
    for input_group in increasing SRAM depth order:
      accumulate XOR-popcount
```

Ctrl 把这个长度为 `9*in_groups` 的扁平序列切成 `in_groups` 个 9-cycle chunk。
因此 `cut_num % in_groups` 是 chunk 索引，不应直接命名为 input_group：

```text
load when chunk_index==0 and cycle==0
write after every in_groups completed chunks
physical_write_addr ~= cut_num / in_groups
```

当前 RTL 用位测试分别实现 `/1`、`/2`、`/4`，未实现通用除法选择。

## 7. 指令边界合同

WorkSheet 在 `iComputeDone` 有效的时钟沿切换 `oInstruction`。Ctrl 同一周期通过
`oComputeDone` 返回 IDLE，并在准备阶段预置下一条指令的主 SRAM 选择。

必须保留的修复是：

```text
state==IDLE 或 InBuf 禁写准备阶段:
    oInputBufSelect = pingpong
```

若固定为 0，紧随 OutSRAM 生产者的 residual 指令第一个 accumulator word 会采样
旧 ActSRAM 数据。历史上该 bug 只污染 residual 首 word，经过后续卷积扩散成少量
最终 bit mismatch。

## 8. 不支持和未验证项

- `calc_type=10` 没有定义。
- 1x1 数据路径虽有分支但未纳入标准回归。
- `stride1` 的判断主要依赖 bit1，除 1/2 外没有规范。
- `stride2` 在当前 Ctrl 中不作为通用算术字段使用，只对应固定下采样 residual。
- 通道数不是 64/128/256 时派生量回落到默认值，不能视为支持。
- 完整 16 条 worksheet 不安全。
