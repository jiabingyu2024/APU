# `rtl` 与 `rtlOther` 功能差异审查

## 1. 审查范围与结论

- `rtl/`：当前本人版本。
- `rtlOther/`：同学版本。
- 本文只做 APU RTL 静态逻辑审查，不涉及 SoC，也没有把两套源码混合修改。

本文比较的前提是：两份设计分别完成正确的 AHB 地址适配、启动适配，并使用完全相同
的输入、权重、BN 参数和指令。地址基址等上板配置不作为功能差异。

两套设计的 XNOR、popcount、累加器、权重 SRAM 和 32/64-bit RAM 拆装在功能上基本
一致。真正可能让最终 tensor 数值不同的部分集中在：

1. `Ctrl` 的循环组织、累加控制相位和尾部写回不同；
2. residual 路径的 `InBuf` 是两套完全不同的实现；
3. `FeatureProcessor` 的边界判断和暂停行为不同；
4. 一次执行 16 条指令时，WorkSheet 指令计数能力不同。

因此，不能只替换一个 `Ctrl` 文件来比较两套功能。`Ctrl + InBuf + FeatureProcessor +
WorkSheet + AHB` 构成了各自配套的时序合同。

## 2. 模块对应关系

| 本人版本 | 同学版本 | 主要结论 |
| --- | --- | --- |
| `Top_student.sv` | `Top.sv` | 核心数据通路连接相近 |
| `Ctrl.sv` | `Ctrl_student.sv` | 核心调度方式和流水控制明显不同 |
| `InBuf.sv` | `InBuf.sv` | residual 对齐机制完全不同 |
| `FeatureProcessor.sv` | `FeatureProcessor.sv` | 地址公式相近，边界判断实现不同 |
| `WorkSheet.sv` | `Worksheet.sv` | 启动检测和指令计数宽度不同 |
| `SIMD.sv` | `SIMD.sv` | 比较函数相同，AHB 读回延迟不同 |
| `ram_mux.sv` | `ahb_slave_top.v` 内 `ram_mux` | 32/64-bit 拼接和读回顺序相同 |
| `addr_map/ahb_slave` 独立文件 | 合并在 `ahb_slave_top.v` | 属于接口集成差异，不参与 tensor 比较 |

## 3. 不会造成数值功能差异的部分

### 3.1 计算核心

两份 `Multiplier` 都执行：

```text
mul[i] = activation[i] XOR weight[i]
```

两份 `AdderTree` 都对 64 个 1-bit 结果求和。本人版本使用循环累加组合逻辑，同学版本
使用显式二叉加法树；数值相同，但综合结构、逻辑深度和时序可能不同。

两份 `Accumulator` 的指令语义相同：

| `accInst` | 行为 |
| --- | --- |
| `00` | 清零 |
| `01` | 装载当前 popcount |
| `10` | 累加当前 popcount |
| `11` | 保持 |

### 3.2 lane 映射

两份 `ComputeCoreGroup` 都是：

```text
weight bank i -> ComputeCore i -> accumulator i -> SIMD bit i
```

没有发现一份把 lane `i` 接到 `63-i`，也没有发现 32-channel 半字交换。

### 3.3 32/64-bit RAM 拼接

两份 `ram_mux` 的关键逻辑相同：

```systemverilog
ram_waddr[0] == 0：暂存第一个 32-bit word
ram_waddr[0] == 1：写入 {当前 word, 暂存 word}
```

读回也都是低地址返回 `[31:0]`，高地址返回 `[63:32]`。所以此前看到的相邻两个
32-bit word 顺序差异，不能归因于两份 `ram_mux` 不同。

## 4. 不纳入结果比较的接口差异

### 4.1 地址选择

本人版本由顶层传入 `hsel`：

```systemverilog
ready_en = hsel & htrans[1];
```

因此课程 TB 可以直接使用 `0x0000_0000`、`0x0000_2000` 等局部地址。

同学版本删除了顶层 `hsel`，在 AHB slave 内固定译码：

```systemverilog
BRIDGE_BASE_ADDR = 32'h43C0_0000;
hsel = haddr >= 32'h43C0_0000 && haddr < 32'h43C0_4000;
```

该差异通过 TB 或板级地址适配即可消除。只要两份设计都收到相同的内部寄存器和 RAM
访问，它不会改变卷积结果，因此不列为功能风险。

### 4.2 `apu_ready` 协议

本人版本在任意非写周期把 `apu_ready` 清零，因此写 `1` 产生单周期脉冲。本人
`WorkSheet` 使用电平检测启动。

同学版本在没有 AHB 写操作时保持 `apu_ready`；只有写其他寄存器或显式写 `0` 才清零。
与之配套的 `WorkSheet` 使用 `iAPUReady && !apuReadyD` 上升沿检测。

两套启动逻辑各自配套时都能产生一次执行请求。它只在交叉替换模块时才会造成启动
异常，不代表两份完整设计的 tensor 结果必然不同。

## 5. WorkSheet 差异

### 5.1 指令数量宽度

本人版本的 `totalInstrCount` 宽度是 `$clog2(16)=4`。连续写满 16 条指令时，计数从
15 加 1 会回到 0。

同学版本使用 32-bit `totalInstrCount`，可正确表示 16。

**可见现象：**本人版本一次 worksheet 装满 16 条指令时可能立即错误结束或不执行；
当前一次最多装 8 条，所以现有网络没有触发该问题。

### 5.2 启动方式

本人版本对 `iAPUReady` 做电平检测，同学版本做上升沿检测。这与上一节的
`apu_ready` 生成方式严格配套，不是单纯代码风格差异。

## 6. Ctrl 核心调度差异

### 6.1 循环组织

同学版本采用直观三层顺序：

```text
round：输出空间像素
  -> t：输出 64-channel group
     -> cycle：kernel phase × 输入 group，再接 residual shortcut
```

每完成一个输出 group，`writeAddr1++`；每完成一个像素，权重地址回到 `wAddr`。

本人版本采用扁平 `cut_num`：

```text
cut_num
  -> pixel = cut_num / (IG × OG)
  -> output word address = cut_num / IG
  -> cut_num 低位判断当前是否为一个 output word 的首/末 input group
```

这里 `IG=Cin/64`，`OG=Cout/64`。该实现只对当前固定网络的 `IG/OG=1/2/4` 做了移位
优化。同学版使用通用乘加公式，支持范围更宽，但组合路径更长。

两种循环理论上都能形成“pixel-major、output-group-minor”的物理地址顺序，但其控制
信号相位完全不同，不能只对照变量名逐句替换。

### 6.2 累加器控制延迟

同学版：

```text
oAccInstr1 -> oAccInstr2 -> oAccInstr
```

控制请求延迟两拍。

本人版本：

```text
acc_instr_d -> oAccInstr
```

控制请求延迟一拍，但请求条件已经按照当前 SRAM/InBuf 时序重新安排。

这里的拍数不同本身不代表结果不同，因为两套请求条件也不同。完整配套运行时，只要
`LOAD/ADD` 最终都对齐到同一个 activation/weight token，数学结果可以相同；但不能只
替换 `Ctrl`，否则会出现首项丢失或重复累加。

### 6.3 SRAM 写回延迟

同学版本的地址经过三拍，写使能经过两拍：

```text
writeAddr1 -> Addr2 -> Addr3 -> SRAM address
writeEn1   -> En2   -> SRAM write enable
```

本人版本使用一拍 `*_write_*_d`，并在“下一 output word 开始”时写回上一 word；最后一个
word 由完成后的 IDLE 拍补写。

对于完整的两套设计，这两种写回方法都可能正确。真正会形成结果差异的条件是尾写
没有在 `ComputeDone` 之后完成，或者下一条指令过早取得 SRAM 所有权。表现为每层最后
一个 64-bit word 不同，其余地址可能全部一致。

### 6.4 完成时序

同学版本在计算结束后进入 `DRAIN`，等待三个时钟，再发出 `oComputeDone`。

本人版本在最后计算项完成时立即拉高 `oComputeDone`，下一拍借助 IDLE 完成尾写。

**实际结果判断：**在各自完整设计中，同学版用 `DRAIN` 保证写完后再完成；本人版依赖
完成后的 IDLE 尾写。若 WorkSheet 在同拍切换 `nCe` 时没有保留该尾写窗口，本人版会
丢最后 word。当前本人 `Ctrl` 已专门用 `nCe && !oComputeDone` 和 IDLE 尾写处理此事，
所以现有配套下不应仅因完成时序不同而产生结果差异。

### 6.5 BN 地址推进

同学版本在 output-group 边界更新 `oBNAddr1`，再经过三拍输出到 SIMD。

本人版本在注册后的 Feature SRAM 写脉冲出现时推进 `oBNAddr`，没有同学版的三级 BN
地址流水。

完整配套运行时，两种 BN 推进方式都以 output-group 为单位，理论目标相同。只有控制
与 SIMD 延迟配错时才会让阈值属于相邻 group。因此这不是两份完整设计必然不同的点，
但它解释了为什么不能只换 `Ctrl`。

### 6.6 支持范围

本人版本明确限制 `H/W=8/16/32`、`Cin/Cout=64/128/256`，stride2 地址公式也针对当前
网络。未知编码会回落到默认值。

同学版直接用 `1 << log`、乘法和减法计算，shape 更通用；但非法 kernel 编码可能导致
无符号下溢和超长运行。

## 7. residual 路径的决定性差异

这是两份实现差异最大的部分。

### 7.1 本人 InBuf

本人版本依赖固定周期：

```text
logInHW=4 -> count_top=38
其他值    -> count_top=152
```

在固定计数点 `18`、`36`、`37` 锁存 shortcut 数据，再在 `count>20` 或 `count>40` 后
重放。该逻辑与当前 layer2/layer3 的固定计算节拍强绑定。

风险：

- `fromram/temp1/temp2` 在组合块中没有默认赋值，会推断锁存器；
- `count` 在 `nWe=1` 时被清零，行为依赖 `Ctrl` 对 `nWe` 的精确相位；
- 更改 kernel、通道数、SRAM 延迟或 `Ctrl` 拍数后，固定常数立即失效。

### 7.2 同学 InBuf

同学版本使用：

- `delayedSelect` 对齐 SRAM 一拍读延迟；
- `previousReadAddress` 检测相同 shortcut 地址；
- 128-channel 使用一个 residual buffer；
- 256-channel 使用两个 residual buffer 轮换重放。

它不依赖 38/152 的完整周期计数，但强依赖同学版 `Ctrl` 的地址重复序列。

### 7.3 是否会产生真实结果差异

会，这是两份完整设计最可能真正产生 tensor 差异的位置。

同学版 residual buffer 只在 `writeFromA` 时捕获 shortcut，主数据则优先从 B 写入
`mainBuffer`。这隐含要求 residual 指令开始时 `pingpong=1`：

```text
OutSRAM(B) = 主路径输入
ActSRAM(A) = shortcut 输入
```

当前固定网络中，每个 residual 之前的 normal 指令数量恰好使 `pingpong=1`，所以该假设
可以成立。但若改变指令拆批方式、跳过某层、单独运行 residual，或者初始 pingpong
方向不同，同学版会捕获错误 RAM；本人版通过 `fromram` 记录方向，设计意图上不固定
要求 residual 从某一特定 SRAM 开始。

另一方面，本人版使用固定 `38/152` 周期和锁存器重放 shortcut，强依赖当前网络节拍。
若 `Ctrl`、SRAM 延迟、通道数或 kernel 节拍变化，本人版可能在错误周期重放；同学版
则依赖地址重复和双 buffer，受完整周期长度变化影响较小。

因此结果差异具有明确触发条件：

| 运行场景 | 更可能的结果 |
| --- | --- |
| 完整运行当前固定网络，指令顺序不变 | 两者有可能得到相同结果，必须动态回归确认 |
| 单独从 residual 指令启动 | 同学版可能因固定 RAM 方向假设而不同 |
| 改变指令拆批或跳过前级层 | 同学版 residual 主/shortcut RAM 可能选反 |
| 改变通道数、kernel 或流水延迟 | 本人版固定 38/152 周期更可能失效 |
| 256-channel residual | 两者缓存和重放机制差异最大，最值得优先比对 |

一旦触发，现象不是文件显示差异，而是 shortcut 加到了错误 output group，经过 SIMD 后
大量输出 bit 不同，并继续传播到后续层。

## 8. FeatureProcessor 差异

两份都按 `iDepth=C/64` 产生 3x3 的九个地址，并把越界位置置零。

本人版本先计算 `centerRow/centerCol`，逻辑语义直观；同学版本用地址范围和按位 `&`
判断行内偏移。对于当前 `inHW*iDepth` 均为 2 的幂，两者多数情况下等价。

关键差异：

1. 本人版本即使 `nCe=1`，仍更新 `zeroMaskReg/rKernelSize`；同学版本在 `nCe=1` 时完整
   保持读数据和 mask。
2. 本人版本的 `rKernelSize` 是 1-bit，只保存“是否 3x3”；同学版本保存完整 2-bit
   kernel 编码。
3. 同学版本越界时把物理读地址改成 0；本人版本仍读取回绕地址，只在输出端屏蔽。

**实际结果判断：**当前网络的 `inHW*iDepth` 均为 2 的幂，并只使用 3x3/1x1，因此两种
边界算法在正常连续运行中应产生相同 padding。连续启停、非法 shape 或非 2 的幂布局
才可能产生边界首拍和行边界差异；这不是当前网络最终结果不同的首要原因。

## 9. SIMD 差异

两份计算输出完全相同：

```text
sign=1：acc > threshold
sign=0：acc < threshold
```

差异只在 AHB 读回：本人 `oReadData` 寄存一拍，同学版组合读取。卷积计算使用的
`oSIMDData` 都是组合结果，所以在不读回 BN 参数的正常推理中不会改变 tensor。

## 10. 与当前“通道/半字顺序不一致”的关系

静态比较可以明确排除：

- 两份 `ram_mux` 的 low32/high32 规则相同；
- 两份 `ComputeCoreGroup` 都保持 lane `i -> bit i`；
- 两份 SIMD 比较都保持 lane 编号。

所以相邻 32-bit word 交换现象，不是因为本人和同学的基础数据通路接线相反。

两份 `Ctrl` 虽然调度方法不同，但都按输出 group 递增写物理地址。若使用同一套参数
装载规则，单凭当前静态代码不能证明同学版会自动消除 golden 的 group/half-word 排列
差异。该问题仍应优先检查参数文件通道顺序和 TB 中 `conv_layer` 的 bank/group 装载索引。

## 11. 实际计算结果差异排序

| 优先级 | 会改变结果的条件 | 最可能现象 |
| --- | --- | --- |
| P0 | residual 起始 RAM 方向或重放节拍变化 | layer2/layer3 shortcut 加错，最终 tensor 大量不同 |
| P0 | 尾写窗口被下一条指令或停机覆盖 | 每层最后一个 64-bit word 不同 |
| P1 | Acc/BN 控制与本设计 SRAM 延迟不配套 | kernel 首项或 64-channel group 周期性错位 |
| P1 | 本人版本一次写满 16 条指令 | 指令计数回绕，整批不执行或提前结束 |
| P2 | 非当前 shape、非 2 的幂布局或异常启停 | padding 边界和首拍数据不同 |
| 不影响 tensor | AHB 基地址、SIMD 软件读回延迟 | 正确适配后计算值不变 |
| 不影响数值 | 加法树实现结构 | 仅综合时序和资源不同 |

## 12. 最终判断

1. 排除 AHB 基地址和启动接口适配后，两份 normal 卷积的数学目标相同，不能仅凭代码
   结构不同就判断输出不同。
2. 对当前固定网络、固定指令顺序，两份完整设计有可能给出相同结果，但静态审查不能
   代替逐层动态比对。
3. residual 的实现机制完全不同，是实际运行产生结果差异的首要位置；尤其是单独运行
   residual、改变拆批顺序或执行 256-channel residual 时。
4. 尾写机制不同是第二个真实风险，检查时应特别比较每层最后一个 64-bit word。
5. FeatureProcessor 和 SIMD 的差异在当前正常推理条件下通常不会改变 tensor。
6. 当前 32-bit 半字和 channel-group 排列问题不能由两份 `ram_mux` 差异解释。
7. 后续动态对比必须使用同一份参数、同一份 dataflow，并分别提供匹配各自地址和启动
   协议的薄适配层；比较点应依次为第一层、首次 128-channel、首次 residual、
   首次 256-channel，而不是直接只看最终输出。
