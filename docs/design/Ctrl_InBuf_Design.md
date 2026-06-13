# Ctrl 与 InBuf 详细设计说明

本文对应以下 RTL：

- `rtl/Ctrl.sv`
- `rtl/InBuf.sv`
- `rtl/FeatureProcessor.sv`
- `rtl/ComputeCoreGroup.sv`
- `rtl/ComputeCore.sv`
- `rtl/WeightSRAM.sv`
- `rtl/WeightBuffer.sv`
- `rtl/Accumulator.sv`

阅读本文时请先记住一句话：

> `Ctrl` 不负责计算 XOR、加法或阈值比较，它负责把卷积算法中的
> `{输出像素、输出通道组、卷积核位置、输入通道组}` 转换成逐拍地址和控制信号。

当前实现不是通用握手流水，而是固定延迟流水。只要修改 FeatureSRAM、WeightSRAM、
InBuf、WeightBuffer 或 Accumulator 的寄存级数，就必须重新调整 Ctrl 的控制相位。

## 1. 模块定位

`WorkSheet` 发出一条 32-bit 指令，`Ctrl` 将其展开成完整的一层卷积。Ctrl 同时控制：

1. 从 ActSRAM 或 OutSRAM 的哪个空间位置读取激活。
2. 从 64 个 WeightSRAM bank 的哪个公共地址读取权重。
3. 当前 popcount 应该装载到 accumulator，还是累加到旧值。
4. 当前结果使用哪个 BN/SIMD 参数 entry。
5. 结果写入哪块 Feature SRAM、哪个物理地址。
6. residual 模式何时切换到 shortcut，以及何时返回主路径。

`InBuf` 位于 FeatureSRAM 和计算阵列之间：

- normal 模式：一级激活寄存器，用于和 WeightBuffer 对齐。
- residual 模式：除一级寄存外，还保存 shortcut 数据，供后续输出组 replay。

```text
WorkSheet
    | iInstruction
    v
  Ctrl
    | Feature 地址/读使能       | WeightAddr/读使能
    v                           v
ActSRAM / OutSRAM           64 个 WeightSRAM bank
    |                           |
    v                           v
  InBuf                    64 个 WeightBuffer
    |                           |
    +------------+--------------+
                 v
        64 个并行 ComputeCore
        XOR -> popcount -> Accumulator
                 |
                 v
               SIMD
                 |
                 v
       ActSRAM 或 OutSRAM 写回
```

## 2. 算法变量与硬件变量对照

### 2.1 算法变量

| 算法名 | 中文含义 | 当前硬件含义 |
| --- | --- | --- |
| `H`、`Hin` | 输入特征图高度 | 当前网络中高度和宽度相等 |
| `W`、`Win` | 输入特征图宽度 | 与 `Hin` 相同 |
| `Hout` | 输出特征图高度 | normal 为 `Hin/stride1`；residual 主路径为 `Hin` |
| `Wout` | 输出特征图宽度 | 与 `Hout` 相同 |
| `Cin` | 输入通道数 | 支持 64、128、256 |
| `Cout` | 输出通道数 | 支持 64、128、256 |
| `IG` | 输入通道组数 | `IG=Cin/64`，取值 1、2、4 |
| `OG` | 输出通道组数 | `OG=Cout/64`，取值 1、2、4 |
| `p` | 输出空间点编号 | `p=out_row*Wout+out_col` |
| `og` | 物理输出通道组编号 | 每组包含 64 个输出通道 |
| `k` | 3x3 kernel 位置 | 0..8，顺序为左上到右下 |
| `ig` | 输入通道组编号 | 0..IG-1，每组 64 输入通道 |
| `lane` | 当前组内输出通道编号 | 0..63，对应一个 ComputeCore/WeightSRAM bank |

### 2.2 指令字段如何还原 H、W、Cin、Cout

`iInstruction` 的字段为：

```text
[31:30] calc_type
[29:28] kernel_size
[27:25] log_in_hw
[24:21] log_in_c
[20:17] log_out_c
[16:15] stride1
[14:13] stride2
[12:5]  weight_base
[4:0]   bn_base
```

对应关系：

```text
Hin  = Win  = 2^log_in_hw
Cin         = 2^log_in_c
Cout        = 2^log_out_c
IG          = Cin / 64 = 2^(log_in_c-6)
OG          = Cout/ 64 = 2^(log_out_c-6)
```

当前代码没有使用通用指数运算，而是只解码已验证值：

| 指令编码 | 实际值 |
| --- | ---: |
| `log_in_hw=3/4/5` | `Hin=8/16/32` |
| `log_in_c=6/7/8` | `IG=1/2/4` |
| `log_out_c=6/7/8` | `OG=1/2/4` |

输出尺寸：

```text
normal stride1: Hout = Hin
normal stride2: Hout = Hin/2
residual main : Hout = Hin
```

Residual 指令中的 `Hin/Cin` 描述较小的主路径 feature。另一块 SRAM 中的 shortcut
feature 尺寸为：

```text
shortcut_H   = 2*Hin
shortcut_W   = 2*Win
shortcut_Cin = Cin/2
shortcut_IG  = IG/2
```

## 3. Ctrl 所有英文变量解释

### 3.1 命名前缀和全部端口

命名前缀：

| 前缀 | 英文 | 中文含义 |
| --- | --- | --- |
| `i` | input | 输入到当前模块 |
| `o` | output | 当前模块输出 |
| `n` | negative/active-low | 低有效，例如 `nRst=0` 表示复位有效 |
| `P_` | parameter | 可配置参数 |
| `_d` | delay/next pipeline value | 尚未送到外部的延迟级控制或地址 |

Ctrl 端口：

| 变量 | 英文拆解 | 中文含义和使用时机 |
| --- | --- | --- |
| `clk` | clock | 模块时钟，状态和寄存输出在上升沿更新 |
| `nRst` | negative reset | 低有效复位，清状态并令初始方向为 Act 读、Out 写 |
| `nCe` | negative chip enable | 低有效运行允许；1 表示 WorkSheet 不要求计算 |
| `iInstruction` | input instruction | 当前 32-bit 计算指令 |
| `oActReadCenterAddr` | output Act read center address | ActSRAM 当前卷积中心的 group0 物理地址 |
| `oActReadEn` | output Act read enable | ActSRAM 读请求，高有效 |
| `oActKernelSize` | output Act kernel size | ActSRAM 当前按 3x3 还是 1x1 读取 |
| `oActHW` | output Act height/width | ActSRAM 中当前 feature 的实际 H/W |
| `oActlogInC` | output Act log input channels | ActSRAM 当前 feature 的 log2(C)，顶层据此求 depth |
| `oActWriteAddr` | output Act write address | SIMD 结果写入 ActSRAM 的物理 word 地址 |
| `oActWriteEn` | output Act write enable | ActSRAM 高有效写请求，已经过一拍控制寄存 |
| `oInputBufNWe` | output InputBuf negative write enable | InBuf 低有效写使能；0 表示本拍允许锁存 SRAM 数据 |
| `oInputBufSelect` | output InputBuf select | 0 选择 ActData，1 选择 OutData |
| `oOutReadCenterAddr` | output Out read center address | OutSRAM 当前卷积中心的 group0 物理地址 |
| `oOutReadEn` | output Out read enable | OutSRAM 读请求；运行中也用于推导 InBuf 选择 |
| `oOutKernelSize` | output Out kernel size | OutSRAM 当前按 3x3 还是 1x1 读取 |
| `oOutHW` | output Out height/width | OutSRAM 中当前 feature 的实际 H/W |
| `oOutlogInC` | output Out log input channels | OutSRAM 当前 feature 的 log2(C) |
| `oOutWriteAddr` | output Out write address | SIMD 结果写入 OutSRAM 的物理 word 地址 |
| `oOutWriteEn` | output Out write enable | OutSRAM 高有效写请求，已经过一拍控制寄存 |
| `oBNAddr` | output batch-normalization address | SIMD 参数 entry 地址，对应当前物理输出组 |
| `oWeightAddr` | output weight address | 64 个 WeightSRAM bank 共用的读地址 |
| `oWeightReadEn` | output weight read enable | 权重 SRAM 高有效读请求；顶层转换为低有效 nCe |
| `oAccInstr` | output accumulator instruction | 累加器操作码：CLEAR、LOAD、ADD |
| `oComputeDone` | output compute done | 当前指令完成脉冲，通知 WorkSheet 切换指令 |

### 3.2 参数、状态和指令字段

| 变量 | 英文展开/中文含义 | 设计作用 |
| --- | --- | --- |
| `P_BINDWIDTH` | bind width，单个 SRAM word 位宽 | 固定为 64，一个 word 保存 64 通道 bit |
| `P_FEATURE_MEMORY_SIZE` | Feature 存储总 bit 数 | 默认 65536 bit，即 1024x64 bit |
| `FEATURE_ADDR_WIDTH` | Feature 地址位宽 | 默认 `$clog2(1024)=10` |
| `CALC_NORMAL` | 普通卷积类型 | `calc_type=00` |
| `CALC_RESIDUAL` | 残差合并类型 | `calc_type=01` |
| `ACC_CLEAR` | accumulator 清零 | 累加器操作码 `00` |
| `ACC_LOAD` | accumulator 装载首项 | 操作码 `01`，覆盖旧累加值 |
| `ACC_ADD` | accumulator 累加 | 操作码 `10`，新 popcount 加到旧值 |
| `state_t` | state type，状态类型 | 定义 IDLE、CONV、CONV2 三种编码 |
| `state` | 当前控制状态 | `IDLE/CONV/CONV2` |
| `IDLE` | 空闲/准备状态 | 等待新指令，同时处理最后结果的尾写 |
| `CONV` | convolution main path，卷积主路径 | normal 全部计算或 residual 3x3 部分 |
| `CONV2` | residual shortcut path，附加卷积状态 | residual 的 stride2 1x1 shortcut 累加 |
| `pingpong` | 乒乓 SRAM 角色位 | 0 表示 Act 读、Out 写；1 表示 Out 读、Act 写 |
| `calc_type` | calculation type，计算类型 | 区分 normal 和 residual |
| `kernel_size` | 卷积核尺寸编码 | 数值 3 表示 3x3，其他值进入 1x1 路径 |
| `log_in_hw` | log2(input H/W) | 3/4/5 对应 8/16/32 |
| `log_in_c` | log2(input channels) | 6/7/8 对应 Cin=64/128/256 |
| `log_out_c` | log2(output channels) | 6/7/8 对应 Cout=64/128/256 |
| `stride1` | 主路径步长 | 当前用 bit1 判断 stride2，否则 stride1 |
| `stride2` | shortcut 步长字段 | 协议中保留；当前地址使用固定 residual 公式 |
| `weight_base` | 权重基地址 | 当前指令在每个 WeightSRAM bank 中的起始地址 |
| `bn_base` | BN 参数基地址 | 当前指令第一个输出组的 SIMD entry |

### 3.3 派生 shape 和计数变量

| 变量 | 中文含义 | 计算方式/作用 |
| --- | --- | --- |
| `input_hw` | 主路径输入 H/W 实际值 | 8、16、32 |
| `output_hw` | 输出 H/W 实际值 | normal 根据 stride，residual 等于 `input_hw` |
| `input_groups` | 输入 64-channel 组数 IG | `Cin/64` |
| `output_groups` | 输出 64-channel 组数 OG | `Cout/64` |
| `input_group_shift` | `log2(IG)` | IG=1/2/4 时为 0/1/2，用于把乘除法改成移位 |
| `output_group_shift` | `log2(OG)` | OG=1/2/4 时为 0/1/2 |
| `total_group_shift` | `log2(IG*OG)` | 范围 0..4，`cut_num >> total_group_shift` 得到像素编号 |
| `groups_per_pixel` | 每个输出像素的 chunk 数，5 bit | `1 << total_group_shift`，可表示最大值 16 |
| `pixels_per_group` | 输出空间点总数，11 bit | 通过 4/8/16/32 查表得到 16/64/256/1024 |
| `cycles_per_chunk` | 每个 chunk 周期数，4 bit | 3x3 为 9，1x1 为 1 |
| `weight_span` | 权重地址总跨度，8 bit | normal=`9*IG*OG`；residual=`OG*(9*IG+IG/2)`，最大 152 |
| `cycle` | 当前 chunk 内周期，4 bit | 3x3 时 0..8 |
| `cut_num` | 线性 chunk 编号，默认 15 bit | 地址、输出组和写回边界的核心索引 |
| `t` | 总进度辅助计数，11 bit | 0..`pixels_per_group-1`，只用于结束判断 |
| `round` | 总进度外层辅助计数，5 bit | 0..`groups_per_pixel-1`，只用于结束判断 |
| `res_flag` | residual shortcut 拍编号 | layer2 为 0；layer3 为 0、1 |
| `CONV2_done` | CONV2 已执行标志 | 防止同一主路径边界重复跳入 CONV2 |

特别注意：`t` 和 `round` 的名字很容易造成误解。当前规范的数据顺序由
`cut_num/cycle` 决定，不能把 `round` 简单当成 `og`，也不能把 `t` 简单当成 `p`。

### 3.4 地址和边界变量

| 变量 | 中文含义 | 作用 |
| --- | --- | --- |
| `address_cut_num` | 地址计算使用的 chunk 编号 | CONV2 使用 `cut_num-1`，保持当前输出位置 |
| `pixel_index` | 输出空间点编号 p | `address_cut_num/(IG*OG)` |
| `row_skip_count` | stride2 额外跨行次数 | 用于固定网络的地址修正 |
| `main_center_addr` | 主路径卷积中心地址 | 交给主 FeatureProcessor |
| `shortcut_center_addr` | shortcut 采样中心地址 | CONV2 交给另一块 FeatureProcessor |
| `completed_word_addr` | 已完成输出 word 地址 | `cut_num/IG`，等价于 `p*OG+og` |
| `chunk_first` | 是否为当前输出 word 第一个 chunk | 决定 ACC_LOAD 和稳态写回触发 |
| `chunk_last` | 是否为当前输出 word 最后一个 chunk | residual 在此之后进入 CONV2 |
| `final_chunk` | 是否为整条指令最后主路径 chunk | 决定 normal 完成或 residual 等待 CONV2 |
| `final_shortcut_cycle` | 是否为当前 shortcut 最后一拍 | 决定返回 CONV 或整条 residual 完成 |

### 3.5 延迟控制变量

| 变量 | 中文含义 | 为什么存在 |
| --- | --- | --- |
| `acc_instr_d` | 尚未输出的累加器控制 | 与 feature/weight 两级数据延迟对齐 |
| `act_write_en_d` | ActSRAM 预写使能 | 再寄存到 `oActWriteEn`，等待 SIMDData 稳定 |
| `out_write_en_d` | OutSRAM 预写使能 | 与 Act 写使能对称 |
| `act_write_addr_d` | ActSRAM 预写地址 | 和预写使能使用错拍更新，保持前一 word 地址 |
| `out_write_addr_d` | OutSRAM 预写地址 | 与 Act 写地址对称 |

### 3.6 Ctrl 函数名称

| 函数 | 中文含义 |
| --- | --- |
| `decode_hw` | 把 `log_in_hw` 解码成实际 H/W |
| `decode_groups` | 把 `log2(C)` 解码成 `C/64` |
| `decode_group_shift` | 把 `log2(C)` 解码成组数的移位量 0/1/2 |
| `square_hw` | 查表得到 `Hout*Wout`，避免综合平方乘法器 |
| `normalized_log_channels` | 对非法通道编码回落到 log2(64)=6 |
| `is_first_chunk` | 判断当前 chunk 是否为输出 word 的第一个 chunk |
| `is_last_chunk` | 判断当前 chunk 是否为输出 word 的最后一个 chunk |
| `word_addr_from_chunk` | 用位切片执行 `cut_num/IG`，得到输出 word 地址 |
| `pixel_from_chunk` | 用固定右移执行 `cut_num/(IG*OG)` |
| `row_skip_from_pixel` | 用固定右移执行 `pixel/(input_hw/2)` |
| `scale_by_groups` | 用固定左移执行 `pixel*IG` |

函数形参：`encoded_hw` 表示尚未解码的 H/W 编码；`log_channels` 表示通道数的
log2 编码；`chunk` 表示待判断的线性 chunk 编号；`groups` 表示 IG。

## 4. InBuf 所有英文变量解释

### 4.1 端口和参数

| 变量 | 中文含义 | 设计作用 |
| --- | --- | --- |
| `PERIOD` | 时钟周期参数 | 当前模块实际未使用，属于历史参数 |
| `P_BINDWIDTH` | 数据 word 位宽 | 默认 64 bit |
| `clk` | 时钟 | 上升沿锁存数据和计数 |
| `nRst` | 低有效复位 | 清 `rBuf` 和 `count` |
| `iSelect` | 输入选择 | 0 选 ActData，1 选 OutData |
| `nWe` | 低有效写使能 | 0 更新 `rBuf`，1 保持并清 residual 计数 |
| `iInstruction` | 当前指令 | InBuf 只使用 `calc_type` 和 `in_hw` |
| `iWriteDataA` | A 路输入数据 | 顶层连接 ActSRAM 输出 |
| `iWriteDataB` | B 路输入数据 | 顶层连接 OutSRAM 输出 |
| `nCe` | 低有效输出允许 | 顶层固定 0；为 1 时 `oInData=0` |
| `oInData` | 输出激活 word | 送入 64 个 ComputeCore |

### 4.2 内部变量

| 变量 | 中文含义 | 设计作用 |
| --- | --- | --- |
| `calc_type` | 计算类型 | `01` 时启动 residual 保存/replay |
| `kernel_size` | 卷积核尺寸 | 当前声明但未使用，属于历史遗留 |
| `in_hw` | `log2(H)` | 4 表示 layer2 residual，3 表示 layer3 residual |
| `rBuf` | 主输出寄存器 | normal 时保存当前 SRAM 数据；residual 时也可保存 replay 数据 |
| `data` | 当前 mux 选择后的 SRAM 数据 | `iSelect ? iWriteDataB : iWriteDataA` |
| `dataA/dataB` | 历史中间变量 | 当前声明但未使用 |
| `count` | residual 周期计数 | 记录一个像素全部输出组的 38 或 152 拍 |
| `count_top` | residual 周期上限 | layer2=38，layer3=152 |
| `fromram` | 主路径来源 SRAM 记录 | 用于判断当前是否切到了 shortcut SRAM |
| `temp1` | 保存的 shortcut group0 | layer2/3 都使用 |
| `temp2` | 保存的 shortcut group1 | 仅 layer3 使用 |
| `temp` | 当前要 replay 的保存值 | layer2 固定 temp1；layer3 在 temp1/temp2 间选择 |

`fromram/temp1/temp2` 当前通过不完整 `always_comb` 保存，综合上是 latch。功能已经通过
固定网络回归，但如果面向 ASIC 重构，应改成显式 `always_ff`。

## 5. H、W、Cin、Cout 对应的真实计算顺序

### 5.1 算法上最容易理解的循环

普通 3x3 卷积可以写成：

```text
for out_row = 0 .. Hout-1
  for out_col = 0 .. Wout-1
    p = out_row*Wout + out_col

    for og = 0 .. OG-1
      清空当前 64 个输出通道的 accumulator

      for k = 0 .. 8
        for ig = 0 .. IG-1
          读取 feature[p 周围的 k][ig]
          读取 weight[og][k][ig][lane]
          64 个 lane 并行执行 XOR-popcount 并累加

      使用 BN[og] 处理 64 个 accumulator
      写 output[p][og]
```

其中 `lane=0..63` 不占额外周期，因为 64 个 ComputeCore 是空间并行的。

### 5.2 Ctrl 为什么不是直接使用 p、og、k、ig 四个计数器

FeatureProcessor 内部已经维护：

```text
countDepthCycles = ig
countConvCycles  = k
```

它的自然读取顺序是：

```text
(k=0,ig=0), (k=0,ig=1), ...,
(k=1,ig=0), (k=1,ig=1), ...
```

Ctrl 不重复维护 k/ig，而是每 9 拍切成一个 `chunk`。真实换算公式是：

```text
p = cut_num / (IG*OG)
c = cut_num % (IG*OG)

chunk = c % IG
og    = c / IG

term = chunk*9 + cycle
k    = term / IG
ig   = term % IG
```

这些是算法语义公式，不表示 RTL 中仍存在通用除法器。由于 IG、OG 只能为 1、2、4，
当前实现先得到 `total_group_shift=log2(IG*OG)`，再执行：

```text
p = cut_num >> total_group_shift
```

综合结果是固定移位选择器，而不是由 `cut_num` 驱动的动态除法网络。

因此物理执行顺序仍等价于：

```text
p -> og -> k -> ig
```

但 RTL 表面看到的是：

```text
cut_num -> cycle
```

### 5.3 IG=1 示例：Cin=64

一个输出组只需要一个 chunk：

| `cycle` | `k` | `ig` |
| ---: | ---: | ---: |
| 0 | 0 | 0 |
| 1 | 1 | 0 |
| ... | ... | ... |
| 8 | 8 | 0 |

9 拍后完成一个 64-channel 输出 word。

### 5.4 IG=2 示例：Cin=128

一个输出组需要两个 chunk，共 18 拍。注意 chunk 边界不等于 kernel 边界：

| chunk | cycle | term | k | ig |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 | 0 |
| 0 | 1 | 1 | 0 | 1 |
| 0 | 2 | 2 | 1 | 0 |
| 0 | 3 | 3 | 1 | 1 |
| 0 | 4 | 4 | 2 | 0 |
| 0 | 5 | 5 | 2 | 1 |
| 0 | 6 | 6 | 3 | 0 |
| 0 | 7 | 7 | 3 | 1 |
| 0 | 8 | 8 | 4 | 0 |
| 1 | 0 | 9 | 4 | 1 |
| 1 | 1 | 10 | 5 | 0 |
| ... | ... | ... | ... | ... |
| 1 | 8 | 17 | 8 | 1 |

这就是为什么不能把 `chunk` 直接命名成 `input_group`。它只是 18 项线性序列的
前半段/后半段。

### 5.5 输出 Feature 地址

Feature SRAM 中一个 64-bit word 表示一个空间点的一组 64 通道：

```text
input_addr  = input_pixel*IG + ig
output_addr = output_pixel*OG + og
```

Ctrl 给 FeatureProcessor 的是当前空间点 group0 中心地址，`ig` 地址增量由
FeatureProcessor 内部 `countDepthCycles` 自动产生。

normal stride1：

```text
main_center_addr = p*IG
```

normal stride2 的通用公式应为：

```text
out_row = p/Wout
out_col = p%Wout
main_center_addr = (out_row*2*Win + out_col*2)*IG
```

当前 RTL 使用固定网络等价式：

```text
main_center_addr = p*2*IG + 32*out_row
```

它成立的前提是已验证网络中每个输入行恒为 32 个 64-bit word：

```text
Win*IG = 32
```

输出写地址由：

```text
completed_word_addr = cut_num/IG
```

在输出 word 边界处，`cut_num/IG` 等价于：

```text
p*OG + og
```

### 5.6 一个完整数值例子

假设：

```text
Hin=16, Win=16
Cin=128 -> IG=2
Cout=256 -> OG=4
stride1
当前输出空间点 p=3
当前物理输出组 og=2
当前 kernel 位置 k=5
当前输入组 ig=1
```

算法要求的地址为：

```text
Feature 中心 group0 地址 = p*IG = 3*2 = 6
FeatureProcessor 内部再根据 k=5、ig=1 产生具体读地址

输出写地址 = p*OG+og = 3*4+2 = 14

当前输出组内的权重项编号 = k*IG+ig = 5*2+1 = 11
当前输出组权重起点偏移   = og*(9*IG) = 2*18 = 36
WeightAddr = weight_base + 36 + 11 = weight_base + 47
```

换成 Ctrl 的 `cut_num/cycle` 表示：

```text
term  = k*IG+ig = 11
chunk = term/9  = 1
cycle = term%9  = 2

c       = og*IG+chunk = 2*2+1 = 5
cut_num = p*(IG*OG)+c = 3*8+5 = 29
```

代回 Ctrl 公式：

```text
p  = cut_num/(IG*OG) = 29/8 = 3
c  = cut_num%(IG*OG) = 29%8 = 5
og = c/IG             = 5/2 = 2
chunk = c%IG          = 5%2 = 1
term  = chunk*9+cycle = 1*9+2 = 11
k     = term/IG       = 11/2 = 5
ig    = term%IG       = 11%2 = 1
```

这说明 RTL 的扁平计数与算法坐标严格可逆。

## 6. 权重如何映射到 64 个 bank 和地址

### 6.1 为什么有 64 个 WeightSRAM bank

`ComputeCoreGroup` 内有 64 个 ComputeCore：

```text
ComputeCore lane0  <-> WeightSRAM bank0
ComputeCore lane1  <-> WeightSRAM bank1
...
ComputeCore lane63 <-> WeightSRAM bank63
```

每个 lane 负责当前物理输出组中的一个输出通道。因此：

- `lane` 维度由 64 个 bank 空间并行展开，不需要 Ctrl 计数。
- 64 个 bank 使用同一个 `oWeightAddr`。
- 同一地址下，64 个 bank 同时输出 64 个不同输出通道的权重 word。
- 每个权重 word 为 64 bit，对应一个输入通道组中的 64 个输入通道。

一次计算拍实际完成：

```text
64 个输出 lane
  x 每个 lane 的 64-bit 激活/权重 XOR
  -> 64 个独立 popcount
```

### 6.2 Normal 权重地址公式

对一个物理输出组 `og`：

```text
weight_addr = weight_base
            + og*(9*IG)
            + k*IG
            + ig
```

解释：

1. `og*(9*IG)` 跳到当前输出通道组的权重区域。
2. `k*IG` 跳到当前 kernel 位置。
3. `ig` 选择当前 64-channel 输入组。

由于 Ctrl 的真实顺序满足 `og -> k -> ig`，所以 `oWeightAddr` 可以每拍简单加 1，
不需要每拍重新做乘法。到达：

```text
weight_base + 9*IG*OG - 1
```

后回卷到 `weight_base`，供下一个输出像素复用同一组卷积核。

### 6.3 Normal 地址例子

例 1：`Cin=64, Cout=128, IG=1, OG=2, weight_base=36`

```text
输出组 og0: 地址 36..44，共 9 个 word/bank
输出组 og1: 地址 45..53，共 9 个 word/bank
```

例 2：`Cin=128, Cout=256, IG=2, OG=4, weight_base=0`

```text
每个输出组占 9*2=18 个地址：
og0:  0..17
og1: 18..35
og2: 36..53
og3: 54..71
```

地址 0 的含义是所有 64 个 bank 同时读取：

```text
bank0 : og0 中 lane0、k0、ig0 的 64-bit 权重
bank1 : og0 中 lane1、k0、ig0 的 64-bit 权重
...
bank63: og0 中 lane63、k0、ig0 的 64-bit 权重
```

地址 1 切换到 `k0,ig1`，仍然是相同 64 个输出 lane 并行。

### 6.4 Residual combined 权重地址

Residual 每个输出组包含：

```text
main_words     = 9*IG
shortcut_words = IG/2
words_per_og   = 9*IG + IG/2
```

主路径权重：

```text
weight_addr = weight_base
            + og*(9*IG + IG/2)
            + k*IG + ig
```

shortcut 权重：

```text
weight_addr = weight_base
            + og*(9*IG + IG/2)
            + 9*IG
            + shortcut_group
```

Ctrl 在 CONV 中读完 `9*IG` 个地址后，不停止 WeightAddr，直接进入 CONV2 再读
`IG/2` 个地址，因此自然符合 combined 文件布局。

Layer2 residual：`IG=2, OG=2, weight_base=54`

```text
每个输出组 18+1=19 个地址：
og0 main    : 54..71
og0 shortcut: 72
og1 main    : 73..90
og1 shortcut: 91
```

Layer3 residual：`IG=4, OG=4, weight_base=0`

```text
每个输出组 36+2=38 个地址：
og0:   0..37
og1:  38..75
og2:  76..113
og3: 114..151
```

### 6.5 物理输出组与 canonical 通道顺序

Ctrl、WeightSRAM、BNAddr 和 Feature 写地址使用的是物理输出组顺序。当前参数装载与
TB adapter 约定：

```text
物理组 p <-> canonical 组 (OG-1-p)
```

因此不要只在 Ctrl 中交换 `og` 顺序。若修改物理组定义，必须同时修改权重装载、
BN 参数装载、Feature dump/group reverse。

### 6.6 权重参数如何写入 bank 和地址

运行时 Ctrl 只给出公共读地址；计算前的软件/TB 还要把参数装入正确 bank。

写入路径为：

```text
AHB 32-bit 数据
 -> ram_mux 将相邻两个 32-bit 数据拼成一个 64-bit word
 -> conv_ram_sel 选择 WeightSRAM bank/lane
 -> conv_ram_waddr 选择该 bank 内地址
 -> conv_ram_wdata 写入 64-bit 权重
```

`ComputeCoreGroup` 的写选择逻辑为：

```text
只有 weightWriteSelect == lane 的 ComputeCore/WeightSRAM bank 打开 nWeightWe
```

参数文件逻辑组织为：

```text
for og = 0 .. OG-1
  for lane = 0 .. 63
    for k = 0 .. 8
      for ig = 0 .. IG-1
        写 bank=lane
        写 addr=weight_base + og*(9*IG) + k*IG + ig
```

每个 64-bit 权重 word 在文本中通常占相邻两行 32-bit 数据，因此 normal 权重文件
的 32-bit 行数为：

```text
OG * 64 lanes * 9 kernels * IG * 2 lines
```

例如 `Cin=128、Cout=256`：

```text
4 * 64 * 9 * 2 * 2 = 9216 行 32-bit 文本
```

Residual combined 文件则将每个 `og/lane` 的 shortcut 数据紧跟在 main 数据之后：

```text
for og
  for lane
    写 9*IG 个 main 64-bit words
    写 IG/2 个 shortcut 64-bit words
```

只有装载顺序和 Ctrl 的 CONV/CONV2 读地址顺序完全一致，连续递增 WeightAddr 才能
正确工作。

## 7. 具体延迟和响应控制

### 7.1 两条输入路径为什么都需要两级存储延迟

激活路径：

```text
Ctrl 地址
 -> FeatureSRAM 同步读寄存器
 -> InBuf.rBuf
 -> XOR/popcount
```

权重路径：

```text
Ctrl oWeightAddr
 -> WeightSRAM.oDataa 同步读寄存器
 -> WeightBuffer.weightBufData
 -> XOR/popcount
```

两条路径都是“SRAM 读一拍 + Buffer 一拍”。这样同一个计算项的激活和权重在
Multiplier 输入端同时出现。

### 7.2 为什么 acc_instr_d 和 oAccInstr 还要延迟

Ctrl 在发出某项地址时产生 `acc_instr_d`。时序链为：

```text
地址请求拍 E0：acc_instr_d 决定当前项是 LOAD 还是 ADD
E1：oAccInstr 寄存 acc_instr_d；InBuf/WeightBuffer 锁存当前项数据
E2：Accumulator 在时钟沿使用 oAccInstr 和当前 popcount
```

因此从 Ctrl 决策到 Accumulator 真正执行相隔两个时钟沿，刚好匹配数据的两级延迟。

如果直接把 `acc_instr_d` 接到 Accumulator：控制只延迟一拍，Accumulator 会用
当前项控制处理前一项数据。

### 7.3 Normal 首个输出 word 的逐拍响应

下面以 `IG=1` 为例。`T0` 表示 kernel0，`T8` 表示 kernel8。

| 时钟沿 | Ctrl/地址 | SRAM/Buffer | Acc 控制与数据 | 写回 |
| --- | --- | --- | --- | --- |
| E0 | 发出 T0 地址；`acc_instr_d=LOAD` | SRAM 开始读 T0 | `oAccInstr` 仍为 CLEAR | 无 |
| E1 | 发出 T1 地址 | InBuf/WeightBuffer 锁存 T0 | `oAccInstr` 变为 LOAD，Accumulator 本沿仍看到旧 CLEAR | 无 |
| E2 | 发出 T2 地址 | Buffer 锁存 T1 | Accumulator 用 LOAD 接收 T0 | 无 |
| E3 | 发出 T3 地址 | Buffer 锁存 T2 | Accumulator 用 ADD 接收 T1 | 无 |
| ... | ... | ... | ... | ... |
| E8 | 发出 T8 地址 | Buffer 锁存 T7 | Accumulator 累加 T6 | 无 |
| E9 | 下一输出 word 开始；产生 `write_en_d` | Buffer 锁存 T8 | Accumulator 累加 T7 | 预写使能产生 |
| E10 | 新 word 继续 | Buffer 锁存新项 | Accumulator 累加 T8，SIMDData 随后稳定 | `oWriteEn` 变高 |
| E11 | 新 word 继续 | 正常流水 | 下一 word 正常累加 | FeatureSRAM 在本沿真正写入前一 word |

这里必须区分：

- `oWriteEn` 在 E10 边沿后变高。
- FeatureProcessor 的写逻辑在下一个上升沿 E11 才真正采样该高电平。
- 所以前一 word 的最后 accumulator 更新发生在 E10，物理写入发生在 E11。

### 7.4 写地址为什么看起来比写使能晚更新

FSM 先产生 `act_write_en_d/out_write_en_d`。下一拍通过旧值检测：

```systemverilog
if (act_write_en_d || out_write_en_d)
  更新下一次使用的 write_addr_d;
```

利用非阻塞赋值的旧值语义：

1. 当前 `oWriteEn` 和 `oWriteAddr` 仍对应前一个输出 word。
2. `write_addr_d` 在后台准备下一输出 word 的地址。
3. FeatureSRAM 真正写入时看到的是配套的旧地址和旧 BNAddr。

若把地址和预写使能在同一条件下直接更新，写使能会配到下一 word 地址，造成所有
结果整体前移一个 64-channel word。

### 7.5 BNAddr 如何与物理写回对齐

`oBNAddr` 在第一个输出 word 开始时装载 `bn_base`。之后只有检测到注册后的：

```text
oActWriteEn || oOutWriteEn
```

才推进到下一个输出组。FeatureSRAM 在该写使能有效的时钟沿使用旧 SIMDData；同一
时钟沿后 BNAddr 才更新，所以当前写回仍使用当前组参数，下一组使用新参数。

如果 BNAddr 在 `write_en_d` 产生时就推进，会比物理写回早一拍。

### 7.6 最后一个输出 word 为什么需要尾写

稳态写回依赖“下一输出 word 开始”触发前一 word 的写回。整层最后一个 word 没有
下一 word，因此 normal 最后一项或 residual 最后 shortcut 完成时：

1. Ctrl 产生 `oComputeDone=1`。
2. Ctrl 翻转 `pingpong`。
3. 下一拍进入 IDLE，依据已经翻转的 pingpong 反向补发 `write_en_d`。
4. 再经过写控制寄存和 SRAM 采样，最后 word 被写入旧指令的目标 SRAM。

停机条件必须是：

```systemverilog
nCe && !oComputeDone
```

因为 WorkSheet 在最后指令完成后会拉高 `nCe`。若 `nCe` 无条件优先，尾写会被清掉。

### 7.7 oInputBufSelect 的响应时序

```text
复位或 nCe=1：选择 ActSRAM
IDLE 或 InBuf 禁写：预先选择 pingpong 主源
运行中：跟随 oOutReadEn，CONV/CONV2 自动切换数据源
```

预选发生在第一次 `nWe=0` 之前。如果 residual 紧跟一个写入 OutSRAM 的指令，新的
主源就是 OutSRAM。若 IDLE 固定选 ActSRAM，第一项会采到旧 ActData。

## 8. Ctrl 与 InBuf 在 residual 中如何配合

### 8.1 Ctrl 负责“何时切换”

每个物理输出组主路径完成时：

```text
cycle==8 && chunk_last
```

Ctrl 从 CONV 进入 CONV2：

- read enable 切到另一块 SRAM。
- `oInputBufSelect` 跟随切换。
- WeightAddr 继续读取 shortcut 权重。
- AccInstr 保持 ADD。

### 8.2 InBuf 负责“旧数据如何复用”

第一输出组可以直接从另一块 SRAM 读取 shortcut，但写回当前输出后，旧 shortcut
地址可能被覆盖。InBuf 因此在第一次 shortcut 窗口捕获数据：

Layer2 residual：

```text
count  0..17：og0 main
count     18：og0 shortcut，保存 temp1
count 19..36：og1 main
count     37：og1 shortcut，replay temp1
```

Layer3 residual：

```text
count  0..35：og0 main
count     36：og0 shortcut group0，保存 temp1
count     37：og0 shortcut group1，保存 temp2
count 38..73：og1 main
count 74/75：replay temp1/temp2
后续 og2/og3 同样 replay
```

`fromram` 记录主路径来源。当 `fromram != iSelect` 时，说明 Ctrl 已切换到 shortcut
SRAM。第一组保存真实 SRAM 数据，后续组根据 `count` 输出 `temp1/temp2`。

### 8.3 CONV2 地址为什么使用 cut_num-1

CONV 最后一个主路径时钟沿已经把 `cut_num` 加 1，下一拍才进入 CONV2。如果直接用
新 `cut_num` 计算 `pixel_index`，shortcut 地址会提前到下一 chunk/像素。

因此：

```text
state==CONV2 时 address_cut_num = cut_num-1
```

它显式保持刚完成主路径的空间位置，替代旧 Ctrl 依赖组合 latch 保持地址的写法。

## 9. 状态机与完成条件

```text
IDLE --有效指令--> CONV

CONV --normal 最后一项-->
IDLE + ComputeDone + pingpong 翻转

CONV --residual 当前 og 主路径结束-->
CONV2

CONV2 --当前 og shortcut 结束但整层未结束-->
CONV

CONV2 --最后 og shortcut 结束-->
IDLE + ComputeDone + pingpong 翻转
```

完成条件中的：

```text
round == groups_per_pixel-1
t     == pixels_per_group-1
```

本质上只是在判断总 chunk 数已经达到：

```text
Hout*Wout*IG*OG
```

layer3 residual 为：

```text
Hout*Wout = 8*8 = 64
IG*OG     = 4*4 = 16
总 chunk  = 1024
```

`groups_per_pixel` 必须至少 5 bit。当前正好使用 5 bit；若使用 4 bit，16 会截断为 0，
`final_chunk` 永远不能成立，仿真会停在第三次 `run_apu()`。

### 9.1 `cut_num` 到 SRAM 地址的等价时序优化

优化前的地址生成虽然公式正确，但实现使用了 64 bit 中间量和动态除法：

```text
cut_num[63:0]
-> CONV2 减一/选择
-> / (IG*OG)
-> / (input_hw/2)
-> * IG、*2、*32 和加法
-> 取低 10 bit 送 FeatureProcessor
```

Vivado 报告的关键路径正是从 `cut_num_reg` 到
`featureMemory_data_out_reg`。Ctrl 的超宽组合算术还会与 FeatureProcessor 内部的
地址计算串联，形成很长的单周期路径。

当前实现保持所有数学结果和周期相位不变，只改变硬件表达形式：

```text
cut_num[14:0]
-> CONV2 减一/选择
-> 按 total_group_shift 固定右移 0..4 bit
-> 按 log_in_hw 固定右移 2/3/4 bit
-> 按 IG 固定左移 0/1/2 bit
-> 移位加法
-> 取低 10 bit 送 FeatureProcessor
```

关键等价关系：

```text
IG*OG = 1/2/4/8/16  -> 除法等价于右移 0/1/2/3/4 bit
input_hw/2 = 4/8/16 -> 除法等价于右移 2/3/4 bit
pixel*IG            -> 左移 0/1/2 bit
9*groups            -> (groups<<3)+groups
32*row              -> row<<5
```

没有增加地址寄存器，也没有增加 `PREFILL` 或 `DRAIN` 周期，因此以下行为没有变化：

- `oActReadCenterAddr/oOutReadCenterAddr` 每拍地址序列；
- CONV 与 CONV2 的切换位置；
- WeightAddr 和 BNAddr 推进顺序；
- `acc_instr_d -> oAccInstr` 延迟；
- 写回使能和最后一个 word 的尾写时机；
- `oComputeDone` 的产生周期。

默认参数下 `CUT_NUM_WIDTH=15`。这是因为理论最大展开量为
`32*32*4*4=16384`，还要允许最后主路径时钟沿临时执行一次 `cut_num+1`。
若删掉这一个额外表示位，最大配置在结束边界会回卷，residual 的 `cut_num-1` 地址也会错误。

本次修改后的 Verilator 全网络回归和 `make check` 六项输出比较均为 0 mismatch。

## 10. 常见错误与自检清单

1. 是否把 `chunk` 错当成 `ig`？IG=2 时 chunk0 已跨到 k4。
2. 是否保持算法等价顺序 `p -> og -> k -> ig`？
3. Feature 中心地址是否只给 group0，ig 是否由 FeatureProcessor 内部推进？
4. 64 个 WeightSRAM bank 是否对应 64 个输出 lane，而不是 64 个输入通道？
5. normal 权重地址是否满足 `base+og*9IG+k*IG+ig`？
6. residual 是否在每个 og 后插入 IG/2 个 shortcut 地址？
7. WeightAddr 是否在 CONV2 连续加 1，没有停顿或回到 base？
8. `acc_instr_d -> oAccInstr -> Accumulator` 是否保持两沿响应关系？
9. 最后计算项是否先更新 accumulator，再在下一时钟沿写 FeatureSRAM？
10. BNAddr 是否在物理写回之后推进，而不是在预写脉冲时推进？
11. 最后一个输出 word 是否通过 IDLE 尾写补发？
12. `nCe` 是否不会抢占 `oComputeDone` 后的尾写？
13. residual 第一组 shortcut 是否保存，后续输出组是否 replay？
14. `oInputBufSelect` 是否在新指令首项前预选为 pingpong 主源？
15. 修改延迟后是否重新画逐拍表，而不是只移动一个控制信号试错？

## 11. 最小实践任务

先手写一个只支持 `H=W=4、Cin=Cout=64、3x3 stride1` 的 `CtrlMini`：

1. 使用 `pixel=0..15`、`kernel=0..8` 两个计数器。
2. 每个 pixel 的 kernel0 产生 LOAD，kernel1..8 产生 ADD。
3. 地址请求后增加一拍 SRAM 和一拍 Buffer 延迟。
4. 单独延迟 AccInstr，使 kernel0 数据与 LOAD 在同一 Accumulator 时钟沿到达。
5. 最后 kernel 后进入 DRAIN，等待 accumulator 和 SIMD 稳定。
6. 每个 pixel 写一个 64-bit word，地址等于 pixel。
7. 最后 pixel 写回后产生 ComputeDone。

完成后按以下顺序扩展：

```text
IG=2/4
-> OG=2/4 和 WeightSRAM 地址分区
-> pingpong
-> stride2 地址
-> residual CONV2
-> InBuf shortcut capture/replay
```

每增加一项，都应检查 accumulator 整数，而不只检查最终 SIMD bit；阈值比较可能
掩盖少量累加错误。
