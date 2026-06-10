# 07 Residual 路径专题

## 1. 功能模型

当前 residual 指令 `calc_type=01` 完成：

```text
主路径:     较小 feature 上的 3x3 conv2 Hamming 累加
shortcut:   较大、通道减半 feature 上的 stride-2 1x1 Hamming 累加
combine:    两者在同一 12-bit accumulator 内直接相加
postprocess: SIMD 阈值比较并写回
```

它不是先生成两张中间图再逐元素加法。主路径和 shortcut 使用一个 accumulator，
因此 combined 参数文件、Ctrl 插拍和 InBuf 数据选择是一个不可拆分的协议。

## 2. 两块 SRAM 的角色

Residual 开始时，当前 ping-pong 主源保存上一条 conv1 的较小 feature，另一块
SRAM 仍保留 residual block 输入的较大 feature。

| 状态 | 主源 | 另一块 SRAM |
| --- | --- | --- |
| CONV | 读取较小 feature，3x3 | 不读或准备 shortcut |
| CONV2 | 关闭主源 | 读取较大 feature 的 stride-2 位置 |
| 写回 | 写入另一块 SRAM | 可能覆盖刚读取的旧 residual 输入 |

由于输出组多于 shortcut 输入组，同一个 shortcut 输入必须供多个输出组复用。
第一输出组写回后，旧 residual feature 的地址可能被覆盖，所以不能每次都重新从
SRAM 读取。

## 3. 每个物理输出组的周期数

| 配置 | IG | 主路径 | shortcut | 合计 |
| --- | ---: | ---: | ---: | ---: |
| layer2 residual | 2 | 18 | 1 | 19 cycles |
| layer3 residual | 4 | 36 | 2 | 38 cycles |

一个像素包含 OG 个输出组：

```text
layer2: OG=2 -> 38 cycles/pixel
layer3: OG=4 -> 152 cycles/pixel
```

这正是 InBuf 的 `count_top=38/152` 来源。

## 4. CONV 到 CONV2 的切换

CONV 在 `cycle==8` 且当前 9-cycle chunk 是该输出组最后一个 chunk 时跳转：

```text
IG=2: cut_num[0]   == 1
IG=4: cut_num[1:0] == 3
```

CONV2 长度：

```text
IG=2 -> 1 cycle
IG=4 -> 2 cycles
```

每个 CONV2 拍：

- WeightAddr 继续加 1，读取 combined 文件中的 shortcut word。
- Feature 读使能切到另一块 SRAM。
- InBuf 选择 shortcut SRAM 数据或已保存 replay 数据。
- Accumulator 保持 ADD，把 shortcut popcount 加入主路径结果。

最后一个输出组的 CONV2 结束时直接产生 `ComputeDone` 和 ping-pong 翻转。

## 5. InBuf 当前实现

InBuf 的普通路径是单级 64-bit 寄存器 `rBuf`。Residual 模式还维护：

| 状态 | 含义 |
| --- | --- |
| `count` | 当前像素 residual 全输出组周期位置 |
| `count_top` | layer2 为 38，layer3 为 152 |
| `fromram` | count==1 时锁存的主路径 SRAM 选择 |
| `temp1/temp2` | 首输出组捕获的 shortcut 64-channel 输入组 |

`nWe=1` 时 InBuf 保持 `rBuf` 并把 `count` 清零；正式运行 `nWe=0` 后计数。

## 6. Layer2 replay 时序

Layer2 shortcut 只有一个 64-channel group：

```text
count 0..17 : output group 0 主路径 18 拍
count 18    : output group 0 shortcut，捕获 temp1
count 19..36: output group 1 主路径
count 37    : output group 1 shortcut，使用 temp1 replay
```

当前代码的 replay 开关使用 `count>20`，因此第二输出组进入另一 SRAM 读取窗口时
输出保存值。`temp` 在 layer2 始终等于 `temp1`。

如果不 replay，第一输出组写回可能覆盖 shortcut 源，第二输出组会读到刚写入的
结果而不是 residual block 原输入。

## 7. Layer3 replay 时序

Layer3 shortcut 有两个输入组，每输出组共 38 拍：

```text
count 0..35 : output group 0 主路径
count 36    : shortcut group 0，捕获 temp1
count 37    : shortcut group 1，捕获 temp2
count 38..73: output group 1 主路径
count 74/75 : replay temp1/temp2
...直到 output group 3
```

选择保存值的当前表达式：

```text
count % 38 == 36 -> temp1
otherwise         -> temp2
```

且只在 `count>40`、运行数据源切换到非主 SRAM 时启用 replay。

## 8. 主源预置修复

Residual 紧随普通卷积时，新主源可能是 OutSRAM。旧逻辑在 IDLE 或 InBuf 禁写时
把 `oInputBufSelect` 固定为 0，导致首个 `ACC_LOAD` 使用 ActSRAM 遗留值。

规范行为：

```text
reset/nCe:                    select=0
IDLE 或 oInputBufNWe==1:     select=pingpong
运行:                        select=oOutReadEn
```

该规则必须在地址发出和 InBuf 首次写入之前生效。

## 9. 当前实现中的 latch 风险

`fromram/temp1/temp2` 在 `always_comb` 中没有默认赋值，综合语义是锁存器。其功能
意图是跨周期保存 shortcut 数据，但写法不适合作为最终 ASIC 实现。

等价重构必须使用显式 `always_ff`：

```text
if residual_start: capture main_source
if shortcut_capture_valid && shortcut_group==0: temp1 <= selected_sram_data
if shortcut_capture_valid && shortcut_group==1: temp2 <= selected_sram_data
```

并以显式 `{pixel,output_group,shortcut_group}` 控制 replay。重构前后应对比全部
accumulator 整数，不仅比较最终二值输出，因为 BN 阈值可能掩盖少量算术错误。

## 10. Combined 权重顺序合同

每个 output group 的 bank 地址顺序必须为：

```text
for kernel in 0..8:
  for ig in 0..IG-1:
    main_weight[ig][kernel]
for shortcut_group in 0..IG/2-1:
  shortcut_weight[shortcut_group]
```

当前 Ctrl 的全局 WeightAddr 连续序列与此等价。不同 output group 紧邻存放。

不要通过“保持首地址一拍”修复指令预取；历史实验表明这会把局部首项错误扩大为
整层权重错位。

## 11. Residual 验收条件

1. Layer2 residual 512 个 64-lane accumulator word 全部整数一致。
2. Layer3 residual 256 个 64-lane accumulator word全部整数一致。
3. 首 output word 不含上一指令 partial sum。
4. 第二及后续 output group 的 shortcut 数据与首组捕获值一致。
5. 每个 output group 恰好读取 `9*IG+IG/2` 个权重 word。
6. 整条 residual 只翻转一次 ping-pong。
7. 输出经 canonical group 重排后与 tanh3 golden 0 mismatch。
