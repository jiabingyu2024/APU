# APU ASIC 芯片架构设计文档

## 1. 设计目标

本 APU 是一个面向 CIFAR-10 二值 ResNet 中间卷积层的专用神经网络加速器。软件侧负责网络的前处理和后处理，硬件侧负责执行中间的二值卷积、累加、BatchNorm 等效比较、HardTanh/二值化以及残差合并相关计算。

该设计的核心目标是：

- 使用 0/1 表示二值激活和二值权重，避免浮点运算。
- 以 64 个输入通道为最小数据粒度，一次读取 64 bit 特征或权重。
- 使用 64 个并行 ComputeCore，同时产生 64 个输出通道的卷积结果。
- 将卷积后的 BatchNorm、HardTanh 和二值化融合到 SIMD 模块中。
- 使用 ActSRAM 和 OutSRAM 两块 64 Kb 特征 SRAM 构成乒乓缓冲。
- 使用 AHB Slave 作为外部配置和数据搬运接口，支持 PS/CPU 写入输入、权重、BN 参数和指令，再启动 APU。

在 PYNQ 上板场景中，PS 端通过 AXI-to-AHB 桥访问 APU；在 ASIC SoC 场景中，该 AHB Slave 可以挂接到片上总线或由微控制器子系统控制。

## 2. 顶层结构

顶层模块为 `Top`，参考文件是 `Top_student.sv`。从 RTL 可见的模块层级如下：

```text
Top
|-- ahb_slave_top
|-- WorkSheet
|-- Ctrl
|-- InBuf
|-- FeatureProcessor as ActSRAM
|-- FeatureProcessor as OutSRAM
|-- ComputeCoreGroup
|-- SIMD
```

整体数据流可以概括为：

```text
配置阶段:
AHB -> WorkSheet / ActSRAM / WeightSRAM / SIMD 参数 RAM

运行阶段:
ActSRAM / OutSRAM -> InBuf -> ComputeCoreGroup -> SIMD -> ActSRAM / OutSRAM
```

架构图中的关键模块和容量如下：

| 模块 | 容量或位宽 | 功能 |
| --- | ---: | --- |
| AHB Slave | 32-bit AHB 数据通路 | 外部配置、数据读写、启动和完成状态 |
| WorkSheet | 16 条 32-bit 指令 | 指令 RAM 和顺序发射器 |
| ActSRAM | 64 Kb，64-bit 读写宽度 | 输入或中间特征图缓存 |
| OutSRAM | 64 Kb，64-bit 读写宽度 | 输出或中间特征图缓存 |
| InBuf | 64-bit | 计算输入缓冲，选择 Act/Out 数据源 |
| WeightSRAM | 64 片 x 256 x 64 bit | 每个输出通道一片权重 SRAM |
| ComputeCoreGroup | 64 个 ComputeCore | 并行计算 64 个输出通道 |
| Accumulator 输出 | 64 x 12 bit | 卷积累加结果 |
| SIMD 参数 RAM | 64 通道 x 32 项 x 13 bit | BN/激活比较阈值 |
| SIMD 输出 | 64 bit | 64 个输出通道的二值化结果 |

顶层参数也印证了这些设计点：

```systemverilog
P_BINDWIDTH = 64
P_FEATURE_MEMORY_SIZE = 65536
P_GROUP = 64
P_WORDS_WE = 256
P_BITWIDTH_WE = 64
P_OUTBITWIDTH_ACC = 12
P_CHANNELS = 64
P_COMPAREWIDTH = 13
P_TOTAL64BN = 32
```

## 3. AHB 外部接口

APU 对外表现为 AHB Slave。外部处理器通过 AHB 访问内部 RAM 窗口和控制寄存器。AHB 数据宽度为 32 bit，而内部特征/权重计算粒度为 64 bit，因此部分数据需要两个 32-bit AHB word 组成一个 64-bit 内部计算 word。

### 3.1 地址空间

| 地址 | 名称 | 权限 | 说明 |
| --- | --- | --- | --- |
| `0x0000` - `0x1FFF` | RAM 数据窗口 | RW | 访问 `RAM_SEL_ADDR` 当前选中的内部 RAM |
| `0x2000` | `RAM_CTRL_ADDR` | RW | RAM 控制权寄存器 |
| `0x2004` | `RAM_SEL_ADDR` | RW | RAM 片选寄存器 |
| `0x2008` | `APU_READY_ADDR` | WO | 写 1 后通知 APU 开始执行 |
| `0x200C` | `CPL_ADDR` | RO | APU 完成标志，读完成状态 |

`RAM_CTRL_ADDR` 的有效位如下：

| 位 | 含义 |
| --- | --- |
| bit 0 | 数据 RAM 控制权：`1` 表示 AHB/PS 控制 ActSRAM 和 OutSRAM，`0` 表示 APU 控制 |
| bit 1 | 权重/参数 RAM 控制权：`1` 表示 AHB/PS 控制 WeightSRAM 和 SIMD 参数 RAM，`0` 表示 APU 控制 |

`RAM_SEL_ADDR` 的片选定义如下：

| 片选号 | 选中对象 |
| ---: | --- |
| `0` - `63` | SIMD/BN 参数 RAM，对应 64 个输出通道 slice |
| `64` - `127` | WeightSRAM，对应 64 个输出通道 slice |
| `128` | ActSRAM / 输入特征 RAM |
| `129` | OutSRAM / 输出特征 RAM |
| `130` | WorkSheet 指令 RAM |

### 3.2 主机侧启动流程

典型软件控制流程如下：

1. 写 `RAM_CTRL_ADDR = 0x3`，把数据 RAM 和权重/参数 RAM 的控制权交给 AHB。
2. 写 `RAM_SEL_ADDR = 128`，将输入特征写入 ActSRAM。
3. 对每条需要执行的卷积指令：
   - 选择 `64` - `127`，向 WeightSRAM 的 64 个 slice 写权重。
   - 选择 `0` - `63`，向 SIMD/BN 参数 RAM 的 64 个 slice 写比较阈值。
   - 选择 `130`，向 WorkSheet 写入 32-bit 指令。
4. 写 `RAM_CTRL_ADDR = 0x0`，把 RAM 控制权交还给 APU。
5. 写 `APU_READY_ADDR = 1`，启动 WorkSheet。
6. 轮询 `CPL_ADDR` 或等待 `int_cal` 中断/完成信号。
7. 写 `RAM_CTRL_ADDR = 0x3`，重新取得 RAM 控制权，读回输出 SRAM。

`PS_CIFAR10下发学生/apu_driver.py` 中的 `execute_apu_network()` 实现了上述流程。

## 4. 指令格式

WorkSheet 中每条指令为 32 bit。Python 驱动中的打包逻辑为：

```python
i = 0
i |= (op  & 0x3)  << 30
i |= (ks  & 0x3)  << 28
i |= (lihw & 0x7) << 25
i |= (lic & 0xF)  << 21
i |= (loc & 0xF)  << 17
i |= (s1  & 0x3)  << 15
i |= (s2  & 0x3)  << 13
i |= (wa  & 0xFF) << 5
i |= (bna & 0x1F)
```

| 位域 | 字段 | 说明 |
| --- | --- | --- |
| `[31:30]` | `opcode` | 计算类型。`00` 为普通卷积，`01` 为残差/resident 卷积 |
| `[29:28]` | `kernelSize` | 卷积核尺寸，本设计中直接写入 `1` 或 `3` |
| `[27:25]` | `logInHW` | 输入特征图 H/W 的 log2，如 32 对应 5，16 对应 4，8 对应 3 |
| `[24:21]` | `logInC` | 输入通道数 log2，如 64 对应 6，128 对应 7，256 对应 8 |
| `[20:17]` | `logOutC` | 输出通道数 log2 |
| `[16:15]` | `stride1` | 主干卷积步长 |
| `[14:13]` | `stride2` | 残差分支卷积步长，仅 `opcode=01` 时有效 |
| `[12:5]` | `wAddr` | WeightSRAM 内的权重基地址 |
| `[4:0]` | `bnAddr` | SIMD/BN 参数 RAM 内的参数基地址 |

Ctrl 模块根据这 32 bit 指令推导循环边界、读写地址、权重地址、BN 地址、乒乓方向以及累加器控制信号。

## 5. 数据表示与存储布局

### 5.1 二值表示

软件侧使用 `+1/-1` 表示二值激活，硬件侧使用 `0/1`。映射关系为：

| 软件值 | 硬件 bit |
| ---: | ---: |
| `+1` | `0` |
| `-1` | `1` |

软件中的转换代码为：

```python
x_binary_01 = x.sign().add(-1).div(-2)
```

因此 APU 内部不需要浮点乘法。二值卷积可以理解为二值匹配/XNOR 风格乘法，再经过加法树和累加器得到整数卷积结果。

### 5.2 特征图布局

PyTorch 张量格式是 NCHW，即 `(B, C, H, W)`。APU 存储时按 NHWC 风格展平，且推理时 `B = 1`。

以 64 通道特征图为例：

- 文本文件第 1、2 行共 64 bit，对应 `(h=0, w=0)` 的 64 个通道。
- 第 3、4 行共 64 bit，对应 `(h=0, w=1)` 的 64 个通道。
- 内部 FeatureProcessor 每次读写 64 bit，刚好对应一个空间点的一组 64 通道。

当通道数大于 64 时，APU 按 64 通道分组处理：

- 128 通道拆成 2 组。
- 256 通道拆成 4 组。

### 5.3 权重布局

权重逻辑格式为：

```text
(C_out, K_h, K_w, C_in)
```

WeightSRAM 有 64 个 slice。每个 slice 对应当前 64 输出通道组中的一个输出通道。一个 64-bit 权重 word 对应某个输出通道、某个 kernel 位置、某个 64 输入通道组的权重。

普通卷积中，每个 WeightSRAM slice 需要写入的 AHB 32-bit word 数为：

```text
words_per_slice = 2 * kernelSize * kernelSize * (C_in / 64)
```

其中系数 2 来自 AHB 32-bit 写入与内部 64-bit 权重 word 的宽度差异。

残差/resident 合并卷积中，驱动使用：

```text
words_per_slice = (2 * kernelSize * kernelSize + 1) * (C_in / 64)
```

额外的 `+1` 用于支持 combined 参数文件中残差分支相关的权重/合并数据组织。

### 5.4 BN/SIMD 参数布局

SIMD 参数 RAM 也按 64 个通道 slice 分布。每个输出通道对应一个 13-bit 比较阈值或 BN 等效参数。

主机写入时的地址规则为：

```text
RAM_SEL = channel_index          // 0 - 63
address = bnAddr * 4 + group * 4
data    = 当前通道、当前 64 输出通道组的 BN/SIMD 参数
```

运行时 Ctrl 输出 `BNAddr`，SIMD 读出对应的 13-bit 参数，对 64 个累加结果并行比较，输出 64-bit 二值特征。

## 6. 核心模块设计

### 6.1 AHB Slave

AHB Slave 是 APU 的外部控制前端，负责：

- 解码 AHB 读写请求。
- 维护 `RAM_CTRL_ADDR` 和 `RAM_SEL_ADDR`。
- 生成 ActSRAM、OutSRAM、WeightSRAM、SIMD 参数 RAM、WorkSheet 的 AHB 读写端口信号。
- 产生 `data_ram_ctrl` 和 `conv_ram_ctrl`，决定 RAM 由 AHB 还是 APU 控制。
- 接收 `APU_READY_ADDR` 启动信号。
- 将 `WorkSheetDone` 转换为完成状态或 `int_cal`。

当 APU 运行时，AHB Slave 不参与计算，只保留状态寄存器和完成通知。

### 6.2 WorkSheet

WorkSheet 是小型指令 RAM 和指令发射器。它接收 AHB 写入的最多 16 条指令，并在 `apu_ready` 后依次发给 Ctrl。

关键接口如下：

| 信号 | 方向 | 功能 |
| --- | --- | --- |
| `iAPUReady` | input | APU 启动信号 |
| `iComputeDone` | input | 当前指令完成，切换下一条 |
| `oCtrlnCe` | output | Ctrl 低有效使能 |
| `oInstruction` | output | 当前 32-bit 指令 |
| `oWorkSheetDone` | output | 全部指令执行完成 |

顶层中有：

```systemverilog
assign cal_cpl = WorkSheetDone;
```

因此 APU 的完成状态以 WorkSheet 指令序列完成为准，而不是某个单独卷积点完成。

### 6.3 Ctrl

Ctrl 是整个 APU 的调度核心。它解码指令并产生所有运行期控制信号：

- ActSRAM/OutSRAM 读中心地址。
- ActSRAM/OutSRAM 读使能、写地址、写使能。
- InBuf 写使能和输入选择。
- WeightSRAM 读地址和读使能。
- SIMD 参数地址。
- Accumulator 控制指令。
- 反馈给 WorkSheet 的 `oComputeDone`。

累加器控制编码为：

| `oAccInstr` | 含义 |
| --- | --- |
| `00` | 清零 |
| `01` | 装载第一次部分和 |
| `10` | 继续累加 |
| `11` | 保持 |

推荐的 Ctrl 主体是三层循环：

```text
round: 输出通道组循环
  t: 输出空间位置循环
    cycle: kernel 位置 x 输入通道组循环
```

指令字段推导出的主要变量为：

```text
input_hw     = 1 << logInHW
input_c      = 1 << logInC
output_c     = 1 << logOutC
output_hw    = input_hw / stride1
in_groups    = input_c / 64
out_groups   = output_c / 64
kernel_ops   = kernelSize * kernelSize
cyclePerTime = kernel_ops * in_groups
timePerRound = output_hw * output_hw
totalRound   = out_groups
```

对于 `opcode=01`，Ctrl 还需要协调残差分支读取、主干分支卷积、合并以及写回，避免残差输入被提前覆盖。

### 6.4 ActSRAM / OutSRAM

ActSRAM 和 OutSRAM 都是 `FeatureProcessor` 实例。每个实例具备：

- 64 Kb 容量。
- 64-bit 数据宽度。
- AHB 配置模式。
- APU 运行模式。
- 卷积窗口读取能力。
- padding 场景下的 zero mask 能力。

顶层通过 `data_ram_ctrl` 切换控制权：

```systemverilog
Act write addr = data_ram_ctrl ? in_ram_waddr  : ActWriteAddr
Act write data = data_ram_ctrl ? in_ram_wdata  : SIMDData
Act read addr  = data_ram_ctrl ? in_ram_raddr  : ActReadCenterAddr

Out write addr = data_ram_ctrl ? out_ram_waddr : OutWriteAddr
Out write data = data_ram_ctrl ? out_ram_wdata : SIMDData
Out read addr  = data_ram_ctrl ? out_ram_raddr : OutReadCenterAddr
```

运行时两块 SRAM 构成乒乓结构：

- 当前层从 ActSRAM 读、向 OutSRAM 写。
- 下一层可反过来从 OutSRAM 读、向 ActSRAM 写。
- 残差块可能同时依赖两块 SRAM 或需要保存原始 resident 输入。

### 6.5 InBuf

InBuf 是 ComputeCoreGroup 前级的 64-bit 输入缓冲。它可以选择 ActSRAM 或 OutSRAM 的输出：

```text
iWriteDataA = ActData
iWriteDataB = OutData
iSelect     = InputBufSelect
```

普通卷积中，InBuf 主要起一拍暂存和数据源选择作用。残差卷积中，InBuf 还需要解决一个关键数据相关问题：

- 某些残差块中，resident 分支的原始输入需要被多次读取。
- 第一组 64 输出通道计算完成后，结果可能写回并覆盖 ActSRAM 中的原始 resident 输入。
- 第二组 64 输出通道再次读取 resident 输入时，如果没有额外保存，就会读到已经被覆盖的数据。

因此最终设计中需要让 InBuf 根据当前指令、ActSRAM 读中心地址和计算阶段保存 resident 输入，并在后续分组中重放原始数据。这是第一个 64-to-128 残差块和后续 128-to-256 残差块都必须处理的风险点。

### 6.6 ComputeCoreGroup

ComputeCoreGroup 由 64 个并行 ComputeCore 组成。每个 ComputeCore 对应当前输出通道组中的一个输出通道。

单个 ComputeCore 的数据路径为：

```text
64-bit activation word
64-bit weight word
        |
binary multiply / match
        |
64 输入的加法树
        |
跨 kernel 位置和输入通道组的累加器
        |
12-bit 累加结果
```

组输出为：

```systemverilog
wire [P_GROUP-1:0][P_OUTBITWIDTH_ACC-1:0] ComputeCoreData;
```

在默认参数下，即：

```text
64 x 12-bit
```

WeightSRAM 读地址在 AHB 和 APU 之间切换：

```systemverilog
weightReadAddr = conv_ram_ctrl ? conv_ram_raddr : WeightAddr
```

配置阶段由 AHB 读写权重；运行阶段由 Ctrl 按 kernel 位置和输入通道组递增权重地址。

### 6.7 SIMD

SIMD 执行卷积后的融合后处理：

```text
12-bit 累加结果
  -> BN 等效阈值比较
  -> HardTanh / sign
  -> 0/1 二值化输出
```

SIMD 输入是 64 个 12-bit 累加值，输出是一个 64-bit 特征 word：

```systemverilog
oSIMDData[63:0]
```

该 64-bit word 会按当前乒乓方向写入 ActSRAM 或 OutSRAM。

## 7. 普通卷积与残差卷积对 Ctrl 的影响

本设计中 Ctrl 最重要的分支来自 `opcode`：`00` 表示普通卷积，`01` 表示残差卷积。二者并不是只差一个是否相加的后处理，而是会显著影响 Ctrl 的读源选择、写回目标、循环层次、权重地址推进、BN 地址推进、累加器控制以及 InBuf 的保护逻辑。

### 7.1 普通卷积的 Ctrl 行为

普通卷积可以理解为单输入、单输出的数据流：

```text
源 SRAM -> InBuf -> ComputeCoreGroup -> SIMD -> 目的 SRAM
```

Ctrl 的主要任务是遍历：

```text
输出通道组 round
  输出空间点 t
    kernel 位置和输入通道组 cycle
```

对于普通卷积，`stride1` 决定输出空间点到输入读中心地址的映射；`kernelSize` 决定每个输出点需要读取几个 kernel 位置；`logInC` 决定每个 kernel 位置要遍历多少个 64 通道输入组；`logOutC` 决定要计算多少个 64 输出通道组。

普通卷积中，Ctrl 的控制逻辑相对直接：

- 只选择一个输入 SRAM 作为当前层源数据。
- 只选择另一个 SRAM 作为当前层目的数据。
- 每个输出点完成全部 `kernelSize * kernelSize * (C_in / 64)` 次部分计算后，才允许 SIMD 结果写回。
- Accumulator 在一个输出点开始时清零或装载第一次部分和，中间持续累加，最后保持到 SIMD 写回完成。
- 当前指令全部输出通道组和空间点完成后，切换 ping-pong 方向，并向 WorkSheet 发出 `oComputeDone`。

因此普通卷积的关键易错点主要是：读地址是否按 stride/kernel/padding 正确展开、权重地址是否和输入通道组及 kernel 位置对齐、写回地址是否按输出通道组和输出空间点递增、以及写使能是否补偿了 SRAM/InBuf/Accumulator 的流水线延迟。

### 7.2 残差卷积的 Ctrl 行为

残差卷积对应 `opcode=01`，它不是简单的普通卷积后再额外加一条线，而是一次指令中包含主干分支和 resident/shortcut 分支的配合。可以抽象为：

```text
主干路径:      上一普通卷积输出 -> 3x3/主干卷积 -> 累加结果
resident 路径: 原始残差输入     -> 1x1/stride2 卷积或 resident 计算 -> 残差结果
合并路径:      主干结果 + 残差结果 -> SIMD/二值化 -> 写回
```

在本 APU 中，残差卷积最影响 Ctrl 的地方有三点。

第一，读源不再是单一线性源。普通卷积只需要从当前 ping-pong 源 SRAM 取输入，而残差卷积需要同时理解主干输入和 resident 输入的来源。以通道扩展的残差块为例，主干卷积可能读当前中间结果，而 resident 分支需要回看更早的原始输入。如果这些数据位于同一块 SRAM，Ctrl 和 InBuf 必须避免写回覆盖后再读取。

第二，`stride1` 和 `stride2` 的含义不同。`stride1` 控制主干卷积的空间映射，`stride2` 控制 resident/shortcut 分支的空间映射。普通卷积只需要一套输出点到输入读中心地址的映射；残差卷积可能需要为同一个输出空间点生成两套读地址或两种读取阶段。

第三，输出写回有数据相关风险。残差块常见场景是输出通道数扩大，例如 64 到 128 或 128 到 256。APU 每次只计算 64 个输出通道，因此同一个 resident 输入会被多个输出通道组复用。若第一组输出写回时覆盖了 resident 输入所在地址，第二组输出通道再读 resident 输入就会读到错误数据。Ctrl 需要配合 InBuf 在第一次读到原始 resident 输入时保存它，后续需要时从 InBuf/暂存寄存器重放，而不是盲目再次访问已被覆盖的 SRAM 地址。

因此残差卷积下 Ctrl 除了普通卷积的循环外，还需要额外处理：

- 根据 `opcode=01` 进入残差状态或残差子阶段。
- 区分主干路径和 resident 路径的读地址、读使能和 InBuf 选择。
- 正确使用 `stride1` 和 `stride2`。
- 对 combined 权重区域使用不同的权重地址推进规则。
- 控制 Accumulator 在主干部分和残差部分之间是累加、保持还是重新装载。
- 在最终合并结果有效后再触发 SIMD 写回。
- 保护 resident 输入，避免先写回的 64 输出通道组破坏后续通道组还要读取的原始输入。

用一句话总结：普通卷积的 Ctrl 主要是“按三层循环把一个卷积算完并写到另一块 SRAM”；残差卷积的 Ctrl 还要“管理两条数据来源、两套空间映射和一个可能被写回破坏的 resident 数据依赖”。

## 8. 运行期数据流

### 8.1 普通卷积，`opcode=00`

普通卷积执行流程如下：

1. Ctrl 解码 `logInHW`、`logInC`、`logOutC`、`kernelSize`、`stride1`、`wAddr`、`bnAddr`。
2. 对每个输出通道组：
   - 设置 WeightSRAM 基地址。
   - 设置 SIMD/BN 参数地址。
3. 对每个输出空间点：
   - FeatureProcessor 根据读中心地址和 kernel size 读取输入窗口。
   - InBuf 暂存当前 64-bit 激活数据。
   - ComputeCoreGroup 读取对应 64-bit 权重。
   - 二值乘法、加法树产生部分和。
   - Accumulator 在所有 kernel 位置和输入通道组上累加。
4. SIMD 对最终累加结果做阈值比较，输出 64-bit 二值结果。
5. Ctrl 将 SIMDData 写入目标 Feature SRAM。
6. 当前层结束后，Ctrl 切换乒乓方向并向 WorkSheet 发出 `oComputeDone`。

### 8.2 残差卷积，`opcode=01`

残差指令对应课件中的计算类型 2，可抽象为：

```text
主干分支:     CONV1 + BN/SIMD
resident 分支: CONV2 / downsample
合并:         ADD + activation
```

该类型的核心难点不是计算本身，而是 SRAM 原地更新造成的数据冲突。解决策略是：

- 第一次读取 resident 输入时，把原始输入保存到 InBuf 或额外寄存器中。
- 当后续输出通道组还需要同一份 resident 输入时，不再从已被覆盖的 SRAM 地址读取，而是使用保存的数据。
- combined 权重文件，例如 `layer2.0.conv2_combined.txt`，将主干/残差相关参数按硬件执行顺序打包，便于一次性写入 WeightSRAM。

## 9. 网络映射

APU 负责二值 ResNet 的中间卷积部分。PS 端负责：

- CIFAR-10 图像预处理。
- 第一层卷积、BN、HardTanh。
- 将 `+1/-1` 转为硬件 `0/1`。
- APU 输出后的平均池化、全连接、BN 和 LogSoftmax。

Python 驱动中 APU 的输入形状为：

```text
(N, C, H, W) = (1, 64, 32, 32)
```

APU 的输出形状为：

```text
(N, C, H, W) = (1, 256, 8, 8)
```

课件中的典型卷积任务如下：

| 卷积类型 | 计算类型 | 输入 | 卷积核 | 步长 | padding | 输出 | APU 周期数 |
| ---: | ---: | --- | --- | ---: | --- | --- | ---: |
| 1 | 1 | `32 x 32 x 64` | `64 x 3 x 3 x 64` | 1 | 是 | `32 x 32 x 64` | 9,216 |
| 2 | 1 | `32 x 32 x 64` | `64 x 3 x 3 x 128` | 2 | 是 | `16 x 16 x 128` | 4,608 |
| 3 | 1 | `16 x 16 x 128` | `128 x 3 x 3 x 128` | 1 | 是 | `16 x 16 x 128` | 9,216 |
| 4 | 1 | `16 x 16 x 128` | `128 x 3 x 3 x 256` | 2 | 是 | `8 x 8 x 256` | 4,608 |
| 5 | 1 | `8 x 8 x 256` | `256 x 3 x 3 x 256` | 1 | 是 | `8 x 8 x 256` | 9,216 |
| 6 | 2 | `32 x 32 x 64` | `64 x 1 x 1 x 128` | 2 | 否 | `16 x 16 x 128` | 512 |
| 7 | 2 | `16 x 16 x 128` | `128 x 1 x 1 x 256` | 2 | 否 | `8 x 8 x 256` | 512 |

周期数公式可以理解为：

```text
cycles = (C_in / 64) * (C_out / 64) * H_out * W_out * K_h * K_w
```

因为每个周期级别的核心计算粒度是一个 64 输入通道组与一个 64 输出通道组。

### 9.1 当前驱动中的指令序列

`tb_top_student.v` 和 `apu_driver.py` 中当前示例加载了如下 WorkSheet 序列：

| WorkSheet 地址 | Layer | Opcode | 输入输出 | 步长 | `wAddr` | `bnAddr` |
| ---: | --- | ---: | --- | ---: | ---: | ---: |
| 0 | `layer1.0.conv1` | `00` | `32x32x64 -> 32x32x64` | 1 | 0 | 0 |
| 1 | `layer1.0.conv2` | `00` | `32x32x64 -> 32x32x64` | 1 | 9 | 1 |
| 2 | `layer1.1.conv1` | `00` | `32x32x64 -> 32x32x64` | 1 | 18 | 2 |
| 3 | `layer1.1.conv2` | `00` | `32x32x64 -> 32x32x64` | 1 | 27 | 3 |
| 4 | `layer2.0.conv1` | `00` | `32x32x64 -> 16x16x128` | 2 | 36 | 4 |
| 5 | `layer2.0.conv2_combined` | `01` | 残差合并，输出 `16x16x128` | 1/2 | 54 | 6 |
| 6 | `layer2.1.conv1` | `00` | `16x16x128 -> 16x16x128` | 1 | 92 | 10 |
| 7 | `layer2.1.conv2` | `00` | `16x16x128 -> 16x16x128` | 1 | 128 | 14 |

`APUdebug参数_golden` 中还提供了 `layer3.*` 的参数和中间结果。由于 WeightSRAM 每个 slice 只有 256 个 64-bit 地址，后续 256 通道层通常需要覆盖前面权重区域并分段执行。

## 10. 控制时序与流水线延迟

Ctrl 必须补偿各模块的时序延迟。课件给出的主要延迟关系如下：

| 阶段 | 类型 | 延迟 |
| --- | --- | ---: |
| FeatureProcessor / WeightSRAM 读 | 时序 | 1 cycle |
| InBuf 暂存 | 时序 | 1 cycle |
| 二值乘法 | 组合 | 0 cycle |
| 加法树 | 组合 | 0 cycle |
| Accumulator | 时序 | 1 cycle |
| SIMD 比较/激活 | 组合 | 0 cycle |
| FeatureProcessor 写 | 时序 | 1 cycle |

因此 Ctrl 中部分输出必须延迟对齐，尤其是：

- `oActWriteAddr`
- `oActWriteEn`
- `oOutWriteAddr`
- `oOutWriteEn`
- `oInputBufNWe`
- `oInputBufSelect`

推荐实现方式是将 Ctrl 分成两部分：

1. 主状态机和计数器只描述当前逻辑计算位置。
2. 输出延迟管线负责把写地址、写使能、累加器状态和 SIMD 写回时刻对齐。

这样可以减少因为 SRAM 读延迟、InBuf 延迟、Accumulator 延迟造成的 off-by-one 错误。

## 11. 存储容量与分块执行

### 11.1 特征 SRAM

每块 Feature SRAM 容量为：

```text
65536 bit = 32 x 32 x 64
```

它也刚好可以容纳：

```text
16 x 16 x 256 = 65536 bit
```

因此该设计用两块 64 Kb SRAM 就能覆盖本网络中间层的主要特征图尺寸。

### 11.2 权重 SRAM

WeightSRAM 共有 64 个 slice，每个 slice 有 256 个 64-bit word。一个 64 输出通道组会同时使用 64 个 slice。

不同输入通道下的 3x3 卷积每个输出通道需要的内部 64-bit 权重 word 数为：

| 输入通道数 | 输入通道组 | 3x3 内部权重 word 数 |
| ---: | ---: | ---: |
| 64 | 1 | 9 |
| 128 | 2 | 18 |
| 256 | 4 | 36 |

由于 `wAddr` 只有 8 bit，且每个 slice 深度为 256，较大的层或完整网络需要在主机侧分段装载参数，运行完一段后覆盖旧权重继续执行后续层。

## 12. 验证策略

推荐验证顺序如下：

1. 验证 AHB 单寄存器读写，包括 `RAM_CTRL_ADDR`、`RAM_SEL_ADDR`、`APU_READY_ADDR`、`CPL_ADDR`。
2. 写入 ActSRAM 后读回，确认输入 bit packing 和地址递增正确。
3. 对 WeightSRAM 的 64 个 slice 做写入/读回，确认 `RAM_SEL=64+i` 映射正确。
4. 对 SIMD 参数 RAM 做写入/读回，确认 `RAM_SEL=i` 映射正确。
5. 跑一个最简单普通卷积，比较 SIMD 输出和 golden 数据。
6. 跑 stride=2 的普通卷积，检查输出地址和 padding/步长逻辑。
7. 跑 `opcode=01` 残差卷积，重点检查 InBuf 是否保存了被覆盖前的 resident 输入。
8. 跑多条 WorkSheet 指令，检查 `ComputeDone` 和 `WorkSheetDone`。
9. 将最终输出与 `APUdebug参数_golden/data_flow` 中的逐层 golden 文件对比。

需要特别注意的数据格式问题：

- `$readmemb` 读入的 32-bit 文本行存在位序问题，助教提供文件已按要求做了反转处理。
- Conv/input 文件每两行组成一个 64-bit 计算 word。
- data_flow 中每 64 个数据为一组，校对时要按 64 通道组对齐。
- APU 输出按 64 输出通道组依次写出，不一定和 PyTorch NCHW 展平顺序完全一致。
- 某些读回流程中需要 dummy read 来补偿 SRAM/AHB 读延迟。

## 13. ASIC 集成考虑

如果将该设计作为 ASIC IP 集成，需要重点关注：

- 将 `FeatureProcessor`、`WeightSRAM`、SIMD 参数 RAM 替换为工艺 SRAM macro 或寄存器文件 macro。
- 保持配置阶段和运行阶段的 RAM 控制权互斥，或使用真正双端口 SRAM 支持读写分离。
- 64-bit activation word 会广播到 64 个 ComputeCore，物理实现中要关注扇出和布线。
- WeightSRAM 64 个 slice 天然适合做规则阵列布局，每个 slice 靠近对应 ComputeCore。
- SRAM macro 的读延迟一旦变化，Ctrl 的延迟管线必须同步调整。
- 可以对 WeightSRAM、SIMD 参数 RAM、AHB Slave 做时钟门控，降低运行期功耗。
- 若 SoC 中数据搬运压力较大，可在 AHB 外层增加 DMA 或更宽的数据搬运接口，但 APU 内部 64-bit 计算粒度不需要改变。

## 14. 总结

该 APU 是一个高度定制的二值 CNN 加速器，而不是通用 NPU。它用固定 64 通道粒度换取简单、规则、可验证的硬件结构：

- 两块 64 Kb 特征 SRAM 做乒乓缓存。
- 64 个 WeightSRAM slice 对应 64 个并行输出通道。
- ComputeCoreGroup 每次处理一个 64-bit 激活 word 和 64 个输出通道的权重。
- SIMD 将 BN、HardTanh 和二值化后处理融合为阈值比较。
- WorkSheet 用 32-bit 指令描述层参数和调度信息。
- Ctrl 负责把网络层映射为地址、使能、累加和写回时序。
- InBuf 除普通缓冲外，还必须处理残差块的 resident 输入覆盖问题。

从教学和芯片设计角度看，这个 APU 覆盖了神经网络 ASIC 中非常典型的问题：片上存储组织、总线配置接口、二值计算阵列、指令调度、乒乓缓存、残差数据相关、流水线延迟补偿以及 golden model 对拍验证。
